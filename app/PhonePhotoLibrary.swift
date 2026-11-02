import AppKit
import Combine

struct PhoneAsset:Identifiable {
    let record:USBMediaFile
    let source:MediaSource
    let id:String
    init(record:USBMediaFile){self.record=record;self.source=record.source;self.id=record.source.id}
    var name:String{record.name}
    var bytes:Int64{record.bytes}
}
final class MediaReadReply:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Data,Error>?
    init(_ value:CheckedContinuation<Data,Error>){continuation=value}
    func finish(_ value:Result<Data,Error>){lock.lock();let c=continuation;continuation=nil;lock.unlock();c?.resume(with:value)}
}

// Starts only on the owner's Read Media Library action. Only selected USB DCIM is exposed.
@MainActor final class PhonePhotoLibrary:ObservableObject {
    @Published var assets:[PhoneAsset]=[]
    @Published var selected=Set<String>()
    @Published var thumbnails:[String:NSImage]=[:]
    @Published var status:UIMessage="Выбери «Прочитать медиатеку», чтобы открыть фотографии этого iPhone."
    @Published var busy=false
    @Published var loading=false
    @Published var phase="idle"
    @Published var fraction:Double=0
    @Published var lastDirectory=""
    @Published var showConfirmation=false
    @Published var confirmation=""
    @Published var search=""
    @Published var kind="all"
    @Published var filterDates=false
    @Published var since=Date().addingTimeInterval(-30*86400)
    @Published var until=Date()
    @Published var jpegCopies=false
    private let catalogBridge=USBBridge(),thumbnailBridge=USBBridge(),stream=USBMediaStream()
    private var connected=false,udid=""
    private var generation=UUID()
    private var cancellation=MediaCancellation()
    private var pending:([MediaSource],URL,OriginalMediaJob?,UUID,Bool)?
    private let worker=MediaCopyWorker()
    private var previewQueue:[PhoneAsset]=[],attempted=Set<String>(),thumbnailOrder:[String]=[]
    private var previewTask:Task<Void,Never>?
    private var previewEpoch=UUID()
    private var activeStream:String?
    var visible:[PhoneAsset] {
        let start=Calendar.current.startOfDay(for:since),end=Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:until)) ?? until
        return assets.filter{asset in
            (search.isEmpty || asset.name.localizedCaseInsensitiveContains(search)) && (kind=="all" || asset.source.kind==kind) &&
            (!filterDates || (asset.source.created ?? asset.source.modified).map{$0>=start && $0<end} == true)
        }
    }
    func selectVisible(){guard visible.count<=10000 else{status="Выбор превышает лимит: 10 000 файлов или 256 ГБ.";return};selected=Set(visible.filter{$0.bytes>0}.map(\.id))}
    func connect(udid:String)async {
        guard !busy,!udid.isEmpty else{return};disconnect();self.udid=udid
        let generation=self.generation;busy=true;loading=true;phase="loading";fraction=0
        status="Разблокируй iPhone. Читаем локальные фото и видео по USB…"
        defer{if self.generation==generation{busy=false;loading=false;startPreviews()}}
        do {
            var folders=["/DCIM"],seen=Set<String>(),all:[String:PhoneAsset]=[:],index=0,skipped=0
            while index<folders.count {
                try cancellation.check();guard self.generation==generation else{throw BridgeError(code:"operation_cancelled")}
                let folder=folders[index];index+=1;guard seen.insert(folder).inserted else{continue};guard seen.count<=4096 else{throw BridgeError(code:"media_catalog_limit")}
                var offset=0,token=""
                while true {
                    let response=try await catalogBridge.call(["action":"media_catalog_page","udid":udid,"path":folder,"offset":offset,"catalog_token":token])
                    guard self.generation==generation else{throw BridgeError(code:"operation_cancelled")};try cancellation.check()
                    let page=try JSONDecoder().decode(USBMediaPage.self,from:JSONSerialization.data(withJSONObject:response))
                    guard page.files.count<=300,page.folders.count<=300,page.next_offset>offset || !page.has_more else{throw BridgeError(code:"invalid_media_page")}
                    for file in page.files{try file.validate();let item=PhoneAsset(record:file);all[item.id]=item}
                    for child in page.folders{guard child.hasPrefix(folder+"/"),child.utf8.count<=1800 else{throw BridgeError(code:"unsafe_media_path")};folders.append(child)}
                    guard all.count<=100000,folders.count<=4096 else{throw BridgeError(code:"media_catalog_limit")}
                    skipped+=page.skipped;assets=Array(all.values);status = .format("Читаем каталог по USB. Найдено файлов: %@.",[String(assets.count)])
                    if !page.has_more{break};offset=page.next_offset;token=page.catalog_token
                }
            }
            assets.sort{($0.source.created ?? $0.source.modified ?? .distantPast)>($1.source.created ?? $1.source.modified ?? .distantPast)}
            connected=true;phase=assets.isEmpty ? "empty":"ready"
            status = assets.isEmpty ? .key("В доступном DCIM нет локальных медиафайлов. Оригиналы могут быть только в iCloud; альбомы «С Mac» не относятся к DCIM.") : .format("Медиафайлов по USB: %@. Исходники не изменялись.",[String(assets.count)])
        }catch{
            phase=assets.isEmpty ? "error":"partial";connected = !assets.isEmpty
            status = assets.isEmpty ? .key(Self.errorText(error)) : .sequence([.key("Каталог прочитан не полностью. Показаны только найденные файлы. "),.key(Self.errorText(error))])
        }
    }
    func disconnect(){
        guard !busy else{return};generation=UUID();catalogBridge.cancel();stopPreviews();stream.cancel()
        connected=false;udid="";assets=[];selected=[];thumbnails=[:];pending=nil;lastDirectory="";phase="idle";activeStream=nil;cancellation=MediaCancellation();previewQueue=[];attempted=[];thumbnailOrder=[]
    }
    func cancel(){cancellation.cancel();catalogBridge.cancel();stopPreviews();stream.cancel()}
    func thumbnail(_ asset:PhoneAsset){
        guard (!busy || loading),(connected || loading),asset.source.kind=="image",asset.bytes>0,asset.bytes<=8*1024*1024,thumbnails[asset.id]==nil,attempted.insert(asset.id).inserted else{return}
        previewQueue.append(asset);startPreviews()
    }
    private func stopPreviews(){previewEpoch=UUID();thumbnailBridge.cancel();previewTask?.cancel();previewTask=nil;previewQueue=[];attempted=Set(thumbnails.keys)}
    private func startPreviews(){
        guard previewTask==nil,!busy,connected,!previewQueue.isEmpty else{return};let generation=self.generation,epoch=previewEpoch
        previewTask=Task{@MainActor in
            defer{if self.previewEpoch==epoch{self.previewTask=nil}}
            while !self.previewQueue.isEmpty,!Task.isCancelled,self.generation==generation,self.previewEpoch==epoch,!self.busy {
                let item=self.previewQueue.removeFirst()
                do{
                    let response=try await self.thumbnailBridge.call(["action":"media_preview","udid":self.udid,"path":item.record.path,"fingerprint":item.record.fingerprint])
                    guard self.generation==generation,self.previewEpoch==epoch,!Task.isCancelled,let raw=response["data"] as? String,let data=Data(base64Encoded:raw) else{return}
                    let png=await Task.detached(priority:.utility){PrivateMediaPreview.png(data)}.value
                    guard self.generation==generation,self.previewEpoch==epoch,!Task.isCancelled else{return}
                    if let png,let image=NSImage(data:png){
                        if self.thumbnailOrder.count>=256{let old=self.thumbnailOrder.removeFirst();self.thumbnails.removeValue(forKey:old);self.attempted.remove(old)}
                        self.thumbnails[item.id]=image;self.thumbnailOrder.append(item.id)
                    }
                }catch{if Task.isCancelled || self.generation != generation{return}}
            }
        }
    }
    private func expanded()throws->[MediaSource] {
        try MediaGrouping.plan(assets.map(\.source),selected:selected,groups:[:],related:[:])
    }
    func prepareExport(){
        guard !busy,!selected.isEmpty,connected,let folder=PrivatePanels.folder() else{return}
        do{let sources=try expanded();pending=(sources,folder,nil,generation,jpegCopies);review(sources,resume:false)}catch{status = .key(Self.errorText(error))}
    }
    func prepareResume(){
        guard !busy,connected,let folder=PrivatePanels.folder() else{return}
        do{let job=try OriginalMediaJob(resuming:folder,device:udid),ids=Set(assets.map(\.id));for source in job.receipt.sources{guard ids.contains(source.id) else{throw BridgeError(code:"source_changed")}};pending=(job.receipt.sources,folder,job,generation,job.receipt.jpegCopies);review(job.receipt.sources,resume:true)}catch{status = .key(Self.errorText(error))}
    }
    private func review(_ sources:[MediaSource],resume:Bool){
        confirmation=LF("Объектов: %@. Объем: %@. Будет создана новая папка; исходники сохранятся.",String(sources.count),humanSize(sources.reduce(0){$0+$1.bytes}))
        if resume{confirmation=L("Продолжим выбранную копию. Существующие байты повторно читаются с iPhone и сравниваются; подтвержденные файлы не перезаписываются.")}
        confirmation+="\n"+L("Прямой USB-доступ копирует байты локальных файлов DCIM без перекодирования. Одноименные части Live Photo и сопутствующие файлы сохраняются рядом. Это не полный каталог iCloud и синхронизированных альбомов.")
        if pending?.4 == true{confirmation+="\n"+L("Дополнительно создаются JPEG-копии HEIC. Это преобразование с потерями, возможна потеря HDR; исходные HEIC сохраняются отдельно.")}
        showConfirmation=true
    }
    func discard(){pending=nil;showConfirmation=false}
    private func validate(_ id:String,generation:UUID)async throws {
        guard self.generation==generation,connected,let item=assets.first(where:{$0.id==id}) else{throw BridgeError(code:"source_changed")}
        if activeStream==id {try await stream.finish(id);activeStream=nil}
        else{guard activeStream==nil else{throw BridgeError(code:"invalid_media_stream")};try await stream.begin(item.record,udid:udid);activeStream=id}
    }
    private func read(_ id:String,offset:Int64,count:Int,generation:UUID)async throws->Data {
        guard self.generation==generation,connected,activeStream==id else{throw BridgeError(code:"source_changed")}
        return try await stream.read(id,offset:offset,count:count)
    }
    func export()async {
        guard let(sources,folder,resume,generation,jpeg)=pending,!busy else{return};pending=nil;showConfirmation=false;busy=true;cancellation=MediaCancellation();fraction=0
        stopPreviews()
        defer{busy=false;activeStream=nil;for item in visible.prefix(40){thumbnail(item)}}
        do{
            let job=try resume ?? OriginalMediaJob(parent:folder,sources:sources,device:udid,jpeg:jpeg);lastDirectory=job.root.path;let library=self
            try await worker.run(job,cancel:cancellation,read:{id,offset,count in try await library.read(id,offset:offset,count:count,generation:generation)},validate:{id in try await library.validate(id,generation:generation)},progress:{value in Task{@MainActor in library.fraction=value}})
            status="Оригиналы скопированы и проверены по размеру и SHA-256. На iPhone ничего не удалено."
        }catch{stream.cancel();status = .key(Self.errorText(error))}
        await stream.stop()
    }
    static func errorText(_ error:Error)->String {
        switch(error as? BridgeError)?.code{
        case "media_device_mismatch":return "Выбранная копия относится к другому устройству или старому формату журнала. Исходники сохранены."
        case "media_prefix_mismatch":return "Сохраненный файл отличается от iPhone. Продолжение остановлено; файлы не заменены."
        case "invalid_media_receipt","unverified_existing_file","unverified_derived_file":return "Журнал копирования или существующий файл не подтвержден. Автоматическая перезапись отключена."
        case "source_changed":return "Состав или сведения исходных медиа изменились. Продолжение остановлено."
        case "unsupported_heic","jpeg_conversion_failed":return "JPEG-копия не создана. Исходный HEIC сохранен; проверь ограничения формата."
        case "ambiguous_media_names":return "В одной группе есть одинаковые имена файлов. Выбери их раздельно; перезапись отключена."
        case "media_catalog_changed":return "Состав папки на iPhone изменился во время чтения. Обнови медиатеку."
        case "media_catalog_limit":return "Медиатека превышает лимит каталога. Показанный результат может быть неполным."
        case "media_original_unavailable":return "Локальный оригинал недоступен. Проверь наличие файла на самом iPhone."
        case "media_read_timeout":return "iPhone не ответил вовремя. Незавершенная копия сохранена для продолжения."
        case "photo_read_failed","usb_failed":return "Не удалось прочитать медиа по USB. Разблокируй iPhone, проверь кабель и повтори чтение."
        default:return DeviceWorkspace.errorText((error as? BridgeError)?.code ?? "photo_export_failed")
        }
    }
}
