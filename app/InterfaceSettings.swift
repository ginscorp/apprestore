import SwiftUI
import AppKit
import Combine

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case russian = "ru", english = "en"
    var id: String { rawValue }
    var title: String { self == .russian ? "Русский" : "English" }
    static var selected: InterfaceLanguage {
        if let saved = UserDefaults.standard.string(forKey: "interfaceLanguage"), let value = Self(rawValue: saved) { return value }
        return .russian // Preserve the language of existing installations until explicitly changed.
    }
}

enum InterfaceTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("Как в macOS"); case .light: return L("Светлая"); case .dark: return L("Темная") }
    }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

@MainActor final class InterfaceSettings: ObservableObject {
    static let shared = InterfaceSettings()
    @Published var language: InterfaceLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "interfaceLanguage") }
    }
    @Published var theme: InterfaceTheme {
        didSet { guard theme != oldValue else { return }; UserDefaults.standard.set(theme.rawValue, forKey: "interfaceTheme"); applyAppearance() }
    }
    @Published var allowPasswordSaving=false {
        didSet {UserDefaults.standard.set(allowPasswordSaving,forKey:"allowPersonalPasswordSaving")}
    }
    var locale: Locale { Locale(identifier: language.rawValue) }
    private init() {
        language = .selected
        theme = InterfaceTheme(rawValue: UserDefaults.standard.string(forKey: "interfaceTheme") ?? "system") ?? .system
        allowPasswordSaving = PersonalPasswordVault.supported && UserDefaults.standard.bool(forKey:"allowPersonalPasswordSaving")
    }
    private var appearanceTask: Task<Void,Never>?
    func applyAppearance() {
        appearanceTask?.cancel()
        appearanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:100_000_000)
            guard !Task.isCancelled,let self else { return }
            let desired: NSAppearance? = theme == .system ? nil : NSAppearance(named:theme == .dark ? .darkAqua:.aqua)
            NSApp.appearance = desired
            // AppKit owns every window, including Settings and its title bar.
            for window in NSApp.windows { window.appearance = nil }
        }
    }
}

// Only application-authored keys are localized. Catalog titles and Apple data stay verbatim.
private enum LocalizationBundles {
    static let values: [String:Bundle] = Dictionary(uniqueKeysWithValues:["ru","en"].compactMap { language in
        guard let path=Bundle.main.path(forResource:language,ofType:"lproj"),let bundle=Bundle(path:path) else{return nil}
        return (language,bundle)
    })
}
func L(_ key: String) -> String {
    LocalizationBundles.values[InterfaceLanguage.selected.rawValue]?.localizedString(forKey:key,value:key,table:"Localizable") ?? key
}

func LF(_ key: String, _ arguments: String...) -> String { localizedFormat(key, arguments) }
private func localizedFormat(_ key: String, _ arguments: [String]) -> String {
    String(format: L(key), locale: Locale(identifier: InterfaceLanguage.selected.rawValue), arguments: arguments)
}

func localizedBackupMessage(_ source: String) -> String {
    if let match = source.range(of: "^Резервная копия · проверено [0-9]+ файлов$", options:.regularExpression), match == source.startIndex..<source.endIndex {
        let count = source.components(separatedBy:" ").first { Int($0) != nil } ?? "0"
        return LF("Резервная копия · проверено %@ файлов", count)
    }
    let prefix = "Резервная копия не подтверждена ["
    if source.hasPrefix(prefix), source.hasSuffix("]") {
        return L("Резервная копия не подтверждена") + " [" + source.dropFirst(prefix.count)
    }
    return L(source)
}

indirect enum UIMessage: ExpressibleByStringLiteral {
    case key(String), format(String, [String]), sequence([UIMessage]), literal(String)
    init(stringLiteral value: String) { self = .key(value) }
    var text: String {
        switch self {
        case .key(let key): return L(key)
        case .format(let key, let values): return localizedFormat(key, values)
        case .sequence(let parts): return parts.map(\.text).joined()
        case .literal(let value): return value
        }
    }
    var isEmpty: Bool { text.isEmpty }
}

