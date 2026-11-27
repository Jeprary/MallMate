import Foundation

enum RouteLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case chinese = "zh"

    static let preferenceKey = "routewalk.language"
    static let didChange = Notification.Name("RouteWalkLanguageDidChange")

    static var preference: RouteLanguage {
        get { RouteLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system }
        set {
            guard newValue != preference else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
            if Thread.isMainThread {
                NotificationCenter.default.post(name: didChange, object: nil)
            } else {
                DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
            }
        }
    }

    static var current: RouteLanguage {
        let selection = preference
        return selection == .system ? resolve(Locale.preferredLanguages) : selection
    }

    static func resolve(_ identifiers: [String]) -> RouteLanguage {
        for identifier in identifiers {
            let language = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            if language == "zh" { return .chinese }
            if language == "en" { return .english }
        }
        return .english
    }

    static func text(_ en: String, _ zh: String) -> String {
        current.select(en, zh)
    }

    func select(_ en: String, _ zh: String) -> String {
        self == .chinese ? zh : en
    }

    static func format(_ en: String, _ zh: String, _ values: CVarArg...) -> String {
        let language = current
        let locale = Locale(identifier: language == .chinese ? "zh-Hans" : "en")
        return String(format: language == .chinese ? zh : en, locale: locale, arguments: values)
    }
}

/// A live status may outlast the selected language, so keep both translations until presentation.
struct RouteText: Equatable, Sendable {
    let english: String
    let chinese: String
    init(_ english: String, _ chinese: String) {
        self.english = english
        self.chinese = chinese
    }
    var localized: String { RouteLanguage.text(english, chinese) }

    func localized(in language: RouteLanguage) -> String { language.select(english, chinese) }
}
