import Foundation
import OSLog

enum AppLog {
    static let auth = Logger(subsystem: "WHOOPHealthSync", category: "auth")
    static let api = Logger(subsystem: "WHOOPHealthSync", category: "api")
    static let sleep = Logger(subsystem: "WHOOPHealthSync", category: "sleep")
    static let heartRate = Logger(subsystem: "WHOOPHealthSync", category: "heartRate")
    static let healthKit = Logger(subsystem: "WHOOPHealthSync", category: "healthKit")
    static let persistence = Logger(subsystem: "WHOOPHealthSync", category: "persistence")
    static let sync = Logger(subsystem: "WHOOPHealthSync", category: "sync")
}

enum AppLocalization {
    /// Same resolution as AppLanguage.locale, for code that runs outside the SwiftUI environment.
    static var locale: Locale {
        switch UserDefaults.standard.string(forKey: "appLanguage") {
        case "english": return Locale(identifier: "en")
        case "spanish": return Locale(identifier: "es")
        case "polish": return Locale(identifier: "pl")
        default:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if preferred.hasPrefix("es") { return Locale(identifier: "es") }
            if preferred.hasPrefix("pl") { return Locale(identifier: "pl") }
            return Locale(identifier: "en")
        }
    }

    // String(localized:locale:) only formats with the locale; a resource locale also selects the .lproj table.
    static func string(_ key: String.LocalizationValue, locale: Locale = AppLocalization.locale) -> String {
        String(localized: LocalizedStringResource(key, locale: locale))
    }
}

enum SensitiveTextSanitizer {
    static func redact(_ text: String) -> String {
        var output = text
        let replacements: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[redacted-email]"),
            (#"\bauthorization\s*[:=]\s*Bearer\s+[A-Za-z0-9._\-]+"#, "Authorization: Bearer [redacted-token]"),
            (#"Bearer\s+[A-Za-z0-9._\-]+"#, "Bearer [redacted-token]"),
            (#"\bauthorization\s*[:=]\s*Basic\s+[A-Za-z0-9._~+/\-=]+"#, "Authorization: Basic [redacted-token]"),
            (#"\bauthorization\s*[:=]\s*(?!Bearer\b|Basic\b)[^\s,;]+"#, "Authorization=[redacted]"),
            (#"\b[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b"#, "[redacted-jwt]"),
            (#"\b(access[_-]?token|refresh[_-]?token|id[_-]?token|password|mfa[_-]?code|sms_mfa_code|software_token_mfa_code|email_otp_code)\s*[:=]\s*[^\s,;]+"#, "$1=[redacted]")
        ]
        for replacement in replacements {
            output = output.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return output
    }
}