enum Palette {
    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let canvas = adaptive("Canvas",light:NSColor(srgbRed:0.94,green:0.95,blue:0.97,alpha:1),dark:.windowBackgroundColor)
    static let surface = Color(nsColor:.controlBackgroundColor)
    static let card = adaptive("Card",light:.white,dark:NSColor(srgbRed:0.16,green:0.17,blue:0.185,alpha:1))
    static let ink = Color(nsColor:.labelColor)
    static let muted = Color(nsColor:.secondaryLabelColor)
    static let border = adaptive("CardBorder",light:NSColor(srgbRed:0.48,green:0.51,blue:0.57,alpha:1),dark:.separatorColor)
    static let accent = Color.accentColor
    static let hero = Color.accentColor
}

// Standard title-bar controls are provided by Window.windowStyle(.titleBar).
struct PreferencesView: View {
    @ObservedObject private var settings = InterfaceSettings.shared
    @ObservedObject private var profiles = LocalAccounts.shared
    var body: some View {
        Form {
            Section {
                Picker(L("Язык"), selection:$settings.language) {
                    ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("language-control")
                Picker(L("Оформление"), selection:$settings.theme) {
                    ForEach(InterfaceTheme.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).id(settings.language).accessibilityIdentifier("theme-control")
            } header: { Text(L("Интерфейс")) }
            Text(L("Язык и тема меняются сразу. Перезапуск и повторный вход в Apple ID не нужны."))
                .font(.caption).foregroundStyle(.secondary)
            Section {
                Label(L("Штатные кнопки и полноэкранный режим macOS"), systemImage:"macwindow")
                Text(L("В полноэкранном режиме наведи указатель к верхнему краю экрана, чтобы показать меню и кнопки окна."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Разрешить сохранение личных паролей"),isOn:$settings.allowPasswordSaving)
                    .disabled(!PersonalPasswordVault.supported).accessibilityIdentifier("password-saving-control")
                Text(L(PersonalPasswordVault.supported ? "Только Связка ключей этого Mac, с подтверждением macOS. Сохранение каждого личного аккаунта выбирается отдельно при входе." : "Защищенное сохранение паролей недоступно в локальной сборке. Нужны подпись и профиль Apple Developer. Пароли в файлы не записываются."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Гостевые аккаунты не сохраняются. Коды 2FA, cookies и сеансы не сохраняются ни в одном режиме."))
                    .font(.caption).foregroundStyle(.secondary)
            } header:{Text(L("Пароли и безопасность"))}
            Section {
                if profiles.accounts.isEmpty {Text(L("Сохраненных личных Apple ID пока нет")).foregroundStyle(.secondary)}
                ForEach(profiles.accounts) {account in
                    HStack {
                        VStack(alignment:.leading,spacing:3){Text(account.appleID);Text(L(account.passwordSaved ? "Пароль в Связке ключей" : "Сохранен только Apple ID")).font(.caption).foregroundStyle(.secondary)}
                        Spacer();Button(L("Забыть…")){profiles.pendingRemoval=account.id}
                    }
                }
                Text(L("Для добавления выбери личный режим в окне входа и отметь сохранение Apple ID. Этот список не входит в публичный кеш и резерв на Резервная копия."))
                    .font(.caption).foregroundStyle(.secondary)
                if !profiles.message.isEmpty {Text(profiles.message.text).font(.caption).foregroundStyle(.secondary)}
            } header:{Text(L("Личные аккаунты на этом Mac"))}
        }.formStyle(.grouped).padding(12).frame(width:580,height:620)
        .environment(\.locale,settings.locale)
        .confirmationDialog(L("Забыть выбранный личный аккаунт на этом Mac?"),isPresented:Binding(get:{profiles.pendingRemoval != nil},set:{if !$0 {profiles.pendingRemoval=nil}}),titleVisibility:.visible) {
            Button(L("Забыть аккаунт"),role:.destructive) {if let id=profiles.pendingRemoval {Task{await profiles.remove(id)}};profiles.pendingRemoval=nil}
        }
    }
}

func humanSize(_ bytes:Int64)->String {HumanFormat.size(bytes,locale:Locale(identifier:InterfaceLanguage.selected.rawValue))}
func humanDuration(_ seconds:Double?)->String {HumanFormat.duration(seconds:seconds,locale:Locale(identifier:InterfaceLanguage.selected.rawValue))}
