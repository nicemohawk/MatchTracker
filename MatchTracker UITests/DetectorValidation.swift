// DetectorValidation.swift
// MatchTracker UITests
//
// Validates `SatelliteFieldDetector` against REAL Apple satellite imagery on the booted simulator.
// The app can't be asked to detect from the UI-test process (the detector lives in the app target),
// so this launches the app with `-RunDetectorValidation <regions>`, which triggers the DEBUG
// harness (`SatelliteDetectorValidation`) to run the real detector over each region and write
// annotated PNGs + a results JSON into a directory shared between the app and this runner
// (`SIMULATOR_SHARED_RESOURCES_DIRECTORY`, also passed explicitly via launch environment).
//
// The runner and this test share a directory because both processes run on the same simulator and
// both see `SIMULATOR_SHARED_RESOURCES_DIRECTORY`. We poll for a `DONE` sentinel, then attach the
// imagery and assert the recall/precision bar: ≥1 detection in each positive region, 0 in the
// negative control.

import XCTest

final class DetectorValidation: XCTestCase {

    /// Must match `SatelliteDetectorValidation.launchKey` / `.outputEnvKey` in the app target.
    private let launchArgumentKey = "-RunDetectorValidation"
    private let outputEnvironmentKey = "DETECTOR_VALIDATION_OUTPUT"

    /// Real regions to exercise. `expectsPitch == false` is a negative control. `span` is the
    /// latitude/longitude delta in degrees (a comfortable single-complex framing).
    private struct Region {
        let name: String
        let latitude: Double
        let longitude: Double
        let span: Double
        let expectsPitch: Bool
    }

    private let regions: [Region] = [
        // Positives — large public multi-pitch soccer complexes (many full-size grass pitches, so a
        // ~0.008° frame captures several even if the listed centre is slightly off). These are the
        // crisp, multi-pitch case the Vision path already handled well.
        Region(name: "PosWRALRaleigh", latitude: 35.8847, longitude: -78.5482, span: 0.0050, expectsPitch: true),
        Region(name: "PosStarSanAntonio", latitude: 29.5412, longitude: -98.3932, span: 0.0050, expectsPitch: true),
        Region(name: "PosWWTechFenton", latitude: 38.5455, longitude: -90.4383, span: 0.0045, expectsPitch: true),

        // Positives — SINGLE pitch that FILLS most of the frame with FAINT markings, at two zooms.
        // This is the field-report failure mode: Vision returns no rectangle for a lone frame-filling
        // pitch (its touchlines run near/off the frame edge and the markings are low-contrast), so the
        // scorer never saw a candidate. The model-driven ridge search recovers these. WW Tech's centre
        // pitch is dark turf with faint dark-on-dark lines that fills the frame at these spans.
        Region(name: "PosWWTechFillA", latitude: 38.5455, longitude: -90.4383, span: 0.0015, expectsPitch: true),
        Region(name: "PosWWTechFillB", latitude: 38.5455, longitude: -90.4383, span: 0.0022, expectsPitch: true),

        // Positives — WORN municipal-park grass pitch (tan/patchy turf, faint white chalk outline and
        // centre circle), at two zooms including "fills most of the frame". A WRAL overflow field north
        // of the complex; Vision found nothing here, the ridge search recovers it.
        Region(name: "PosWornFill", latitude: 35.8858, longitude: -78.5494, span: 0.0017, expectsPitch: true),
        Region(name: "PosWornWide", latitude: 35.8858, longitude: -78.5494, span: 0.0022, expectsPitch: true),

        // Negative controls — open Pacific water, and a large uniform-green farm field (a realistic
        // false-positive trap: green + rectangular but with no white pitch markings). The ridge search
        // adds many more candidates, so these guard that its extra recall costs no precision.
        Region(name: "NegPacific", latitude: 36.5000, longitude: -122.6000, span: 0.010, expectsPitch: false),
        Region(name: "NegFarmland", latitude: 38.6868, longitude: -90.0342, span: 0.0050, expectsPitch: false)
    ]

    private struct RegionResult: Decodable {
        let name: String
        let detectionCount: Int
        let lengthsMeters: [Double]
        let widthsMeters: [Double]
        let timingMilliseconds: Double
        let annotatedImage: String
        let note: String
    }

    func testDetectorRecallAndPrecision() throws {
        let outputDirectory = try prepareSharedOutputDirectory()

        let spec = regions
            .map { "\($0.name),\($0.latitude),\($0.longitude),\($0.span)" }
            .joined(separator: ";")

        let app = XCUIApplication()
        app.launchArguments += ["-hasOnboarded", "YES", launchArgumentKey, spec]
        app.launchEnvironment[outputEnvironmentKey] = outputDirectory.path
        app.launch()

        // The DEBUG harness runs on a detached task independent of the UI, so we just wait on files.
        let doneMarker = outputDirectory.appendingPathComponent("DONE")
        XCTAssertTrue(waitForFile(doneMarker, timeout: 300),
                      "Detector validation never produced a DONE marker at \(outputDirectory.path)")

        let resultsURL = outputDirectory.appendingPathComponent("results.json")
        attachFile(resultsURL, name: "results.json")
        let data = try Data(contentsOf: resultsURL)
        let results = try JSONDecoder().decode([RegionResult].self, from: data)

        // Attach every annotated snapshot for human inspection, and log a compact summary.
        var summary = "Detector validation results:\n"
        for result in results {
            attachFile(outputDirectory.appendingPathComponent(result.annotatedImage), name: result.annotatedImage)
            summary += "  \(result.name): \(result.detectionCount) detection(s), "
                + "sizes \(zip(result.lengthsMeters, result.widthsMeters).map { "\(Int($0.0))×\(Int($0.1))m" }), "
                + "\(Int(result.timingMilliseconds))ms — \(result.note)\n"
        }
        let summaryAttachment = XCTAttachment(string: summary)
        summaryAttachment.name = "summary.txt"
        summaryAttachment.lifetime = .keepAlways
        add(summaryAttachment)
        print(summary)

        // Timing budget: a full region scan should stay well under ~3s of detector work.
        for result in results {
            XCTAssertLessThan(result.timingMilliseconds, 3000,
                              "\(result.name) detector scan took \(Int(result.timingMilliseconds))ms (> 3000ms budget)")
        }

        // Recall / precision bar.
        for region in regions {
            guard let result = results.first(where: { $0.name == region.name }) else {
                XCTFail("No result recorded for \(region.name)")
                continue
            }
            if region.expectsPitch {
                XCTAssertGreaterThanOrEqual(result.detectionCount, 1,
                    "Expected ≥1 pitch in \(region.name) but found \(result.detectionCount) — inspect \(result.annotatedImage)")
            } else {
                XCTAssertEqual(result.detectionCount, 0,
                    "Negative control \(region.name) should find 0 pitches but found \(result.detectionCount) — inspect \(result.annotatedImage)")
            }
        }
    }

    // MARK: - Shared directory / file helpers

    private func prepareSharedOutputDirectory() throws -> URL {
        let base: URL
        if let shared = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] {
            base = URL(fileURLWithPath: shared, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        let directory = base.appendingPathComponent("DetectorValidation", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(500_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func attachFile(_ url: URL, name: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        let attachment = XCTAttachment(data: data)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
