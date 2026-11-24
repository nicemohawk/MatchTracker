// LegalLinks.swift
// MatchTracker

import Foundation

/// Links App Review requires beside a subscription (guideline 3.1.2).
///
/// OWNER MUST SUPPLY BOTH BEFORE RELEASE. They are nil because nobody has provided real pages yet;
/// nothing is linked until they are. If the app uses Apple's standard license agreement, the terms
/// link is https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
enum LegalLinks {
    static let termsOfUse: URL? = nil
    static let privacyPolicy: URL? = nil
}

#if !DEBUG
#warning("LegalLinks: supply the Terms of Use and Privacy Policy URLs before submitting.")
#endif
