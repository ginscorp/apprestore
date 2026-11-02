import Foundation
import Security
import LocalAuthentication
import Combine

enum AccountMode: String, CaseIterable, Identifiable {
    case guest, personal
    var id:String {rawValue}
    var title:String {L(self == .guest ? "Гостевой аккаунт" : "Личный аккаунт")}
}
struct LocalAccount: Codable, Identifiable {
    let id:UUID
    let appleID:String
    var passwordSaved:Bool = false
}
struct LocalAccountIndex: Codable {var schema=1;var accounts:[LocalAccount]=[]}

enum PersonalPasswordVault {
    private static let service="org.example.apprestore.public.personal-apple-login"
    // No legacy-keychain, file, cloud or unprotected fallback if modern protection is unavailable.
    static var supported:Bool {
        var own:SecCode?;guard SecCodeCopySelf([], &own)==errSecSuccess,let own else{return false}
        var ownStatic:SecStaticCode?;guard SecCodeCopyStaticCode(own,[],&ownStatic)==errSecSuccess,let ownStatic else{return false}
        var info:CFDictionary?
        guard SecCodeCopySigningInformation(ownStatic,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let dictionary=info as? [String:Any],let entitlements=dictionary[kSecCodeInfoEntitlementsDict as String] as? [String:Any],
              let identifier=entitlements["com.apple.application-identifier"] as? String,
              let team=dictionary[kSecCodeInfoTeamIdentifier as String] as? String,!team.isEmpty,
              identifier == team+"."+(Bundle.main.bundleIdentifier ?? "") else{return false}
        return Bundle.main.bundleIdentifier == "org.example.apprestore.public"
    }
    static func validAccount(_ account:String)->Bool {
        !account.isEmpty && account.utf8.count<=254 && !account.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}
    }
    private static func base(_ account:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:account.lowercased(),kSecAttrSynchronizable as String:false,
         kSecUseDataProtectionKeychain as String:true]
    }
    private static func context(_ reason:String)->LAContext {let value=LAContext();value.localizedReason=reason;return value}
    static func save(account:String,password:String,personalConsent:Bool) async throws {
        guard personalConsent,validAccount(account),!password.isEmpty,password.utf8.count<=8192 else{throw BridgeError(code:"personal_consent_required")}
        guard supported else{throw BridgeError(code:"protected_keychain_unavailable")}
        let reason=L("Сохранить пароль личного Apple ID в Связке ключей на этом Mac")
        try await Task.detached {
            guard let control=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,.userPresence,nil) else{throw BridgeError(code:"protected_keychain_unavailable")}
            var query=base(account)
            query[kSecAttrAccessControl as String]=control
            query[kSecAttrLabel as String]="AppRestore · "+account
            query[kSecValueData as String]=Data(password.utf8)
            query[kSecUseAuthenticationContext as String]=context(reason)
            let added=SecItemAdd(query as CFDictionary,nil)
            if added==errSecDuplicateItem {
                var match=base(account);match[kSecUseAuthenticationContext as String]=context(reason)
                let status=SecItemUpdate(match as CFDictionary,[kSecValueData as String:Data(password.utf8)] as CFDictionary)
                guard status==errSecSuccess else{throw BridgeError(code:"protected_keychain_write_failed")}
            } else if added != errSecSuccess {throw BridgeError(code:"protected_keychain_write_failed")}
        }.value
    }
    static func load(account:String,personalConsent:Bool) async throws->String {
        guard personalConsent,validAccount(account),supported else{throw BridgeError(code:"protected_keychain_unavailable")}
        let reason=L("Заполнить пароль выбранного личного Apple ID в AppRestore")
        return try await Task.detached {
            var query=base(account);query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String]=context(reason)
            var result:CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,
                  var bytes=result as? Data else{throw BridgeError(code:"protected_keychain_read_failed")}
            defer{bytes.resetBytes(in:0..<bytes.count)}
            guard let password=String(data:bytes,encoding:.utf8),!password.isEmpty,password.utf8.count<=8192 else{throw BridgeError(code:"protected_keychain_read_failed")}
            return password
        }.value
    }
    static func forget(account:String) async throws {
        guard supported,validAccount(account) else{throw BridgeError(code:"protected_keychain_unavailable")}
        try await Task.detached {
            let result=SecItemDelete(base(account) as CFDictionary)
            guard result==errSecSuccess || result==errSecItemNotFound else{throw BridgeError(code:"protected_keychain_delete_failed")}
        }.value
    }
}

