import XCTest
import CoreGraphics
@testable import MatchTrackerKit

/// Format-transcendent workrate: pitch scaling, availability-weighted effort blending, and the
/// wire keys that carry format across the backend.
final class MatchFormatTests: XCTestCase {

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Track builders

    /// A straight north-running track at a repeating speed profile: `baseSpeed` broken by a
    /// `sprintSpeed` burst of `sprintDuration` every `sprintPeriod` seconds. Reported point speed
    /// is exact, so speed zones and distances are deterministic.
    private func movingTrack(durationSeconds: Double, cadence: Double = 1.0,
                             baseSpeed: Double, sprintSpeed: Double,
                             sprintDuration: Double, sprintPeriod: Double) -> [TrackPoint] {
        let frame = ENUFrame(reference: fieldCenter)
        var points: [TrackPoint] = []
        var north = 0.0
        var t = 0.0
        while t < durationSeconds {
            let phase = t.truncatingRemainder(dividingBy: sprintPeriod)
            let speed = phase < sprintDuration ? sprintSpeed : baseSpeed
            let coordinate = frame.unproject(CGPoint(x: 0, y: north))
            points.append(TrackPoint(coordinate: coordinate, timestamp: start.addingTimeInterval(t),
                                     speedMetersPerSecond: speed, courseDegrees: -1, horizontalAccuracy: 8))
            north += speed * cadence
            t += cadence
        }
        return points
    }

    /// A track with an exactly controllable distance rate and high-intensity share: `highFraction`
    /// of each second runs at `highSpeed` (≥ 4 m/s counts as high-intensity), the rest at `lowSpeed`.
    /// Reported point speed is exact, so distance and speed-zone fractions are deterministic.
    private func profileTrack(seconds: Int, highFraction: Double, highSpeed: Double, lowSpeed: Double) -> [TrackPoint] {
        let frame = ENUFrame(reference: fieldCenter)
        let period = highFraction > 0 ? Int((1.0 / highFraction).rounded()) : Int.max
        var east = 0.0
        var points: [TrackPoint] = []
        for index in 0..<seconds {
            let coordinate = frame.unproject(CGPoint(x: east, y: 0))
            let speed = (period != Int.max && index % period == 0) ? highSpeed : lowSpeed
            points.append(TrackPoint(coordinate: coordinate, timestamp: start.addingTimeInterval(Double(index)),
                                     speedMetersPerSecond: speed, courseDegrees: -1, horizontalAccuracy: 5))
            east += speed
        }
        return points
    }

    /// Constant-bpm heart-rate samples every 5 s across the whole span.
    private func heartRate(durationSeconds: Double, bpm: Double) -> [HeartRateSample] {
        stride(from: 0.0, through: durationSeconds, by: 5.0).map {
            HeartRateSample(date: start.addingTimeInterval($0), bpm: bpm)
        }
    }

    private func wholeSpan(_ durationSeconds: Double) -> [DateInterval] {
        [DateInterval(start: start, end: start.addingTimeInterval(durationSeconds))]
    }

    /// `count` sprint segments — `analyze` reads only `intensity` from each, so these stand in for
    /// a detector run without coupling the sprint count to the synthetic track's run-merging.
    private func sprintRuns(count: Int) -> [RunSegment] {
        (0..<count).map { index in
            let at = start.addingTimeInterval(Double(index) * 10)
            return RunSegment(interval: DateInterval(start: at, end: at.addingTimeInterval(3)),
                              distanceMeters: 20, peakSpeed: 7, averageSpeed: 6, intensity: .sprint,
                              pointRange: 0..<1)
        }
    }

    // MARK: - MatchContext.pitchScale

    func testPitchScaleFullSizePitchIsOne() {
        XCTAssertEqual(MatchContext(format: .match, fieldLengthMeters: 105).pitchScale, 1.0, accuracy: 1e-9)
        // Missing length falls back to a full-size pitch.
        XCTAssertEqual(MatchContext(format: .match).pitchScale, 1.0, accuracy: 1e-9)
    }

