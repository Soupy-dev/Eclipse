import SwiftUI
import ObjectiveC

private var eclipseLanguageBundleKey: UInt8 = 0

private final class EclipseLocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &eclipseLanguageBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {

    private static let activateEclipseLocalization: Void = {
        object_setClass(Bundle.main, EclipseLocalizedBundle.self)
    }()

    static func setEclipseLanguage(_ code: String) {
        _ = activateEclipseLocalization

        let candidates = [
            code,
            code.replacingOccurrences(of: "-", with: "_"),
            String(code.prefix(2))
        ]

        var selected: Bundle?
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                selected = bundle
                break
            }
        }

        objc_setAssociatedObject(
            Bundle.main,
            &eclipseLanguageBundleKey,
            selected,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

final class LocalizationManager: NSObject, ObservableObject {
    static let shared = LocalizationManager()

    static let tmdbLanguageKey = "tmdbLanguage"
    static let defaultTMDBCode = "en-US"

    private static let uiCodeByTMDBCode: [String: String] = [
        "en-US": "en",       "en-GB": "en-GB",
        "es-ES": "es",       "es-MX": "es-419",
        "fr": "fr",          "de": "de",
        "it": "it",          "pt-BR": "pt-BR",
        "ja": "ja",          "ko": "ko",
        "zh-CN": "zh-Hans",  "zh-TW": "zh-Hant",
        "ru": "ru",          "ar": "ar",
        "hi": "hi",          "th": "th",
        "tr": "tr",          "pl": "pl",
        "nl": "nl",          "sv": "sv",
        "da": "da",          "no": "nb",
        "fi": "fi"
    ]

    @Published private(set) var locale: Locale
    @Published private(set) var layoutDirection: LayoutDirection

    private var observedStore: UserDefaults?

    private override init() {
        let tmdbCode = ProfileSettingsStore.active.string(forKey: Self.tmdbLanguageKey) ?? Self.defaultTMDBCode
        let uiCode = Self.uiCode(forTMDB: tmdbCode)

        Bundle.setEclipseLanguage(uiCode)
        self.locale = Locale(identifier: uiCode)
        self.layoutDirection = Self.layoutDirection(forUICode: uiCode)

        super.init()

        observedStore = ProfileSettingsStore.active
        observedStore?.addObserver(
            self,
            forKeyPath: Self.tmdbLanguageKey,
            options: [.new],
            context: nil
        )
    }

    func reloadForActiveProfile() {
        let store = ProfileSettingsStore.active
        if observedStore !== store {
            observedStore?.removeObserver(self, forKeyPath: Self.tmdbLanguageKey)
            observedStore = store
            store.addObserver(self, forKeyPath: Self.tmdbLanguageKey, options: [.new], context: nil)
        }
        let tmdbCode = store.string(forKey: Self.tmdbLanguageKey) ?? Self.defaultTMDBCode
        apply(uiCode: Self.uiCode(forTMDB: tmdbCode))
    }

    deinit {
        observedStore?.removeObserver(self, forKeyPath: Self.tmdbLanguageKey)
    }

    static func uiCode(forTMDB tmdbCode: String) -> String {
        uiCodeByTMDBCode[tmdbCode] ?? String(tmdbCode.prefix(2))
    }

    private static func layoutDirection(forUICode uiCode: String) -> LayoutDirection {
        let language = String(uiCode.prefix(2))
        return Locale.characterDirection(forLanguage: language) == .rightToLeft ? .rightToLeft : .leftToRight
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.tmdbLanguageKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let tmdbCode = ProfileSettingsStore.active.string(forKey: Self.tmdbLanguageKey) ?? Self.defaultTMDBCode
        apply(uiCode: Self.uiCode(forTMDB: tmdbCode))
    }

    private func apply(uiCode: String) {
        Bundle.setEclipseLanguage(uiCode)
        let newLocale = Locale(identifier: uiCode)
        let newDirection = Self.layoutDirection(forUICode: uiCode)

        let publish = {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.locale = newLocale
                self.layoutDirection = newDirection
            }
        }

        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }
}