@MainActor final class LocalAccounts: ObservableObject {
    static let shared=LocalAccounts()
    @Published private(set) var accounts:[LocalAccount]=[]
    @Published var message:UIMessage=""
    @Published var pendingRemoval:UUID?
    private let directory:URL
    private var healthy=true
    private var file:URL {directory.appendingPathComponent("local-profiles.json")}
    init(root:URL?=nil) {
        let preview=PublicEdition.preview
        #if APPRESTORE_LAYOUT_TEST
        directory=root ?? FileManager.default.temporaryDirectory.appendingPathComponent("AppRestore-layout-\(getpid())/Accounts")
        #else
        directory=root ?? PublicEdition.dataRoot.appendingPathComponent(preview ? "PreviewAccounts" : "LocalAccounts")
        #endif
        do {
            try verifyRoot()
            if FileManager.default.fileExists(atPath:file.path) {
                let data=try Data(contentsOf:file);guard data.count<=32768 else{throw BridgeError(code:"invalid_local_profiles")}
                let value=try JSONDecoder().decode(LocalAccountIndex.self,from:data)
                let object=try JSONSerialization.jsonObject(with:data) as? NSDictionary
                let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [AnyHashable:Any]
                guard value.schema==1,value.accounts.count<=20,value.accounts.allSatisfy({PersonalPasswordVault.validAccount($0.appleID)}),Set(value.accounts.map(\.id)).count==value.accounts.count,
                      let object,let canonical,object.isEqual(to:canonical) else{throw BridgeError(code:"invalid_local_profiles")}
                accounts=value.accounts
            }
        } catch {healthy=false;message="Список личных аккаунтов требует проверки. Файл не изменен."}
    }
    private func verifyRoot() throws {
        guard directory.resolvingSymlinksInPath().path==directory.standardizedFileURL.path else{throw BridgeError(code:"unsafe_local_profiles")}
        if FileManager.default.fileExists(atPath:file.path) {
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true else{throw BridgeError(code:"unsafe_local_profiles")}
        }
    }
    private func persist(_ value:[LocalAccount]) throws {
        guard healthy else{throw BridgeError(code:"invalid_local_profiles")}
        try verifyRoot();guard value.count<=20 else{throw BridgeError(code:"local_profiles_limit")}
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(LocalAccountIndex(accounts:value));try data.write(to:file,options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        guard try Data(contentsOf:file)==data else{throw BridgeError(code:"local_profiles_write_failed")}
        accounts=value
    }
    func saveName(_ appleID:String,passwordSaved:Bool=false,personalConsent:Bool) throws {
        guard personalConsent,PersonalPasswordVault.validAccount(appleID) else{throw BridgeError(code:"personal_consent_required")}
        var copy=accounts
        if let index=copy.firstIndex(where:{$0.appleID.lowercased()==appleID.lowercased()}) {copy[index].passwordSaved = copy[index].passwordSaved || passwordSaved}
        else {copy.append(LocalAccount(id:UUID(),appleID:appleID,passwordSaved:passwordSaved))}
        try persist(copy)
    }
    func remove(_ id:UUID) async {
        guard let account=accounts.first(where:{$0.id==id}) else{return}
        do {
            if account.passwordSaved {try await PersonalPasswordVault.forget(account:account.appleID)}
            try persist(accounts.filter{$0.id != id});message="Личный аккаунт забыт на этом Mac."
        } catch {message="Не удалось забыть личный аккаунт. Данные сохранены; нужна проверка."}
    }
}
