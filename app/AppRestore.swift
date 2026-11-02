import SwiftUI
import AppKit
import Combine
import Darwin

// The pipe has no listening socket, credential arguments, terminal output or disk log.
final class EngineBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "apprestore.engine")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()
    private let lock = NSLock()
    private var child: Process?
    private func start() throws {
        if process?.isRunning == true { return }
        guard let resources = Bundle.main.resourceURL else { throw BridgeError(code: "engine_missing") }
        let p = Process(); p.executableURL = resources.appendingPathComponent("apprestore-engine")
        let publicCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AppRestorePublic/Catalog")
        p.environment = ["PATH":"/usr/bin:/bin", "APPRESTORE_RUNTIME":resources.appendingPathComponent("Runtime").path,
                         "APPRESTORE_CATALOG_SEED":resources.appendingPathComponent("Catalog").path,
                         "APPRESTORE_CATALOG_CACHE":publicCache.path, "APPRESTORE_LIBRARY":PublicEdition.dataRoot.appendingPathComponent("Library").path, "TMPDIR":NSTemporaryDirectory()]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run(); process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffered.removeAll()
        lock.lock(); child = p; lock.unlock()
    }
    func call(_ payload: [String:Any]) async throws -> [String:Any] {
        guard !PublicEdition.preview else { throw BridgeError(code:"preview_read_only") }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.start()
                    var data = try JSONSerialization.data(withJSONObject: payload); data.append(10)
                    try self.input?.write(contentsOf: data); data.resetBytes(in: 0..<data.count)
                    while !self.buffered.contains(10) {
                        guard let chunk = self.output?.availableData, !chunk.isEmpty else { throw BridgeError(code: "engine_stopped") }
                        self.buffered.append(chunk)
                        if self.buffered.count > 8_000_000 { throw BridgeError(code: "invalid_response") }
                    }
                    let end = self.buffered.firstIndex(of: 10)!
                    let line = self.buffered[..<end]; let decoded = try JSONSerialization.jsonObject(with: line) as? [String:Any]
                    self.buffered.removeSubrange(...end)
                    guard let response = decoded else { throw BridgeError(code: "invalid_response") }
                    if let diagnostic = response["diagnostic"], let bytes = try? JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys,.prettyPrinted]),bytes.count<32768 {
                        let file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AppRestorePublic/diagnostic-last-check.json")
                        try? bytes.write(to:file,options:.atomic)
                        if response["ok"] as? Bool != true {throw BridgeError(code:response["error"] as? String ?? "apple_request_failed",diagnostic:String(data:bytes,encoding:.utf8))}
                    }
                    guard response["ok"] as? Bool == true else { throw BridgeError(code: response["error"] as? String ?? "apple_request_failed") }
                    continuation.resume(returning: response["data"] as? [String:Any] ?? [:])
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() {
        lock.lock(); let running = child; child = nil; lock.unlock()
        // EOF normally runs the helper's cleanup; termination is a bounded fallback.
        queue.async { try? self.input?.close(); self.process = nil; self.input = nil; self.output = nil; self.buffered.removeAll() }
        if let running, running.isRunning { running.terminate() }
    }
    deinit {
        // Do not enqueue a closure retaining self from deinit. SwiftUI can
        // discard an unused view/model during scene recomputation.
        try? input?.close()
        if let child,child.isRunning {child.terminate()}
        try? output?.close()
        buffered.resetBytes(in:0..<buffered.count)
    }
}

