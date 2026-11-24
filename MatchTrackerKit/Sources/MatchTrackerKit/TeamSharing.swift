import Foundation

/// Which team a match goes to.
public enum TeamSharing {
    /// - Parameters:
    ///   - recorded: The team the watch believed in at kickoff. Empty for nobody, nil when it isn't known.
    ///   - chosen: The phone's choice now. Empty for nobody.
    ///   - chosenAt: When that was chosen, if it's known.
    /// - Returns: Nil for nobody.
    public static func code(recorded: String?, chosen: String, chosenAt: Date?, start: Date) -> String? {
        let code: String?
        if let chosenAt, chosenAt <= start {
            // Chosen before kickoff, so it's what was meant, whether or not the watch had heard.
            code = chosen
        } else if chosenAt != nil {
            // Changed since. What the watch knew at the time stands, and what nobody knew isn't shared.
            code = recorded
        } else {
            code = recorded ?? chosen
        }
        return code.flatMap { $0.isEmpty ? nil : $0 }
    }
}
