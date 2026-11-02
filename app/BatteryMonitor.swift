import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class BatteryMonitor:ObservableObject {
    @Published var scope="mac"
    @Published var devices:[BatteryDevice]=[]
    @Published var mac:BatterySnapshot?
    @Published var observations:[String:TechnicalObservation]=[:]
    @Published var phone:BatterySnapshot?
    @Published var points:[BatteryPoint]=[]{didSet{
        let packs=Array(Set(points.map{$0.reading.pack_hash ?? "unknown"})).sorted();packIndexes=Dictionary(uniqueKeysWithValues:packs.enumerated().map{($0.element,$0.offset+1)})
        var daily:[String:BatteryPoint]=[:];let cal=Calendar.current;for point in points{let key=String(cal.startOfDay(for:point.date).timeIntervalSince1970)+":"+(point.reading.pack_hash ?? "unknown");daily[key]=point};cachedDaily=daily.values.sorted{$0.date<$1.date}
    }}
    private(set) var packIndexes:[String:Int]=[:]
    private var cachedDaily:[BatteryPoint]=[]
    @Published var historyID=""
    @Published var chartMetric="full"
    @Published var period="all"
    @Published var busy=false
    @Published var importReview:CoconutReview?
    @Published var showDetails=false
    @Published var status:UIMessage="История батареи хранится только на этом Mac."
    weak var workspace:DeviceWorkspace?
    private weak var app:AppModel?
    private let store=BatteryHistory(),reader=MacBatteryReader(),passportReader=MacPassportReader(),usb=USBBridge(),coconutReader=CoconutReader()
    private var loop:Task<Void,Never>?
    private var started=false
    private var collection=BatteryCollectionPolicy()
    private var connectionSnapshots:[String:BatterySnapshot]=[:]
    private var connectionOverviews:[String:DeviceOverview]=[:]
    init(app:AppModel){self.app=app}
    var current:BatterySnapshot?{scope=="mac" ? mac:phone}
    var savedDevice:BatteryDevice?{devices.first{$0.id==(scope=="history" ? historyID:current?.device.id ?? "")}}
    var tracking:Bool{savedDevice?.tracking ?? (current != nil)}
    var visiblePoints:[BatteryPoint]{guard let days=Int(period),let since=Calendar.current.date(byAdding:.day,value:-days,to:Date()) else{return points};return points.filter{$0.date>=since}}
    var dailyPoints:[BatteryPoint]{guard let days=Int(period),let since=Calendar.current.date(byAdding:.day,value:-days,to:Date()) else{return cachedDaily};return cachedDaily.filter{$0.date>=since}}
    func start()async {
        guard !started,app?.preview==false else{return};started=true
        do{devices=try await store.devices()}catch{status = .key(Self.message(error));return}
        await refresh(onlyTracked:true)
        loop=Task{@MainActor [weak self] in while !Task.isCancelled{do{try await Task.sleep(nanoseconds:15_000_000_000)}catch{return};guard let self else{return};await self.refresh(onlyTracked:true)}}
    }
    func stop(){loop?.cancel();loop=nil;usb.cancel()}
    func refresh(onlyTracked:Bool=false,target requestedTarget:String?=nil)async {
        guard let app,!app.preview,!app.diagnosticCollectionPaused,!app.busy,!busy,workspace?.busy != true,workspace?.photos.busy != true,workspace?.albumSync.busy != true else{return}
        busy=true;var ownsAppBusy=false;defer{busy=false;if ownsAppBusy{app.busy=false}}
        do{
            let discovery=try await usb.call(["action":"devices"]),connected=try app.decode([Device].self,discovery["devices"] ?? [])
            let trusted=Set(connected.filter{$0.paired}.map(\.udid))
            let present=Set(connected.map(\.udid))
            collection.observeConnectedDevices(present)
            connectionSnapshots=connectionSnapshots.filter{present.contains($0.key)}
            connectionOverviews=connectionOverviews.filter{present.contains($0.key)}
            app.devices=connected
            if !connected.contains(where:{$0.udid==app.target}){app.target=connected.count==1 ? connected[0].udid:""}
            let previousPhone=phone?.device.id
            phone=trusted.contains(app.target) ? connectionSnapshots[app.target]:nil
            workspace?.overview=trusted.contains(app.target) ? connectionOverviews[app.target]:nil
            if scope=="iphone",previousPhone != phone?.device.id{await reloadHistory()}
            let requested=requestedTarget ?? (scope=="mac" ? "mac":app.target)
            let readMac = !collection.macCaptured || (!onlyTracked && requested=="mac")
            let phones=connected.filter{device in device.paired && (collection.needsPhone(device.udid) || (!onlyTracked && device.udid==requested)) && (!onlyTracked || devices.first(where:{$0.id==BatteryIdentity.hash("iphone:"+device.udid)})?.tracking != false)}
            guard readMac || !phones.isEmpty else{return}
            guard !app.busy,!app.diagnosticCollectionPaused,workspace?.busy != true,workspace?.photos.busy != true else{return}
            app.busy=true;ownsAppBusy=true
            if readMac {do{let raw=try await reader.read();let resolved=try await store.resolveDevice(raw.device);let snapshot=BatterySnapshot(device:resolved,reading:raw.reading,date:raw.date,transient:raw.transient);mac=snapshot
                let enabled=devices.first{$0.id==snapshot.device.id}?.tracking ?? true
                let passport=try await passportReader.read(snapshot)
                if enabled{try await store.record(snapshot,tracking:true);try await store.recordPassport(passport,device:resolved)}
                collection.capturedMac()
            }catch BatteryFailure.unavailable{mac=nil;collection.capturedMac()}}
            for device in phones {
                let id=BatteryIdentity.hash("iphone:"+device.udid)
                let rawDevice=BatteryDevice(id:id,kind:"iphone",name:device.name,model:device.model,system:(device.model.hasPrefix("iPad") ? "iPadOS ":"iOS ")+device.ios,tracking:true)
                let known=try await store.resolveDevice(rawDevice)
                if onlyTracked,devices.first(where:{$0.id==known.id})?.tracking==false{collection.capturedPhone(device.udid);continue}
                let response=try await usb.call(["action":"inventory","udid":device.udid]),battery=response["battery"] as? [String:Any] ?? [:]
                var reading=battery.isEmpty ? BatteryReading(source:"unavailable"):try app.decode(BatteryReading.self,battery)
                var incoming=rawDevice;incoming.aliases=battery["device_aliases"] as? [String] ?? []
                if incoming.aliases.isEmpty,let field=(response["fields"] as? [[String:Any]])?.first(where:{$0["key"] as? String=="SerialNumber"}),let serial=field["value"] as? String{incoming.aliases=[BatteryIdentity.alias(kind:"iphone",serial:serial)]}
                let resolved=try await store.resolveDevice(incoming)
                let deviceSerial=battery["transient_device_serial"] as? String,batterySerial=battery["transient_battery_serial"] as? String
                var detail=reading.details ?? BatteryDetails()
                if let serial=batterySerial,serial.utf8.count<=200{detail.manufacturer=BatteryOrigin.manufacturer(serial);detail.manufacture_date=BatteryOrigin.weekDate(serial:serial,hours:detail.lifetime?.operating_hours);if detail.manufacture_date != nil{detail.manufacture_date_source="serial_week_estimate"}}
                if let serial=deviceSerial,serial.utf8.count<=128{detail.device_manufacture_date=BatteryOrigin.deviceWeek(serial:serial,kind:"iphone",model:device.model);if detail.device_manufacture_date != nil{detail.device_date_source="legacy_serial_week"}}
                reading.details=detail;reading.system_version=resolved.system;try reading.validate()
                let snapshot=BatterySnapshot(device:resolved,reading:reading,date:Date(),transient:BatteryTransientIdentity(deviceSerial:deviceSerial,batterySerial:batterySerial))
                let fields=try app.decode([HardwareField].self,response["fields"] ?? []),passport=DevicePassport(fields:fields,date:Date());try passport.validate()
                let enabled=devices.first{$0.id==resolved.id}?.tracking ?? true
                if enabled{try await store.record(snapshot,tracking:true);try await store.recordPassport(passport,device:resolved)}
                connectionSnapshots[device.udid]=snapshot
                if let overview=response["overview"]{connectionOverviews[device.udid]=try app.decode(DeviceOverview.self,overview)}
                collection.capturedPhone(device.udid)
                if device.udid==app.target{phone=snapshot;workspace?.overview=connectionOverviews[device.udid]}
            }
            if !connected.contains(where:{$0.udid==app.target && $0.paired}){phone=nil;workspace?.overview=nil}

            devices=try await store.devices();await reloadHistory()
            status="Замер сохранен при подключении или по твоему запросу. Проверка подключения не создает новые записи."
        }catch{status = .key(Self.message(error))}
    }
    func updateStorage(_ storage:[String:Int64],udid:String)async throws {
        guard let app,let snapshot=connectionSnapshots[udid] else{return}
        connectionOverviews[udid]?.storage=storage
        if app.target==udid{workspace?.overview=connectionOverviews[udid]}
        guard devices.first(where:{$0.id==snapshot.device.id})?.tracking != false,
              let observation=observations[snapshot.device.id] else{return}
        var fields=observation.passport.fields.filter{!storage.keys.contains($0.key) && !$0.key.hasPrefix("Settings")}
        fields += storage.sorted{$0.key<$1.key}.map{key,value in HardwareField(key:key,section:"storage",value:String(value),source:key.hasPrefix("Settings") ? "apple_settings_cachedelete":key.hasPrefix("AFC") ? "apple_afc_filesystem":"apple_disk_usage")}
        let passport=DevicePassport(fields:fields,date:Date());try passport.validate()
        try await store.recordPassport(passport,device:snapshot.device)
        await reloadHistory()
    }
    func targetChanged(){let id=app?.target ?? "";phone=connectionSnapshots[id];workspace?.overview=connectionOverviews[id];if scope=="iphone"{points=[];Task{await reloadHistory()}}}
    func setTracking(_ value:Bool)async {
        guard !busy else{return}
        do{
            if let current,scope != "history"{if value{try await store.record(current,tracking:true)}else{try await store.setTracking(current.device.id,false)}}
            else if !historyID.isEmpty{try await store.setTracking(historyID,value)}
            devices=try await store.devices();await reloadHistory();status=value ? "Отслеживание включено. Первый замер сохранен.":"Новые замеры не сохраняются. Прежняя история остается в базе."
        }catch{status = .key(Self.message(error))}
    }
    func reloadHistory()async {
        let id=scope=="history" ? historyID:(current?.device.id ?? "")
        do{let loaded=id.isEmpty ? []:try await store.points(id);guard id==(scope=="history" ? historyID:(current?.device.id ?? "")) else{return};points=loaded;if !id.isEmpty{observations[id]=try await store.passport(id)};if let mac{observations[mac.device.id]=try await store.passport(mac.device.id)};if let phone{observations[phone.device.id]=try await store.passport(phone.device.id)}}catch{status = .key(Self.message(error))}
    }
    func selectScope()async {
        if scope=="history",historyID.isEmpty{historyID=devices.first?.id ?? ""}
        if scope=="iphone"{await refresh(onlyTracked:true)};await reloadHistory()
    }
    func exportCSV()async {
        guard !busy,!points.isEmpty,let device=savedDevice else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.commaSeparatedText];panel.nameFieldStringValue="AppRestore-Battery-"+String(Int(Date().timeIntervalSince1970))+".csv"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{
            guard url.standardizedFileURL.path==url.resolvingSymlinksInPath().path,!FileManager.default.fileExists(atPath:url.path),!url.path.hasPrefix(BatteryHistory.defaultDirectory.path+"/"),!url.path.hasPrefix("/Applications/"),!url.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path),!url.path.hasPrefix(PublicEdition.dataRoot.appendingPathComponent("Library").path+"/") else{throw BatteryFailure.exportExists}
            let rows=points;let data=await Task.detached(priority:.utility){BatteryCSV.csv(rows,device:device)}.value;try data.write(to:url,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);guard try Data(contentsOf:url)==data else{throw BatteryFailure.database};status="CSV сохранен и проверен. База истории не изменялась."
        }catch{status = .key(Self.message(error))}
    }
    func prepareCoconutImport()async {
        guard !busy,app?.preview==false else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.allowedContentTypes=[UTType(filenameExtension:"ccba") ?? .data]
        guard panel.runModal() == .OK,let url=panel.url else{return}
        busy=true;app?.busy=true;defer{busy=false;app?.busy=false}
        do{let plan=try await coconutReader.plan(url);importReview=try await store.preview(plan);status="Копия coconutBattery проверена. Проверь устройства перед переносом."}catch{status = .key(Self.message(error))}
    }
    func applyCoconutImport()async {
        guard let review=importReview,!busy else{return};importReview=nil;busy=true;app?.busy=true;defer{busy=false;app?.busy=false}
        do{let result=try await store.apply(review);devices=try await store.devices();await reloadHistory();status = .format("Перенесено замеров: %@. Уже были или пропущены: %@. Новых устройств: %@.",[String(result.inserted),String(result.skipped),String(result.devices)])}catch{status = .key(Self.message(error))}
    }
    static func message(_ error:Error)->String {
        if let error=error as? CoconutFailure{switch error{
        case .appMissing:return "Для чтения этой экспортной копии нужен установленный coconutBattery. После переноса история работает самостоятельно."
        case .keyMismatch:return "Экспортная копия coconutBattery не прошла проверку подлинности или создана несовместимой версией. История не изменена."
        case .decompressionLimit:return "Копия превышает допустимый размер после распаковки. Перенос остановлен."
        default:return "Не удалось прочитать этот формат истории. Выбери штатную копию .ccba из coconutBattery."
        }}
        switch error as? BatteryFailure{
        case .recoveryLimit:return "Сохранены три защитных снимка базы. Новые переносы приостановлены до выбора места для их архива; прежняя история доступна."
        case .identityConflict:return "Идентификаторы устройств противоречат друг другу. Автоматическое объединение остановлено; имена не используются для сопоставления."
        case .unavailable:return "Система не передала сведения о батарее. Отсутствующие значения не заменяются нулями."
        case .historyLimit:return "Достигнут лимит базы истории. Старые замеры сохранены; автоматического удаления нет."
        case .unsupportedSchema:return "Формат базы истории не поддержан. Файл сохранен без замены."
        case .invalidReading:return "Показания батареи не прошли проверку. Замер не записан."
        case .unsafePath:return "Папка истории не прошла проверку безопасности. Выбери действие после проверки файла базы."
        case .exportExists:return "Назначение уже существует или относится к внутреннему хранилищу. Выбери новый файл."
        case .database:return "Не удалось записать или прочитать историю батареи. Прежняя база сохранена."
        default:return "Не удалось прочитать батарею iPhone. Разблокируй устройство и проверь USB-подключение."
        }
    }
}