final class USBBridge: @unchecked Sendable {
    private let queue=DispatchQueue(label:"apprestore.usb")
    private let lock=NSLock()
    private var child:Process?
    private var cancelled=false
    func cancel() {lock.lock();cancelled=true;let p=child;lock.unlock();p?.terminate()}
    func call(_ payload:[String:Any],progress:(@Sendable ([String:Any])->Void)?=nil) async throws ->[String:Any] {
        guard !PublicEdition.preview else { throw BridgeError(code:"preview_read_only") }
        return try await withCheckedThrowingContinuation {continuation in
            queue.async {
                do {
                    guard let resources=Bundle.main.resourceURL else{throw BridgeError(code:"usb_missing")}
                    let p=Process();p.executableURL=resources.appendingPathComponent("USB/apprestore-usb")
                    p.environment=["PATH":"/usr/bin:/bin","PYTHONNOUSERSITE":"1","PYTHONDONTWRITEBYTECODE":"1","TMPDIR":NSTemporaryDirectory()]
                    let input=Pipe(),output=Pipe();p.standardInput=input;p.standardOutput=output;p.standardError=FileHandle.nullDevice
                    self.lock.lock();self.cancelled=false;self.child=p;self.lock.unlock()
                    defer {self.lock.lock();self.child=nil;self.lock.unlock();if p.isRunning{p.terminate()}}
                    try p.run()
                    var request=try JSONSerialization.data(withJSONObject:payload);request.append(10)
                    try input.fileHandleForWriting.write(contentsOf:request);request.resetBytes(in:0..<request.count);try input.fileHandleForWriting.close()
                    var buffer=Data();var result:[String:Any]?
                    while result == nil {
                        let chunk=output.fileHandleForReading.availableData
                        guard !chunk.isEmpty else {
                            self.lock.lock();let wasCancelled=self.cancelled;self.lock.unlock()
                            throw BridgeError(code:wasCancelled ? "operation_cancelled" : "usb_failed")
                        }
                        buffer.append(chunk);guard buffer.count<=16*1024*1024 else{throw BridgeError(code:"invalid_response")}
                        while let end=buffer.firstIndex(of:10) {
                            let data=Data(buffer[..<end]);buffer.removeSubrange(...end)
                            guard let response=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw BridgeError(code:"invalid_response")}
                            if let event=response["event"] as? String {
                                if event == "progress",let fraction=response["fraction"] as? Double,fraction.isFinite,(0...1).contains(fraction){progress?(["event":"progress","fraction":fraction])}
                                else if event == "storage_ready"{progress?(["event":"storage_ready"])}
                                else if event == "job",let directory=response["directory"] as? String,directory.count<4096 {progress?(["event":"job","directory":directory])}
                                continue
                            }
                            guard response["ok"] as? Bool == true else{throw BridgeError(code:response["error"] as? String ?? "usb_failed")}
                            result=response["data"] as? [String:Any] ?? [:]
                        }
                    }
                    p.waitUntilExit();guard p.terminationStatus==0 else{throw BridgeError(code:"usb_failed")}
                    continuation.resume(returning:result ?? [:])
                } catch {continuation.resume(throwing:error)}
            }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var apps: [CatalogApp] = [] { didSet { updateFiltered() } }
    @Published var statuses: [CatalogStatus] = []
    @Published var search = "" { didSet { updateFiltered() } }
    @Published var selected: Int64?
    @Published var busy = false
    var diagnosticCollectionPaused = false
    @Published var message: UIMessage = "Проверяем обновления каталогов…"
    @Published var account = ""
    @Published var needsCode = false
    @Published var licenseChecked: Int64?
    @Published var availableVersion = ""
    @Published var packagePath = ""
    @Published var packageApp: Int64?
    @Published var devices: [Device] = []
    @Published var target = ""
    @Published var sourceApps: [DeviceApp] = []
    @Published var showTransfer = false
    @Published var confirmInstall = false
    @Published var confirmAcquire = false
    let preview: Bool
    let media: CatalogMedia
    @Published var sort = CatalogSort(rawValue:UserDefaults.standard.string(forKey:"catalogSort") ?? "nameAscending") ?? .nameAscending { didSet { updateFiltered() } }
    @Published var section = "Все приложения" { didSet { updateFiltered() } }
    @Published var cacheUsed = false
    @Published var cacheStored = false
    @Published var lastOperation: UIMessage = ""
    @Published var checkDiagnostic = ""
    @Published var compatibility:PackageCompatibility?
    private var preparedTarget=""
    init(preview: Bool = false) { self.preview = preview; self.media = CatalogMedia(preview:preview) }
    let engine = EngineBridge()
    let usb = USBBridge()
    var selectedApp: CatalogApp? { apps.first { $0.id == selected } }
    @Published private(set) var filtered: [CatalogApp] = []
    private func updateFiltered() {
        let q = search.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().replacingOccurrences(of:"online",with:"онлайн")
        let queried = q.isEmpty ? apps : apps.filter { $0.searchable.contains(q) }
        let categorized = section == "Все приложения" ? queried : queried.filter { $0.category == section }
        filtered = sort.order(categorized)
    }
    func decode<T:Decodable>(_ type:T.Type,_ object:Any) throws -> T { try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:object)) }
    func refresh() async {
        guard !busy && account.isEmpty else { return }; if preview { loadBundledPreview(); return }; busy = true; defer { busy = false }
        do { let data = try await engine.call(["action":"catalog"]); let result = try decode(CatalogPayload.self,data)
            apps = result.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }; statuses = result.status; media.setCatalog(apps)
            let fallback = statuses.contains { !["updated","unchanged"].contains($0.status) }
            message = fallback ? "Каталог готов. Часть источников доступна из сохраненной копии." : .format("Каталоги обновлены: %@ приложений.",[String(apps.count)])
        } catch { fail(error) }
    }
    func login(email:String,password:String,code:String) async {
        guard !busy && !preview else {return}; lastOperation = "Вход в App Store"; busy = true; message = "Входим в App Store…"; defer { busy = false }
        do { let data = try await engine.call(["action":"login","email":email,"password":password,"code":code]); account = data["email"] as? String ?? email; needsCode = false; message = "Сеанс открыт. Выбери приложение и проверь доступность." }
        catch { if (error as? BridgeError)?.code == "two_factor_required" { needsCode = true }; fail(error) }
    }
    func check() async {
        checkDiagnostic = ""
        guard let id = selected, !account.isEmpty, !busy else {return}; let checkedName = selectedApp?.name ?? String(id); lastOperation = .format("Проверка «%@»",[checkedName]); busy = true;licenseChecked = nil;message = "Apple проверяет право на загрузку…";defer{busy = false}
        do { let data = try await engine.call(["action":"check","app_id":id]);licenseChecked = id;availableVersion = data["version"] as? String ?? "";media.recordVersion(id:id,version:availableVersion);message = .format("Apple разрешает загрузку %@. Версия: %@.",[checkedName,availableVersion.isEmpty ? "—" : availableVersion]) } catch { fail(error) }
    }
    func acquire() async {
        guard let id = selected,!busy else{return};busy = true;message = "Получаем бесплатное приложение в App Store…";defer{busy = false}
        do {_ = try await engine.call(["action":"acquire","app_id":id,"confirmed":true]);message = "Бесплатное приложение добавлено в покупки. Проверь доступность."}catch{fail(error)}
    }
    func download() async {
        guard let id = selected, !account.isEmpty, !busy, !preview else { return }
        // Returning to a prepared package clears the UI check, not the Apple session.
        // Recheck before downloading; retain the prepared package if Apple refuses.
        if licenseChecked != id { await check() }
        guard selected == id, licenseChecked == id, !account.isEmpty, !busy else { return }
        lastOperation = "Загрузка приложения";busy = true;packagePath = "";packageApp = nil;message = "Загружаем приложение с серверов Apple…";defer{busy = false}
        do {let data = try await engine.call(["action":"download","app_id":id,"confirmed":true]);guard data["license_ready"] as? Bool == true else {throw BridgeError(code:"license_data_missing")};packagePath = data["path"] as? String ?? "";packageApp = id;cacheUsed = data["cache_used"] as? Bool ?? false;cacheStored = data["cache_stored"] as? Bool ?? false;Task {await media.backupNow()};message = "Пакет загружен, лицензия Apple подготовлена и проверена. Можно установить на выбранный iPhone."}catch{fail(error)}
    }
    func scanDevices() async {
        guard !busy else{return};busy = true;defer{busy = false}
        do {let data = try await usb.call(["action":"devices"]);devices = try decode([Device].self,data["devices"] ?? []);if !devices.contains(where:{$0.udid == target}){target = devices.count == 1 ? devices[0].udid : ""};message = devices.isEmpty ? "Подключи iPhone кабелем и разблокируй его." : "Выбери iPhone для работы."}catch{fail(error)}
    }
    func readSource() async {
        guard !target.isEmpty,!busy else{return};busy = true;defer{busy = false}
        do{let data = try await usb.call(["action":"apps","udid":target]);sourceApps = try decode([DeviceApp].self,data["apps"] ?? []);showTransfer = true;message = "Список с iPhone прочитан. Выбери приложение для повторной загрузки."}catch{fail(error)}
    }
    func chooseSource(_ app:DeviceApp){
        if let id = app.app_id {
            if !apps.contains(where:{$0.id == id}){apps.append(CatalogApp(id:id,name:app.name,aliases:[app.name],sources:["Твой iPhone"],category:"С устройства"))}
            selected = id;search = "";licenseChecked = nil;message = .format("Выбрано %@. Войди в Apple ID, которому принадлежит приложение. Затем подключи целевой iPhone.",[app.name])
        }else{search = app.name;message = "iPhone не сообщил App ID. Подбери точную запись по названию или введи App ID."}
        showTransfer = false
    }
    func prepareInstall() async {
        guard !target.isEmpty,!packagePath.isEmpty,packageApp==selected,!busy else{return}
        busy=true;defer{busy=false}
        do {
            let result=try await usb.call(["action":"package_check","udid":target,"path":packagePath])
            compatibility=try decode(PackageCompatibility.self,result);preparedTarget=target;confirmInstall=true
        }catch{compatibility=nil;fail(error)}
    }
    func install() async {
        guard !target.isEmpty,!packagePath.isEmpty,packageApp==selected,!busy,let compatibility,target==preparedTarget else{return}
        busy=true;message="Устанавливаем на выбранный iPhone…";defer{busy=false}
        do {
            let binding=try JSONSerialization.jsonObject(with:JSONEncoder().encode(compatibility))
            _=try await usb.call(["action":"install","udid":target,"path":packagePath,"confirmed":true,"compatibility":binding])
            message="iPhone подтвердил установку. Открой приложение на телефоне и проверь запуск."
        }catch{fail(error)}
    }
    func end() async {
        guard !busy else{return};busy = true
        var cleanupOK = true
        do {_ = try await engine.call(["action":"close"])} catch {cleanupOK = false}
        engine.stop();account = "";needsCode = false;licenseChecked = nil;packagePath = "";packageApp = nil;sourceApps = [];devices = [];target = "";message = cleanupOK ? "Сеанс закрыт. Временная загрузка удалена." : "Сеанс закрыт. Удаление временного пакета нужно проверить.";busy = false
    }
    func fail(_ error:Error){
        let code = (error as? BridgeError)?.code ?? "unexpected_error"
        let texts:[String:String] = [
            "two_factor_required":"Apple запросила код подтверждения. Введи свежий код в окне приложения; пароль повторно вводить не нужно.",
            "license_required":"У этого Apple ID нет права на приложение. Если оно еще доступно, можно получить бесплатную лицензию.",
            "session_expired":"Apple завершила сеанс. Заверши работу с аккаунтом и войди заново.",
            "runtime_missing":"Комплект компонентов неполный. Нужна повторная сборка приложения.",
            "app_not_available":"Apple не нашла это приложение в магазине данной учетной записи.",
            "free_apps_only":"Получение платных приложений отключено.",
            "not_paired":"Для работы нужно доверие этому Mac. Открой iPhone в Finder и подтверди доверие на телефоне.",
            "device_not_found":"Выбранный iPhone отключен. Подключи его и обнови список.",
            "verification_failed":"iPhone отклонил подпись или лицензию приложения. Перенос на эту учетную запись не подтвержден.",
            "destination_blocked":"Адрес ответа не входит в разрешенные сервисы Apple. Операция остановлена.",
            "license_data_missing":"В пакете не подтверждена лицензия Apple. Установка заблокирована.",
            "package_integrity_failed":"Контрольная сумма загрузки не совпала с ответом Apple. Установка остановлена; повтори загрузку.",
            "package_size_limit":"Пакет или его метаданные превышают допустимый размер. Установка остановлена.",
            "package_preparation_failed":"Пакет не прошел подготовку или проверку. Установка заблокирована.",
            "cleanup_failed":"Не удалось подтвердить удаление временного пакета. Сеанс нужно завершить и проверить очистку.",
            "usb_missing":"В сборке отсутствует модуль подключения iPhone.",
            "apple_request_failed":"Apple не выполнила запрос. Проверь учетные данные и доступность сервиса. Полный ответ с секретами не записывается.",
            "ios_too_old":"Пакет требует более новую iOS. Выбранный iPhone не изменен.",
            "package_minimum_ios_missing":"В IPA не указана минимальная iOS; автоматическая установка остановлена.",
            "package_device_family_mismatch":"Этот пакет не предназначен для выбранного типа устройства.",
            "installation_plan_changed":"Устройство или требования пакета изменились. Повтори проверку установки.",
            "usb_failed":"Не удалось выполнить операцию с iPhone. Проверь кабель, разблокировку и доверие этому Mac."
        ]
        let extra:[String:String] = ["network_timeout":"Apple не ответила вовремя. Сведения о покупке не изменились. Повтори проверку позже.","network_unavailable":"Не удалось связаться с Apple. Проверь подключение к интернету.","apple_rate_limited":"Apple временно ограничила частоту запросов. Подожди несколько минут.","apple_service_unavailable":"Сервис Apple временно недоступен. Повтори проверку позже.","app_temporarily_unavailable":"Apple сейчас не выдает сведения по этому App ID. Наличие установленной копии не отменяется этим ответом.","apple_access_denied":"Apple отклонила запрос этого приложения. Это не доказывает отсутствие прежней покупки.","apple_verification_failed":"Apple не приняла проверку устройства для этого запроса. Повтори проверку позже.","apple_request_failed":"Не удалось получить корректный ответ Apple. Причина не подтверждена; прежняя покупка не считается отсутствующей."]
        checkDiagnostic = (error as? BridgeError)?.diagnostic ?? ""
        message = .sequence((lastOperation.isEmpty ? [] : [lastOperation, .literal(": ")]) + [.key(extra[code] ?? texts[code] ?? "Операция не завершена."), .literal(" [\(code)]")])
    }
    func startup() async {
        await refresh()
        if !preview { await scanDevices() }
        if !preview { await media.backupNow(); Task { await media.warm(apps,all:true) } }
    }
    func loadBundledPreview() {
        guard let url=Bundle.main.resourceURL?.appendingPathComponent("Demo/catalog.json"),
              let data=try? Data(contentsOf:url),
              let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let entries=json["apps"] as? [[String:Any]] else { apps=[];return }
        apps=entries.compactMap{ entry in
            guard let id=entry["id"] as? NSNumber,let name=entry["name"] as? String else{return nil}
            return CatalogApp(id:id.int64Value,name:name,aliases:[],sources:["demo"],category:entry["category"] as? String ?? "")
        }
        media.setCatalog(apps)
        message="Демонстрация: вымышленные данные, операции отключены"
    }

}

final class InputFields: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var code = ""
    @Published var manualID = ""
    @Published var showSignIn = false
    @Published var showCache = false
    @Published var accountMode:AccountMode = .guest
    @Published var saveAccountName=false
    @Published var savePassword=false
    @Published var savedAccountID:UUID?
    @Published var vaultBusy=false
    @Published var vaultMessage:UIMessage=""
}

