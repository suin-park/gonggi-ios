import Foundation
import Observation
import SwiftUI

/// In-app UI language (English default on first launch, saved choice afterwards).
/// All app-owned copy goes through `L(_:)`, which reads `Localizable.xcstrings` (compiled per language into the
/// app bundle) for the selected language. `AppLanguage` is `@Observable`: any view whose body called `L(...)`
/// re-renders when the language changes — no view identity reset, so capture / generation / viewer state is
/// never restarted. System UI (permission prompts, keyboard) keeps following the device language.
@Observable
final class AppLanguage {
    static let shared = AppLanguage()
    static let defaultsKey = "whik.language.v1"

    enum Code: String, CaseIterable, Identifiable {
        case en
        case ko
        case ja
        case zhHans = "zh-Hans"

        var id: String { rawValue }

        /// Language name in its own language (shown in the picker).
        var nativeName: String {
            switch self {
            case .en: return "English"
            case .ko: return "한국어"
            case .ja: return "日本語"
            case .zhHans: return "简体中文"
            }
        }
    }

    private(set) var code: Code
    private(set) var bundle: Bundle
    private(set) var locale: Locale

    init(defaults: UserDefaults = .standard) {
        let stored = Self.resolve(stored: defaults.string(forKey: Self.defaultsKey))
        code = stored
        bundle = Self.bundle(for: stored)
        locale = Locale(identifier: stored.rawValue)
    }

    /// Saved value → language; nothing saved (first launch) or an unknown value is English.
    static func resolve(stored: String?) -> Code {
        stored.flatMap(Code.init(rawValue:)) ?? .en
    }

    func set(_ new: Code, defaults: UserDefaults = .standard) {
        guard new != code else { return }
        defaults.set(new.rawValue, forKey: Self.defaultsKey)
        bundle = Self.bundle(for: new)
        locale = Locale(identifier: new.rawValue)
        code = new
    }

    static func bundle(for code: Code) -> Bundle {
        if let path = Bundle.main.path(forResource: code.rawValue, ofType: "lproj"), let b = Bundle(path: path) {
            return b
        }
        return Bundle.main
    }

    /// Looks the key up in the selected language; falls back to English, then to the key text itself
    /// (keys are the English source strings, so a missing entry never shows an identifier).
    func string(_ key: String) -> String {
        let missing = "\u{1}__missing__"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        if value != missing { return value }
        let english = Self.bundle(for: .en).localizedString(forKey: key, value: missing, table: "Localizable")
        return english == missing ? key : english
    }
}

/// App-owned UI string in the selected language. Key = English source text (see Localizable.xcstrings).
func L(_ key: String) -> String {
    AppLanguage.shared.string(key)
}

/// Formatted variant: the key contains %@ / %lld / %1$@ placeholders; numbers are formatted for the language.
func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = AppLanguage.shared
    return String(format: lang.string(key), locale: lang.locale, arguments: args)
}

extension View {
    /// Root: number / date formatting and `Text(LocalizedStringKey)` follow the in-app language.
    func whikLanguageEnvironment() -> some View {
        environment(\.locale, AppLanguage.shared.locale)
    }
}

/// Dates shown by the app (formatted for the selected language, not the device region).
enum WhikDate {
    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().locale(AppLanguage.shared.locale))
    }

    static func shortWithTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(AppLanguage.shared.locale))
    }
}

/// Names given to new records automatically, in the selected language. Existing or user-typed names are never
/// rewritten; only new records use these.
enum WhikAutoName {
    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// e.g. "New space Oct 25" / "새 공간 10월 25일".
    static func space(_ date: Date) -> String {
        L("New space %@", formatter("MMMd").string(from: date))
    }

    /// e.g. "3D Object Oct 25, 14:05".
    static func object(_ date: Date) -> String {
        L("3D Object %@", formatter("MMMdjmm").string(from: date))
    }

    /// 360° jobs created before their server name arrives, e.g. "Oct 25 space".
    static func dailySpace(_ date: Date) -> String {
        L("%@ space", formatter("MMMd").string(from: date))
    }
}
