// LegalLinks.swift
// MatchTracker

import Foundation

/// Links App Review requires beside a subscription (guideline 3.1.2). The pages are in the
/// nicemohawk/nml-website repository, under `matchtracker`. A first version; have a lawyer read them.
enum LegalLinks {
    static let termsOfUse = URL(string: "https://nicemohawk.com/matchtracker/terms/")!
    static let privacyPolicy = URL(string: "https://nicemohawk.com/matchtracker/privacy/")!
}
