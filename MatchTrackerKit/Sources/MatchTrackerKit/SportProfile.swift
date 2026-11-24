import Foundation

// MARK: - Sport profiles (multi-sport core)

/// Describes one field sport: which HealthKit workout activity it maps to, the plausible pitch
/// dimensions used for field inference/plausibility, the ordered role vocabulary (defensive ->
/// offensive), and the event kinds its UI offers. The Kit stays HealthKit-free, so the workout
/// activity is carried as the raw `UInt` value of `HKWorkoutActivityType` — the app layer maps it
/// back to the real enum when starting a workout.
public struct SportProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String                     // "soccer", "lacrosse", "fieldHockey", "rugby", "ultimate"
    public var displayName: String
    public var workoutActivityTypeRawValue: UInt   // HKWorkoutActivityType.rawValue
    public var typicalLengthRange: ClosedRange<Double>   // meters, long side; plausibility + inference bounds
    public var typicalWidthRange: ClosedRange<Double>    // meters, short side
    public var positionRoles: [String]        // role vocabulary, ordered defensive -> offensive
    public var eventVocabulary: [MatchEventKind]  // kinds this sport's UI offers
    public var hasGoalkeeper: Bool            // whether positionRoles.first is a keeper-like role

    public init(id: String,
                displayName: String,
                workoutActivityTypeRawValue: UInt,
                typicalLengthRange: ClosedRange<Double>,
                typicalWidthRange: ClosedRange<Double>,
                positionRoles: [String],
                eventVocabulary: [MatchEventKind],
                hasGoalkeeper: Bool) {
        self.id = id
        self.displayName = displayName
        self.workoutActivityTypeRawValue = workoutActivityTypeRawValue
        self.typicalLengthRange = typicalLengthRange
        self.typicalWidthRange = typicalWidthRange
        self.positionRoles = positionRoles
        self.eventVocabulary = eventVocabulary
        self.hasGoalkeeper = hasGoalkeeper
    }

    // MARK: Presets

    // HKWorkoutActivityType raw values are hardcoded here (the Kit never imports HealthKit).
    // Verified against the HealthKit `HKWorkoutActivityType` NS_ENUM header:
    //   soccer = 41, lacrosse = 27, hockey = 25 (covers field hockey), rugby = 36,
    //   discSports = 73 (Frisbee sports incl. Ultimate).
    // NOTE the task hint's "soccer=61 / lacrosse=26" are decoys — 61 is downhillSkiing and
    // 26 is hunting; the values below are the correct ones.

    /// Full existing event set + soccer-relevant referee kinds (cards, fouls). No turnovers/timeouts.
    public static let soccer = SportProfile(
        id: "soccer",
        displayName: "Soccer",
        workoutActivityTypeRawValue: 41,           // HKWorkoutActivityType.soccer
        typicalLengthRange: 60...130,              // matches the legacy pitch sanity check
        typicalWidthRange: 35...90,
        positionRoles: ["goalkeeper", "defender", "midfielder", "forward"],
        eventVocabulary: [.matchStart, .matchEnd, .periodStart, .periodEnd,
                          .subIn, .subOut, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                          .flag, .yellowCard, .redCard, .foul],
        hasGoalkeeper: true
    )

    public static let lacrosse = SportProfile(
        id: "lacrosse",
        displayName: "Lacrosse",
        workoutActivityTypeRawValue: 27,           // HKWorkoutActivityType.lacrosse
        typicalLengthRange: 90...115,              // men's field ~100 m between end lines
        typicalWidthRange: 45...60,                // ~55 m wide
        positionRoles: ["goalie", "defense", "midfield", "attack"],
        eventVocabulary: [.matchStart, .matchEnd, .periodStart, .periodEnd,
                          .subIn, .subOut, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                          .flag, .foul, .turnover, .timeout],
        hasGoalkeeper: true
    )

    public static let fieldHockey = SportProfile(
        id: "fieldHockey",
        displayName: "Field Hockey",
        workoutActivityTypeRawValue: 25,           // HKWorkoutActivityType.hockey (field/ice)
        typicalLengthRange: 80...100,              // regulation 91.4 m
        typicalWidthRange: 45...65,                // regulation 55 m
        positionRoles: ["goalkeeper", "defender", "midfielder", "forward"],
        eventVocabulary: [.matchStart, .matchEnd, .periodStart, .periodEnd,
                          .subIn, .subOut, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                          .flag, .yellowCard, .redCard, .foul, .timeout],
        hasGoalkeeper: true
    )

    public static let rugby = SportProfile(
        id: "rugby",
        displayName: "Rugby",
        workoutActivityTypeRawValue: 36,           // HKWorkoutActivityType.rugby
        typicalLengthRange: 90...145,              // 94–100 m field of play + in-goal areas
        typicalWidthRange: 55...75,                // up to 70 m
        positionRoles: ["fullback", "forward", "halfback", "centre", "wing"],
        eventVocabulary: [.matchStart, .matchEnd, .periodStart, .periodEnd,
                          .subIn, .subOut, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                          .flag, .yellowCard, .redCard, .foul, .turnover],
        hasGoalkeeper: false
    )

    public static let ultimate = SportProfile(
        id: "ultimate",
        displayName: "Ultimate",
        workoutActivityTypeRawValue: 73,           // HKWorkoutActivityType.discSports
        typicalLengthRange: 90...110,              // 100 m incl. two 18 m end zones
        typicalWidthRange: 30...40,                // 37 m wide
        positionRoles: ["deep", "handler", "cutter"],
        eventVocabulary: [.matchStart, .matchEnd, .periodStart, .periodEnd,
                          .subIn, .subOut, .goalForUs, .goalAgainstUs, .goalMine, .assist,
                          .flag, .turnover, .timeout],
        hasGoalkeeper: false
    )

    public static let all: [SportProfile] = [soccer, lacrosse, fieldHockey, rugby, ultimate]

    /// Look up a preset by its `id`; `nil`/unknown resolves to soccer (the default sport).
    public static func profile(for id: String?) -> SportProfile {
        guard let id else { return .soccer }
        return all.first { $0.id == id } ?? .soccer
    }
}
