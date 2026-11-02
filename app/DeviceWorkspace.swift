import SwiftUI
import AppKit
import Combine
import CryptoKit
import CoreText

enum WorkspaceTab:String,CaseIterable,Identifiable {
    case overview,battery,installed,catalog,queue,diagnostics,photos,documents,backups,archive,profiles,home,tools
    var id:String{rawValue}
    var title:String {
        switch self {case .overview:return L("Обзор устройства");case .battery:return L("Батарея");case .installed:return L("На устройстве");case .catalog:return L("Каталог приложений");case .queue:return L("Очередь восстановления");case .diagnostics:return L("Диагностика");case .photos:return L("Фото и видео");case .documents:return L("Документы приложений");case .backups:return L("Резервные копии iPhone");case .archive:return L("Архив данных");case .profiles:return L("Профили устройства");case .home:return L("Домашний экран");case .tools:return L("Инструменты")}
    }
    var symbol:String {switch self {case .overview:return "iphone";case .battery:return "battery.100percent";case .installed:return "app.badge";case .catalog:return "square.grid.2x2";case .queue:return "list.bullet.rectangle";case .diagnostics:return "stethoscope";case .photos:return "photo.on.rectangle";case .documents:return "folder";case .backups:return "externaldrive.badge.timemachine";case .archive:return "archivebox";case .profiles:return "checkmark.shield";case .home:return "rectangle.grid.3x3";case .tools:return "wrench.and.screwdriver"}}
}
struct DeviceMetric:Decodable {let value:Double;let boolean:Bool
    init(from decoder:Decoder)throws {let c=try decoder.singleValueContainer();if let b=try? c.decode(Bool.self){value=b ? 1:0;boolean=true}else{value=try c.decode(Double.self);boolean=false}}
    var display:String{boolean ? L(value==0 ? "Нет" : "Да") : value.formatted(.number.precision(.fractionLength(0...2)))}
}
struct DeviceOverview:Decodable {let model:String;let ios:String;let build:String;let name:String;let camera_serial:String;let battery:[String:DeviceMetric];var storage:[String:Int64];let battery_available:Bool;let battery_reading:BatteryReading?;let content_counts:[String:Int64]?;let content_count_sources:[String:String]?;let content_count_observed_at:Int64?}
struct DeviceFile:Decodable,Identifiable {let id:String;let name:String;let directory:Bool;let bytes:Int64;let modified:String;let exportable:Bool}
struct CrashItem:Decodable,Identifiable {let id:String;let name:String}
struct DeviceProfile:Decodable,Identifiable {let id:String;let name:String;let organization:String}
struct BackupSummary:Decodable {let name:String;let ios:String;let model:String;let encrypted:Bool;let finished:Bool;let date:String}
struct BackupFile:Decodable,Identifiable {let id:String;let name:String;let domain:String;let bytes:Int64;let exportable:Bool}
struct ArchiveChat:Decodable,Identifiable {let id:String;let name:String;let address:String;let count:Int}
struct ArchiveMessage:Decodable,Identifiable {let id:String;let text:String;let date:String;let from_me:Bool;let unsupported_body:Bool}
struct ArchiveContactValue:Decodable {let value:String;let kind:String}
struct ArchiveContact:Decodable,Identifiable {let id:String;let name:String;let first:String;let last:String;let organization:String;let values:[ArchiveContactValue]}
struct RestoreQueueItem:Identifiable {let id:Int64;let name:String;var state="Ожидает";var error="";var version="";var minimumIOS="";var checkedIOS="";var bundle="";var launchConfirmed=false}

enum PrivatePanels {
    @MainActor static func folder()->URL? {let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.canCreateDirectories=true;p.allowsMultipleSelection=false;return p.runModal() == .OK ? p.url:nil}
    @MainActor static func files()->[URL] {let p=NSOpenPanel();p.canChooseDirectories=false;p.allowsMultipleSelection=true;return p.runModal() == .OK ? p.urls:[]}
}