    func testPitchScaleShortFieldUsesSqrtRatioAndClampsAtFloor() {
        // sqrt(60/105) ≈ 0.756
        XCTAssertEqual(MatchContext(format: .smallSided, fieldLengthMeters: 60).pitchScale, (60.0 / 105).squareRoot(), accuracy: 1e-9)
        // Tiny field clamps to the 0.6 floor (sqrt(20/105) ≈ 0.436).
        XCTAssertEqual(MatchContext(format: .smallSided, fieldLengthMeters: 20).pitchScale, 0.6, accuracy: 1e-9)
        // Oversized field clamps to the 1.0 ceiling.
        XCTAssertEqual(MatchContext(format: .match, fieldLengthMeters: 200).pitchScale, 1.0, accuracy: 1e-9)
    }

    func testIndoorPitchScaleIsAlwaysSixTenths() {
        XCTAssertEqual(MatchContext(format: .indoor, fieldLengthMeters: 105).pitchScale, 0.6, accuracy: 1e-9)
        XCTAssertEqual(MatchContext(format: .indoor, fieldLengthMeters: nil).pitchScale, 0.6, accuracy: 1e-9)
    }

    // MARK: - Effort blending weights & source

    func testLegacySignatureDelegatesToGPSOnly() {
        let duration = 1200.0
        let track = movingTrack(durationSeconds: duration, baseSpeed: 5.0, sprintSpeed: 7.0,
                                 sprintDuration: 4, sprintPeriod: 60)
        let runs = RunDetector.detectRuns(in: track, configuration: RunDetectorConfiguration())
        let intervals = wholeSpan(duration)

        let legacy = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: intervals)
        let explicit = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: intervals,
                                                 heartRate: [], context: MatchContext(format: .match))
        XCTAssertEqual(legacy.workrateScore, explicit.workrateScore, accuracy: 1e-9)
        XCTAssertEqual(legacy.effortSource, "gps")
    }

    /// With every GPS component saturated at its curve ceiling (distance 92, high-intensity 90,
    /// sprints 90) the blend weights stay directly readable. GPS-only = 0.40·92 + 0.30·90 +
    /// 0.30·90 = 90.8; GPS+HR swaps 25% of the weight onto hrEffort; indoor is hrEffort alone.
    func testBlendWeightsWithSaturatedGPSAndKnownHR() {
        let duration = 1200.0
        // baseSpeed 5.0 (running zone) with 7.0 bursts keeps every step in the running/sprinting
        // zones (high-intensity share 1.0 → 90) at a ~308 m/min pace (distance saturates → 92).
        let track = movingTrack(durationSeconds: duration, baseSpeed: 5.0, sprintSpeed: 7.0,
                                 sprintDuration: 4, sprintPeriod: 60)
        let runs = sprintRuns(count: 20)   // 10 sprints / 10 min → sprint curve saturates → 90
        let intervals = wholeSpan(duration)

        // hrEffort anchor 0.65 %HRR → 72. meanHRR 0.65 → 60 + 0.65·130 = 144.5 bpm.
        let hr = heartRate(durationSeconds: duration, bpm: 144.5)

        let gpsOnly = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: intervals,
                                               heartRate: [], context: MatchContext(format: .match))
        XCTAssertEqual(gpsOnly.effortSource, "gps")
        XCTAssertEqual(gpsOnly.components?.distanceRate ?? 0, 92, accuracy: 0.01)
        XCTAssertEqual(gpsOnly.components?.highIntensity ?? 0, 90, accuracy: 0.01)
        XCTAssertEqual(gpsOnly.components?.sprints ?? 0, 90, accuracy: 0.01)
        XCTAssertNil(gpsOnly.components?.heartRate)
        XCTAssertEqual(gpsOnly.workrateScore, 90.8, accuracy: 0.1)   // 0.40·92 + 0.30·90 + 0.30·90

        let gpsHR = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: intervals,
                                             heartRate: hr, context: MatchContext(format: .match))
        XCTAssertEqual(gpsHR.effortSource, "gps+hr")
        XCTAssertEqual(gpsHR.components?.heartRate ?? 0, 72, accuracy: 0.01)
        XCTAssertEqual(gpsHR.workrateScore, 86.1, accuracy: 0.1)     // 0.30·92 + 0.25·90 + 0.20·90 + 0.25·72

        let indoor = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: intervals,
                                              heartRate: hr, context: MatchContext(format: .indoor))
        XCTAssertEqual(indoor.effortSource, "hr")                    // GPS ignored indoors
        XCTAssertNil(indoor.components?.distanceRate)
        XCTAssertEqual(indoor.workrateScore, 72, accuracy: 0.1)      // hrEffort alone
    }

    /// A comparable hard "strong amateur" effort should score within ±8 points whether it was
    /// measured full-pitch by GPS, small-sided by GPS+HR, or indoors by heart rate alone. Values
    /// were re-tuned to the calibration curves (each format lands ~72–76), not by loosening ±8.
    func testWorkrateComparableAcrossFormats() {
        let duration = 1200.0
        let intervals = wholeSpan(duration)

        // (a) Full pitch, GPS only — ~66 m/min with 5% high-intensity share and a sprint every 10 min.
        let fullTrack = profileTrack(seconds: 1200, highFraction: 0.05, highSpeed: 5.0, lowSpeed: 0.9)
        let fullReport = WorkrateAnalyzer.analyze(track: fullTrack, runs: sprintRuns(count: 2),
                                                  playingIntervals: intervals,
                                                  heartRate: [], context: MatchContext(format: .match))

        // (b) Small-sided (~55 m), GPS + HR — the same effort covers less ground; the pitch-scaled
        // distance/sprint curves and the heart-rate signal (0.68 %HRR) keep the components comparable.
        let smallContext = MatchContext(format: .smallSided, fieldLengthMeters: 55)
        let smallTrack = profileTrack(seconds: 1200, highFraction: 0.05, highSpeed: 4.5, lowSpeed: 0.49)
        let smallHR = heartRate(durationSeconds: duration, bpm: 60 + 0.68 * 130)
        let smallReport = WorkrateAnalyzer.analyze(track: smallTrack, runs: sprintRuns(count: 2),
                                                   playingIntervals: intervals,
                                                   heartRate: smallHR, context: smallContext)

        // (c) Indoor, HR only — same physiological effort (0.68 %HRR), no usable GPS.
        let indoorHR = heartRate(durationSeconds: duration, bpm: 60 + 0.68 * 130)
        let indoorReport = WorkrateAnalyzer.analyze(track: [], runs: [], playingIntervals: intervals,
                                                    heartRate: indoorHR, context: MatchContext(format: .indoor))

        XCTAssertEqual(fullReport.effortSource, "gps")
        XCTAssertEqual(smallReport.effortSource, "gps+hr")
        XCTAssertEqual(indoorReport.effortSource, "hr")

        XCTAssertEqual(fullReport.workrateScore, smallReport.workrateScore, accuracy: 8)
        XCTAssertEqual(smallReport.workrateScore, indoorReport.workrateScore, accuracy: 8)
        XCTAssertEqual(fullReport.workrateScore, indoorReport.workrateScore, accuracy: 8)
        // All three land in the strong-amateur band.
        for report in [fullReport, smallReport, indoorReport] {
            XCTAssert((65...80).contains(report.workrateScore), "expected strong band, got \(report.workrateScore)")
        }
    }

    // MARK: - Calibration band archetypes

    /// Four synthetic profiles must land in their intuition bands under BOTH GPS-only and GPS+HR
    /// blends: casual 25–45, average 50–65, strong 65–80, pro-like 80–95. Inputs were verified
    /// against the calibration curves; each pairs a matching %HRR so the HR blend lands in-band too.
    func testArchetypeProfilesLandInBands() {
        // (highFraction, highSpeed, lowSpeed, sprints, hrr, band)
        let cases: [(name: String, hf: Double, hs: Double, ls: Double, sprints: Int, hrr: Double, band: ClosedRange<Double>)] = [
            ("casual",  0.01,  4.5, 0.75, 0, 0.48, 25...45),
            ("average", 0.025, 4.5, 0.80, 1, 0.55, 50...65),
            ("strong",  0.05,  5.0, 0.90, 2, 0.65, 65...80),
            ("proLike", 0.10,  5.6, 1.10, 6, 0.78, 80...95),
        ]
        for test in cases {
            let track = profileTrack(seconds: 1200, highFraction: test.hf, highSpeed: test.hs, lowSpeed: test.ls)
            let intervals = wholeSpan(1200)
            let gps = WorkrateAnalyzer.analyze(track: track, runs: sprintRuns(count: test.sprints),
                                               playingIntervals: intervals, heartRate: [],
                                               context: MatchContext(format: .match))
            XCTAssert(test.band.contains(gps.workrateScore),
                      "\(test.name) GPS-only \(gps.workrateScore) outside \(test.band)")
            let hr = heartRate(durationSeconds: 1200, bpm: 60 + test.hrr * 130)
            let gpsHR = WorkrateAnalyzer.analyze(track: track, runs: sprintRuns(count: test.sprints),
                                                 playingIntervals: intervals, heartRate: hr,
                                                 context: MatchContext(format: .match))
            XCTAssert(test.band.contains(gpsHR.workrateScore),
                      "\(test.name) GPS+HR \(gpsHR.workrateScore) outside \(test.band)")
        }
    }

    /// The bottom of the scale must be honest: a player who barely exerts scores low, and clamping
    /// at the near-zero anchors can't gift points. "Coasting" (37 m/min, no sprints, 0.3% high-intensity,
    /// 0.40 %HRR) lands 12–32; a "walked around" extreme (40 m/min, no sprints, 0.30 %HRR) below 20.
    func testLowEffortScoresHonestlyLow() {
        let intervals = wholeSpan(1200)

        let coastTrack = profileTrack(seconds: 1200, highFraction: 0.003, highSpeed: 4.2, lowSpeed: 0.6)
        let coastGPS = WorkrateAnalyzer.analyze(track: coastTrack, runs: sprintRuns(count: 0),
                                                playingIntervals: intervals, heartRate: [],
                                                context: MatchContext(format: .match))
        XCTAssert((12.0...32.0).contains(coastGPS.workrateScore), "coast GPS \(coastGPS.workrateScore)")
        let coastHR = heartRate(durationSeconds: 1200, bpm: 60 + 0.40 * 130)
        let coastGPSHR = WorkrateAnalyzer.analyze(track: coastTrack, runs: sprintRuns(count: 0),
                                                  playingIntervals: intervals, heartRate: coastHR,
                                                  context: MatchContext(format: .match))
        XCTAssert((12.0...32.0).contains(coastGPSHR.workrateScore), "coast GPS+HR \(coastGPSHR.workrateScore)")

        let walkTrack = profileTrack(seconds: 1200, highFraction: 0.0, highSpeed: 0, lowSpeed: 0.667)
        let walkGPS = WorkrateAnalyzer.analyze(track: walkTrack, runs: sprintRuns(count: 0),
                                               playingIntervals: intervals, heartRate: [],
                                               context: MatchContext(format: .match))
        XCTAssertLessThan(walkGPS.workrateScore, 20, "walk GPS \(walkGPS.workrateScore)")
        let walkHR = heartRate(durationSeconds: 1200, bpm: 60 + 0.30 * 130)
        let walkGPSHR = WorkrateAnalyzer.analyze(track: walkTrack, runs: sprintRuns(count: 0),
                                                 playingIntervals: intervals, heartRate: walkHR,
                                                 context: MatchContext(format: .match))
        XCTAssertLessThan(walkGPSHR.workrateScore, 20, "walk GPS+HR \(walkGPSHR.workrateScore)")
    }

    /// Monotonicity: covering more ground (all else equal) never lowers the score.
    func testMoreDistanceNeverLowersScore() {
        let intervals = wholeSpan(1200)
        func score(lowSpeed: Double) -> Double {
            // Only the walking fill speed changes, so high-intensity share and sprint count hold;
            // distance rate rises with lowSpeed.
            let track = profileTrack(seconds: 1200, highFraction: 0.15, highSpeed: 5.0, lowSpeed: lowSpeed)
            return WorkrateAnalyzer.analyze(track: track, runs: sprintRuns(count: 5),
                                            playingIntervals: intervals, heartRate: [],
                                            context: MatchContext(format: .match)).workrateScore
        }
        let low = score(lowSpeed: 0.8)
        let mid = score(lowSpeed: 1.3)
        let high = score(lowSpeed: 1.8)
        XCTAssertGreaterThanOrEqual(mid, low)
        XCTAssertGreaterThanOrEqual(high, mid)
    }

    /// A typical recorded amateur match (57 m/min, 3 sprints in 70 min, 2% high-intensity share,
    /// mean 0.62 %HRR) should read as a solid-average outing.
    func testTypicalAmateurMatch() {
        let track = profileTrack(seconds: 4200, highFraction: 0.02, highSpeed: 4.5, lowSpeed: 0.88)
        let report = WorkrateAnalyzer.analyze(track: track, runs: sprintRuns(count: 3),
                                              playingIntervals: wholeSpan(4200),
                                              heartRate: heartRate(durationSeconds: 4200, bpm: 60 + 0.62 * 130),
                                              context: MatchContext(format: .match))
        XCTAssert((50.0...65.0).contains(report.workrateScore), "amateur \(report.workrateScore)")
        XCTAssertEqual(report.isLowConfidence, false)
    }

    /// A short cameo is flagged low-confidence even when the effort itself reads high.
    func testShortStintFlagsLowConfidence() {
        let intervals = wholeSpan(480)   // 8 min < 10 min threshold
        let track = profileTrack(seconds: 480, highFraction: 0.2, highSpeed: 5.0, lowSpeed: 1.2)
        let report = WorkrateAnalyzer.analyze(track: track, runs: sprintRuns(count: 3),
                                              playingIntervals: intervals, heartRate: [],
                                              context: MatchContext(format: .match))
        XCTAssertEqual(report.isLowConfidence, true)
    }

    // MARK: - MatchRecord decode tolerance

    func testMatchRecordDecodesLegacyJSONWithoutFormat() throws {
        let json = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","startDate":0,"fieldID":null,"events":[],"teamCode":null}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let record = try decoder.decode(MatchRecord.self, from: json)
        XCTAssertNil(record.format, "absent format key decodes as nil (≡ .match)")
    }

    func testMatchRecordFormatRoundTrips() throws {
        let record = MatchRecord(id: UUID(), startDate: start, endDate: nil, fieldID: nil,
                                 events: [], teamCode: nil, format: .indoor)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(MatchRecord.self, from: data)
        XCTAssertEqual(decoded.format, .indoor)
    }

    // MARK: - Wire keys

    func testMatchPayloadEncodesFormatAsSnakeCasedWireValue() throws {
        let stats = MatchStats(workrateScore: 70, effortSource: "gps+hr")
        let payload = MatchPayload(uuid: UUID(), recordedAt: start, coordinates: [],
                                   events: [], fieldUUID: nil, teamCode: nil,
                                   format: MatchFormat.smallSided.wireValue, stats: stats)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(payload), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"format\":\"small_sided\""), json)
        XCTAssertTrue(json.contains("\"effort_source\":\"gps+hr\""), json)
    }

    func testMatchPayloadOmitsFormatWhenNil() throws {
        let payload = MatchPayload(uuid: UUID(), recordedAt: start, coordinates: [],
                                   events: [], fieldUUID: nil, teamCode: nil, stats: MatchStats())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(payload), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"format\""), json)
        XCTAssertFalse(json.contains("effort_source"), json)
    }
}
