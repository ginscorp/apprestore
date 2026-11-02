import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class PhoneAlbumSync:ObservableObject {
    @Published var album="AppRestore"
    @Published var busy=false
    @Published var fraction:Double=0
    @Published var status:UIMessage="Подготовь фото и видео для USB-альбома «С моего Mac»."
    @Published var pending:PhoneAlbumPlan?
    @Published var review=false
    @Published var root:URL?
    private let builder=PhoneAlbumBuilder()
    private var cancellation=MediaCancellation()
    func cancel(){cancellation.cancel()}
    func clear(){guard !busy else{return};pending=nil;review=false;root=nil;album="AppRestore";status="Подготовь фото и видео для USB-альбома «С моего Mac»."}
    func prepare(_ device:Device)async {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.allowedContentTypes=[.png,.jpeg,.heic,.movie]
        guard panel.runModal() == .OK,!panel.urls.isEmpty,let parent=PrivatePanels.folder() else{return};busy=true;cancellation=MediaCancellation();defer{busy=false}
        do{pending=try await builder.plan(urls:panel.urls,parent:parent,album:album,device:device.udid,name:device.name,cancel:cancellation);review=true;status="План USB-альбома готов. Проверь состав и назначение."}catch{status = .key(DeviceWorkspace.errorText((error as? BridgeError)?.code ?? "album_failed"))}
    }
    func build()async {
        guard let plan=pending,!busy else{return};review=false;pending=nil;busy=true;cancellation=MediaCancellation();fraction=0;defer{busy=false}
        do{root=try await builder.build(plan,cancel:cancellation,progress:{[weak self] value in Task{@MainActor in self?.fraction=value}});status="Альбом подготовлен и проверен на Mac. Теперь выбери его папку Sync в Finder и выполни синхронизацию с нужным iPhone."}catch{status = .key(DeviceWorkspace.errorText((error as? BridgeError)?.code ?? "album_failed"))}
    }
    func openFinder(){if let root{NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:root.appendingPathComponent("Sync").path)}}
}

struct PhoneAlbumSyncView:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    @ObservedObject var work:DeviceWorkspace
    @ObservedObject var sync:PhoneAlbumSync
    var body:some View {
        DisclosureGroup(L("На iPhone по USB: альбом «С моего Mac»")){
            VStack(alignment:.leading,spacing:12){
                Text(L("Без приложения на iPhone и без подписи разработчика. Альбом будет управляться с Mac, не входит в Camera Roll и недоступен при включенных «Фото iCloud». Live Photo при такой синхронизации теряет живой эффект.")).font(.caption).foregroundStyle(.secondary)
                HStack{TextField(L("Название альбома"),text:$sync.album).textFieldStyle(.roundedBorder);Button(L("Выбрать файлы и папку…")){Task{guard let device=work.device else{return};work.app.busy=true;defer{work.app.busy=false};await sync.prepare(device)}}.disabled(work.device?.paired != true || work.app.busy || work.busy || sync.busy || work.photos.busy);if sync.root != nil{Button(L("Открыть папку Sync в Finder")){sync.openFinder()}}}
                Text(L("В Finder: выбери нужный iPhone → «Фото» → синхронизация из папки Sync → включи видео при необходимости → «Применить». Если Apple предлагает заменить или удалить прежние альбомы, сначала проверь состав; AppRestore это предупреждение не подтверждает.")).font(.caption).foregroundStyle(.secondary)
                Text(L("Подготовленная папка должна оставаться на Mac для следующих синхронизаций. Finder может менять формат на устройстве; исходные файлы в подготовленной папке сохраняются без перекодирования.")).font(.caption).foregroundStyle(.secondary)
                Text(sync.status.text).font(.caption).textSelection(.enabled)
                if sync.busy{HStack{ProgressView(value:sync.fraction).frame(width:160);Button(L("Отменить")){sync.cancel()}}}
            }.padding(.vertical,8)
        }
        .sheet(isPresented:$sync.review){VStack(alignment:.leading,spacing:14){Text(L("Подготовить USB-альбом?")).font(.title2.bold());if let plan=sync.pending{Text(plan.deviceName+" · "+plan.album);Text(LF("Объектов: %@. Объем: %@. Будет создана новая папка; исходники сохранятся.",String(plan.files.count),humanSize(plan.bytes)));Text(plan.parent.path).font(.caption).textSelection(.enabled);ScrollView{VStack(alignment:.leading){ForEach(plan.files,id:\.url){Text($0.name)}}}.frame(maxHeight:180)};Text(L("Сейчас файлы копируются только в новую папку на Mac. Последующая синхронизация выполняется в Finder и может затронуть ранее синхронизированные альбомы."));HStack{Button(L("Отменить")){sync.pending=nil;sync.review=false};Spacer();Button(L("Подготовить альбом")){Task{work.app.busy=true;defer{work.app.busy=false};await sync.build()}}.buttonStyle(.borderedProminent)}}.padding(26).frame(width:560).interactiveDismissDisabled()}
    }
}