@MainActor final class DeviceWorkspace:ObservableObject {
    let app:AppModel
    let photos=PhonePhotoLibrary()
    let albumSync=PhoneAlbumSync()
    let battery:BatteryMonitor
    @Published var tab:WorkspaceTab = .overview
    @Published var busy=false
    @Published var canCancel=false
    @Published var fraction:Double=0
    @Published var status:UIMessage="Выбери действие. Личные данные автоматически не читаются."
    @Published var overview:DeviceOverview?
    @Published var installed:[DeviceApp]=[]
    @Published var installedSearch=""
    @Published var deviceImages:[String:NSImage]=[:]
    @Published var reports:[CrashItem]=[]
    @Published var crashSummary:[String:String]=[:]
    @Published var selectedReport:CrashItem?
    @Published var homeItems:[HomeItem]=[]
    @Published var homeUnsupported=0
    @Published var developer:[String:String]=[:]
    @Published var screenData:Data?
    @Published var launchBundle=""
    @Published var indicatorFile=""
    @Published var indicatorSMS=false
    @Published var indicatorSafari=false
    @Published var indicatorFiles=false
    @Published var indicatorResult:IndicatorResult?
    @Published var profiles:[DeviceProfile]=[]
    @Published var sharingApps:[DeviceApp]=[]
    @Published var sharingBundle=""
    @Published var documentPath="/"
    @Published var files:[DeviceFile]=[]
    @Published var selectedFiles=Set<String>()
    @Published var backupDirectory=""
    @Published var backupPassword=""
    @Published var backupSummary:BackupSummary?
    @Published var backupFiles:[BackupFile]=[]
    @Published var backupSearch=""
    @Published var backupHasMore=false
    @Published var selectedBackupFiles=Set<String>()
    @Published var archiveKind="sms"
    @Published var chats:[ArchiveChat]=[]
    @Published var selectedChats=Set<String>()
    @Published var messages:[ArchiveMessage]=[]
    @Published var contacts:[ArchiveContact]=[]
    @Published var selectedContacts=Set<String>()
    @Published var exportFormat="html"
    @Published var includeAttachments=false
    @Published var backupLimitGiB=256
    @Published var enableEncryption=false
    @Published var showConfirmation=false
    @Published var confirmationTitle=""
    @Published var confirmationDetail=""
    @Published var lastDirectory=""
    @Published var queue:[RestoreQueueItem]=[]
    @Published var queueReplaceExisting=false
    @Published var queueStop=false
    @Published var showQueueConfirmation=false
    private var pending:[String:Any]?
    private var pendingBackupSource=""
    var device:Device?{app.devices.first{$0.udid==app.target}}
    var filteredInstalled:[DeviceApp]{installed.filter{installedSearch.isEmpty || ($0.name+" "+$0.bundle).localizedCaseInsensitiveContains(installedSearch)}}
    init(app:AppModel){self.app=app;self.battery=BatteryMonitor(app:app);self.battery.workspace=self}
    func decode<T:Decodable>(_ type:T.Type,_ data:Any)throws->T{try app.decode(type,data)}
    func request(_ action:String,_ values:[String:Any]=[:])throws->[String:Any] {
        let offline:Set<String>=["backup_inspect","backup_catalog","archive_chats","archive_messages","archive_contacts","archive_export_plan","archive_export","finalize_pdf","ioc_check","ioc_export_plan","ioc_export"]
        if !offline.contains(action){guard let device,device.paired else{throw BridgeError(code:"not_paired")}}
        var result=values;result["action"]=action
        if !offline.contains(action){result["udid"]=app.target}
        return result
    }
    func call(_ payload:[String:Any])async throws->[String:Any] {
        try await app.usb.call(payload,progress:{[weak self] event in Task{@MainActor in
            if let f=event["fraction"] as? Double {self?.fraction=f}
            if event["event"] as? String == "storage_ready" {self?.status="Готово к сверке. На iPhone снова открой Настройки → Основные → Об этом устройстве."}
            if let directory=event["directory"] as? String {self?.lastDirectory=directory}
        }})
    }
    func perform(_ operation:@escaping @MainActor ()async throws->Void) async {
        guard !app.busy,!busy,!app.preview else{return};busy=true;app.busy=true;canCancel=true;fraction=0
        defer{busy=false;app.busy=false;canCancel=false}
        do{try await operation()}catch{status = .key(Self.errorText((error as? BridgeError)?.code ?? "workspace_failed"));if let code=(error as? BridgeError)?.code{status = .sequence([status,.literal(" ["+code+"]")])}}
    }
    func readOverview()async {await perform{
        self.overview=try self.decode(DeviceOverview.self,await self.call(self.request("overview")))
        self.status="Сведения устройства прочитаны. Личные наборы данных не открывались."
    }}
    func readStorageSettings()async {await perform{
        let target=self.app.target
        self.status="Подключаюсь к службе iOS для сверки доступного места…"
        let result=try await self.call(self.request("storage_settings"))
        let storage=try self.decode([String:Int64].self,result["storage"] ?? [:])
        guard self.app.target==target else{return}
        try await self.battery.updateStorage(storage,udid:target)
        self.status = .key(DeviceSettingsStorage(storage) == nil ? "Новый расчет iOS не получен. Показано свободное место по USB; попробуй снова открыть «Об этом устройстве»." : "Расчет доступного места получен из настроек iPhone.")
    }}
    func readInstalled()async {await perform{
        let result=try await self.call(self.request("apps"));self.installed=try self.decode([DeviceApp].self,result["apps"] ?? [])
        self.status="Список установленных приложений прочитан. Выбери приложение для иконки или восстановления."
    }}
    func readIcon(_ application:DeviceApp)async {await perform{
        let data=try await self.call(self.request("icon",["bundle":application.bundle]))
        guard let encoded=data["png"] as? String,let bytes=Data(base64Encoded:encoded),let png=PublicMediaPolicy.normalizedPNG(bytes),let image=NSImage(data:png) else{throw BridgeError(code:"invalid_device_icon")}
        self.deviceImages[application.bundle]=image;self.status="Иконка прочитана с выбранного iPhone."
    }}
    func findInCatalog(_ application:DeviceApp){app.chooseSource(application);tab = .catalog}
    func readReports()async {await perform{
        let result=try await self.call(self.request("crashes"));self.reports=try self.decode([CrashItem].self,result["reports"] ?? []);self.crashSummary=[:];self.selectedReport=nil
        self.status="Доступные отчеты прочитаны без удаления с iPhone. Выбери один отчет."
    }}
    func readReport(_ report:CrashItem)async {await perform{
        let result=try await self.call(self.request("crash_summary",["path":report.id]));self.crashSummary=result.compactMapValues{$0 as? String};self.selectedReport=report
        self.status="Показаны только разрешенные поля отчета. Причина не додумывается."
    }}
    func readProfiles()async {await perform{
        let result=try await self.call(self.request("profiles"));self.profiles=try self.decode([DeviceProfile].self,result["profiles"] ?? []);self.status="Прочитан список видимых профилей. Настройки устройства не менялись."
    }}
    func readSharingApps()async {await perform{
        let result=try await self.call(self.request("sharing_apps"));self.sharingApps=try self.decode([DeviceApp].self,result["apps"] ?? []);self.files=[];self.sharingBundle="";self.documentPath="/"
        self.status="Показаны приложения с поддержкой обмена документами."
    }}
    func readFiles(path:String?=nil)async {await perform{
        guard !self.sharingBundle.isEmpty else{throw BridgeError(code:"selection_required")}
        let result=try await self.call(self.request("files_list",["bundle":self.sharingBundle,"path":path ?? self.documentPath]));self.files=try self.decode([DeviceFile].self,result["files"] ?? []);self.documentPath=result["path"] as? String ?? "/";self.selectedFiles=[]
        self.status="Папка прочитана. Копирование запускается отдельной командой."
    }}
    func stage(_ action:String,values:[String:Any],title:String)async {await perform{
        var request=try self.request(action,values)
        let plan=try await self.call(request)
        guard let token=plan["plan_token"] as? String else{throw BridgeError(code:"invalid_response")}
        request["plan_token"]=token;request["confirmed"]=true
        request["action"]=["file_plan":"file_export","file_upload_plan":"file_upload","backup_plan":"backup_create","archive_export_plan":"archive_export","home_export_plan":"home_export","crash_export_plan":"crash_export","launch_plan":"launch_app","ioc_export_plan":"ioc_export"][action]
        self.pending=request;self.pendingBackupSource=self.backupDirectory
        self.confirmationTitle=L(title)
        let count=plan["count"] as? Int ?? 0,bytes=plan["bytes"] as? Int64 ?? plan["estimated_bytes"] as? Int64 ?? 0
        self.confirmationDetail=LF("Объектов: %@. Объем: %@. Будет создана новая папка; исходники сохранятся.",String(count),humanSize(bytes))
        if let ios=plan["ios"] as? String {self.confirmationDetail += "\niOS "+ios}
        if action=="file_upload_plan" {
            let bundle=values["bundle"] as? String ?? "",name=self.sharingApps.first(where:{$0.bundle==bundle})?.name ?? bundle
            self.confirmationDetail += "\n"+(self.device?.name ?? "iPhone")+" · "+name+"\n"+bundle+"\n"+(values["path"] as? String ?? "/")
        }
        if action=="launch_plan" {self.confirmationDetail=L("Будет открыт выбранный установленный пакет на iPhone. Уже запущенное приложение не завершается; успешный запрос не подтверждает его работоспособность.")+"\n"+(values["bundle"] as? String ?? "")}
        if action=="crash_export_plan" {self.confirmationDetail += "\n"+L("Полный отчет может содержать личные сведения. Он сохранится только в выбранной папке и не войдет в общий кеш.")}
        if action=="ioc_export_plan" {self.confirmationDetail += "\n"+L("Это ограниченная проверка индикаторов. Отсутствие совпадений не доказывает безопасность устройства.")}
        if action=="backup_plan" {
            let encrypted=plan["encrypted"] as? Bool ?? false
            if !encrypted && !self.enableEncryption {self.pending=nil;throw BridgeError(code:"backup_encryption_confirmation_required")}
            self.confirmationDetail += "\n"+L(encrypted ? "Копия будет зашифрована. Пароль остается только в памяти." : "На iPhone будет включено шифрование резервных копий с введенным паролем. Эта настройка останется включенной и после операции.")
            self.confirmationDetail += "\n"+L("Это личная резервная копия устройства. Она не войдет в общий кеш AppRestore.")
        }
        if let unsupported=plan["unsupported_messages"] as? Int,unsupported>0 {self.confirmationDetail += "\n"+LF("Сообщений с неподдержанным форматированием: %@. В экспорте будет явная отметка.",String(unsupported))}
        if let coverage=plan["attachment_coverage"] as? [String:Any] {self.confirmationDetail += "\n"+LF("Вложения: отсутствует %@, пропущено форматов %@.",String(coverage["missing"] as? Int ?? 0),String(coverage["unsupported"] as? Int ?? 0));if coverage["schema_supported"] as? Bool == false {self.confirmationDetail += "\n"+L("Связи вложений в этом формате базы пока не поддержаны.")}}
        self.showConfirmation=true
    }}
    func exportDocuments()async {guard let folder=PrivatePanels.folder() else{return};await stage("file_plan",values:["bundle":sharingBundle,"paths":Array(selectedFiles).sorted(),"destination":folder.path],title:"Скопировать выбранные документы?")}
    func uploadDocuments()async {await uploadDocuments(PrivatePanels.files())}
    func uploadDocuments(_ paths:[URL])async {guard !paths.isEmpty,paths.count<=100 else{return};await stage("file_upload_plan",values:["bundle":sharingBundle,"path":documentPath,"local_files":paths.map(\.path),"upload_nonce":UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()],title:"Передать документы в приложение?")}
    func createBackup()async {guard !backupPassword.isEmpty,let folder=PrivatePanels.folder() else{return};await stage("backup_plan",values:["destination":folder.path,"max_bytes":Int64(backupLimitGiB)*1024*1024*1024,"backup_password":backupPassword,"enable_encryption_confirmed":enableEncryption],title:"Создать зашифрованную копию iPhone?")}
    func commitPlan()async {
        guard let payload=pending else{return};pending=nil;showConfirmation=false
        await perform{
            var result=try await self.call(payload)
            if result["launch_requested"] as? Bool == true {self.status="Запрос запуска принят. Проверь на iPhone, открылось ли приложение без сбоя.";return}
            if result["needs_pdf"] as? Bool == true,let path=result["text_path"] as? String,let directory=result["directory"] as? String {
                try PrivatePDF.render(textURL:URL(fileURLWithPath:path),directory:URL(fileURLWithPath:directory))
                result=try await self.call(self.request("finalize_pdf",["directory":directory]))
            }
            if let directory=result["directory"] as? String {self.lastDirectory=directory}
            if let backup=result["backup_directory"] as? String {self.backupDirectory=backup;self.backupSummary=nil}
            self.status = .format("Готово: %@ файлов, %@. Результат проверен.",[String(result["count"] as? Int ?? 0),humanSize(result["bytes"] as? Int64 ?? 0)])
        }
    }
    func discardPlan(){pending=nil;showConfirmation=false}
    func chooseBackup()async {guard let folder=PrivatePanels.folder() else{return};backupDirectory=folder.path;backupPassword="";backupFiles=[];chats=[];messages=[];contacts=[];await inspectBackup()}
    func inspectBackup()async {await perform{
        let result=try await self.call(self.request("backup_inspect",["backup_directory":self.backupDirectory]));self.backupSummary=try self.decode(BackupSummary.self,result);self.status="Прочитаны служебные сведения выбранной копии. Для личных данных выбери раздел."
    }}
    private var archiveRequest:[String:Any]{["backup_directory":backupDirectory,"backup_password":backupPassword]}
    func readBackupFiles(append:Bool=false)async {await perform{
        var data=self.archiveRequest;data["search"]=self.backupSearch;data["offset"]=append ? self.backupFiles.count:0
        let result=try await self.call(self.request("backup_catalog",data));let rows=try self.decode([BackupFile].self,result["files"] ?? []);self.backupFiles=append ? self.backupFiles+rows:rows;self.backupHasMore=result["has_more"] as? Bool ?? false;if !append{self.selectedBackupFiles=[]};self.status="Каталог копии открыт в памяти. Расшифрованная база на диск не записана."
    }}
    func readArchive()async {await perform{
        var data=self.archiveRequest;data["kind"]=self.archiveKind
        let result=try await self.call(self.request(self.archiveKind=="contacts" ? "archive_contacts" : "archive_chats",data))
        self.messages=[];self.selectedChats=[];self.selectedContacts=[]
        if self.archiveKind=="contacts" {self.contacts=try self.decode([ArchiveContact].self,result["contacts"] ?? [])}else{self.chats=try self.decode([ArchiveChat].self,result["chats"] ?? [])}
        self.status="Выбранный набор прочитан локально. Экспорт требует отдельного выбора."
    }}
    func readMessages(_ chat:ArchiveChat)async {await perform{
        var data=self.archiveRequest;data["kind"]=self.archiveKind;data["chat_id"]=chat.id
        let result=try await self.call(self.request("archive_messages",data));self.messages=try self.decode([ArchiveMessage].self,result["messages"] ?? []);self.status="Показано до 500 сообщений выбранной переписки. Экспорт использует всю выбранную переписку в пределах лимита."
    }}
    func exportArchive(filesOnly:Bool=false)async {
        guard let folder=PrivatePanels.folder() else{return}
        var data=archiveRequest;data["destination"]=folder.path;data["kind"]=filesOnly ? "files" : archiveKind
        data["selected_ids"]=filesOnly ? Array(selectedBackupFiles).sorted() : archiveKind=="contacts" ? Array(selectedContacts).sorted() : Array(selectedChats).sorted()
        data["format"]=filesOnly ? "original" : archiveKind=="contacts" ? (exportFormat=="csv" ? "csv":"vcf") : exportFormat
        data["include_attachments"]=includeAttachments
        await stage("archive_export_plan",values:data,title:"Экспортировать выбранные личные данные?")
    }
    func clearPrivate(){guard !busy,!photos.busy,!albumSync.busy else{return};albumSync.clear();overview=nil;installed=[];deviceImages=[:];reports=[];crashSummary=[:];selectedReport=nil;homeItems=[];homeUnsupported=0;developer=[:];screenData=nil;launchBundle="";indicatorFile="";indicatorResult=nil;indicatorSMS=false;indicatorSafari=false;indicatorFiles=false;profiles=[];sharingApps=[];sharingBundle="";files=[];selectedFiles=[];backupPassword="";backupDirectory="";backupSummary=nil;backupFiles=[];chats=[];messages=[];contacts=[];selectedChats=[];selectedContacts=[];selectedBackupFiles=[];pending=nil;queue=[];lastDirectory="";photos.disconnect();status="Личные сведения закрыты. Общий каталог сохранен."}
    func addToQueue(_ application:CatalogApp){guard queue.count<25,!queue.contains(where:{$0.id==application.id}) else{return};queue.append(RestoreQueueItem(id:application.id,name:application.name))}
    func restoreQueue()async {
        guard !app.account.isEmpty,let device,!busy,!app.busy,!queue.isEmpty,!app.preview else{return}
        let target=device.udid,account=app.account;busy=true;app.busy=true;canCancel=false;queueStop=false
        defer{busy=false;app.busy=false}
        do {
            
            for index in queue.indices {
                if queueStop {break}
                guard app.target==target,app.account==account else{throw BridgeError(code:"installation_plan_changed")}
                let id=queue[index].id;queue[index].launchConfirmed=false
                do {
                    queue[index].state="Проверка";_=try await app.engine.call(["action":"check","app_id":id])
                    if queueStop {break}
                    queue[index].state="Загрузка"
                    let package=try await app.engine.call(["action":"download","app_id":id,"confirmed":true])
                    guard let path=package["path"] as? String,package["license_ready"] as? Bool == true else{throw BridgeError(code:"license_data_missing")}
                    app.packagePath=path;app.packageApp=id
                    let compatibility=try await call(request("package_check",["path":path]))
                    queue[index].version=compatibility["version"] as? String ?? "";queue[index].minimumIOS=compatibility["minimum_ios"] as? String ?? "";queue[index].checkedIOS=compatibility["ios"] as? String ?? "";queue[index].bundle=compatibility["bundle"] as? String ?? ""
                    let listing=try await call(request("apps"));let existing=try decode([DeviceApp].self,listing["apps"] ?? [])
                    if let bundle=compatibility["bundle"] as? String,existing.contains(where:{$0.bundle==bundle}),!queueReplaceExisting {queue[index].state="Пропущено: уже установлено";continue}
                    if queueStop {break}
                    queue[index].state="Установка"
                    _=try await call(["action":"install","udid":target,"path":path,"confirmed":true,"compatibility":compatibility])
                    queue[index].state="Установлено";fraction=Double(index+1)/Double(queue.count)
                }catch {queue[index].state="Ошибка";queue[index].error=(error as? BridgeError)?.code ?? "operation_failed";if ["session_expired","device_not_found","installation_plan_changed"].contains(queue[index].error){throw error}}
            }
            status="Очередь остановлена или завершена. Проверь запуск установленных приложений на iPhone."
        }catch{status = .key(Self.errorText((error as? BridgeError)?.code ?? "workspace_failed"))}
    }
    static func errorText(_ code:String)->String {
        let map=["backup_history_limit":"В этой папке уже есть 8 копий или незавершенных попыток. Выбери другое место или отдельно проверь прежние копии; автоматического удаления нет.","not_paired":"Подключи и разблокируй iPhone, подтверди доверие этому Mac.","device_not_found":"Выбранный iPhone отключен. Обнови список устройств.","operation_cancelled":"Операция отменена. Незавершенные файлы не считаются проверенной копией.","backup_password_required":"Введи пароль этой резервной копии. Это отдельный пароль, не Apple ID.","backup_password_invalid":"Пароль копии не подошел или ее каталог поврежден. Исходная копия сохранена.","incomplete_backup":"Копия не завершена; экспорт из нее остановлен.","dataset_not_in_backup":"В этой копии нет выбранного набора данных.","unsupported_backup_schema":"Формат этой базы пока не поддержан. Данные не изменены.","backup_dataset_has_pending_wal":"В копии есть незавершенный журнал этой базы. Нужен согласованный снимок; неполный экспорт остановлен.","backup_encryption_confirmation_required":"Для новой копии включи явное подтверждение шифрования и введи пароль не короче 8 символов.","insufficient_disk_space":"Недостаточно свободного места для выбранной операции и безопасного запаса.","plan_changed":"Состав, устройство или назначение изменились. Повтори подготовку операции.","file_sharing_not_enabled":"Приложение не подтвердило поддержку обмена документами.","protected_file_blocked":"Этот файл относится к защищенным учетным данным. Экспорт заблокирован.","ios_too_old":"Пакет требует более новую iOS. iPhone не изменен.","package_device_family_mismatch":"Пакет не предназначен для выбранного устройства.","package_minimum_ios_missing":"Не удалось подтвердить минимальную iOS пакета.","backup_write_outside_job":"Попытка записи за пределами новой резервной копии остановлена.","selection_required":"Сначала выбери элементы для операции.","device_file_exists":"На устройстве уже существует это назначение. Перезапись отключена."]
        let extra=["developer_mode_required":"Для этой функции нужен уже включенный режим разработчика. Включи его в настройках iPhone, только если решил использовать инструменты разработчика.","developer_ios_unsupported":"Эта функция требует iOS 17.4 или новее и доступной службы Apple.","no_supported_indicators":"В файле нет поддержанных активных индикаторов. Нужен совместимый STIX2 с простыми сравнениями."]
        let media=["invalid_album_plan":"План альбома недействителен. Выбери файлы, название и папку заново.","unsupported_sync_media":"Этот формат не подходит для синхронизации через Finder. Выбери поддерживаемое фото или видео.","private_data_in_public_folder":"Личные файлы нельзя сохранять в папке программы или общем кеше. Выбери отдельную папку.","copy_verification_failed":"Копия не прошла проверку. Исходники сохранены; незавершенная папка оставлена для проверки."]
        return media[code] ?? extra[code] ?? map[code] ?? "Операция не завершена. Исходные данные сохранены; проверь подключение, выбор и ограничения формата."
    }
}

