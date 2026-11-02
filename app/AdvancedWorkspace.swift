import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

struct HomeItem:Decodable,Identifiable {let id:String;let name:String;let kind:String;let bundle:String;let children:[HomeItem]?}
struct IndicatorMatch:Decodable,Identifiable {let indicator:String;let kind:String;let value:String;let dataset:String;let record:String;var id:String{indicator+kind+value+dataset+record}}
struct IndicatorCoverage:Decodable,Identifiable {let source:String;let count:Int;let status:String;var id:String{source}}
struct IndicatorFeed:Decodable {let sha256:String;let supported:Int;let unsupported_or_inactive:Int}
struct IndicatorResult:Decodable {let matches:[IndicatorMatch];let coverage:[IndicatorCoverage];let feed:IndicatorFeed;let partial:Bool;let matches_truncated:Bool}

enum PrivateReportWriter {
    static func write(_ files:[String:Data],parent:URL,kind:String)throws->URL {
        guard MediaIntegrity.canonical(parent) else{throw BridgeError(code:"unsafe_output_folder")}
        let forbidden=["/Applications",PublicEdition.dataRoot.path,Bundle.main.bundleURL.standardizedFileURL.path]
        guard !forbidden.contains(where:{parent.path==$0 || parent.path.hasPrefix($0+"/")}),files.count<=8,files.values.reduce(0,{$0+$1.count})<=32*1024*1024 else{throw BridgeError(code:"private_data_in_public_folder")}
        let root=parent.appendingPathComponent("AppRestore-"+kind+"-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var entries:[[String:Any]]=[]
        for name in files.keys.sorted(){guard MediaIntegrity.name(name),let data=files[name] else{throw BridgeError(code:"unsafe_filename")};let path=root.appendingPathComponent(name);try data.write(to:path,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path);let copied=try Data(contentsOf:path);guard copied==data else{throw BridgeError(code:"copy_verification_failed")};entries.append(["path":name,"bytes":data.count,"sha256":MediaIntegrity.sha(data)])}
        let receipt:[String:Any]=["schema":1,"status":"verified","source_deleted":false,"shared_cache":false,"count":entries.count,"bytes":files.values.reduce(0,{$0+$1.count}),"files":entries]
        let receiptURL=root.appendingPathComponent("receipt.json");try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:receiptURL,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptURL.path)
        return root
    }
    static func jsonHTML(_ object:Any,title:String)throws->[String:Data] {
        let data=try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]);let text=String(decoding:data,as:UTF8.self).replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
        return ["report.json":data,"report.html":Data(("<!doctype html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>"+title+"</title><h1>"+title+"</h1><pre>"+text+"</pre>").utf8)]
    }
}

extension DeviceWorkspace {
    func readHome()async {await perform{
        let result=try await self.call(self.request("home_layout"));self.homeItems=try self.decode([HomeItem].self,result["items"] ?? []);self.homeUnsupported=result["unsupported"] as? Int ?? 0;self.status="Снимок расположения значков прочитан. Порядок на iPhone не менялся."
    }}
    func exportHome()async {guard let parent=PrivatePanels.folder() else{return};await stage("home_export_plan",values:["destination":parent.path],title:"Сохранить снимок домашнего экрана?")}
    func exportCrash()async {guard let report=selectedReport,let parent=PrivatePanels.folder() else{return};await stage("crash_export_plan",values:["path":report.id,"destination":parent.path],title:"Сохранить полный выбранный отчет?")}
    func readDeveloper()async {await perform{
        let result=try await self.call(self.request("developer_status"));self.developer=result.compactMapValues{value in if let str=value as? String{return str};if let flag=value as? Bool{return flag ? "yes":"no"};return nil};self.status="Условия доступа проверены. Режим разработчика, образы и доверие автоматически не меняются."
    }}
    func captureScreen()async {await perform{
        let result=try await self.call(self.request("screen_capture",["confirmed":true]));guard let raw=result["png"] as? String,let data=Data(base64Encoded:raw),PublicMediaPolicy.normalizedPNG(data) != nil else{throw BridgeError(code:"invalid_screenshot")};self.screenData=data;self.status="Снимок экрана находится в памяти. Сохранение запускается отдельной кнопкой."
    }}
    func saveScreen()async {guard let data=screenData,let parent=PrivatePanels.folder() else{return};await perform{self.lastDirectory=try PrivateReportWriter.write(["screen.png":data],parent:parent,kind:"Screenshot").path;self.status="Снимок экрана сохранен и проверен в выбранной папке."}}
    func launchApp()async {guard !launchBundle.isEmpty else{return};await stage("launch_plan",values:["bundle":launchBundle],title:"Открыть выбранное приложение на iPhone?")}
    func chooseIndicators(){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.allowedContentTypes=[.json,UTType(filenameExtension:"stix2") ?? .data];if panel.runModal() == .OK,let url=panel.url{indicatorFile=url.path;indicatorResult=nil}}
    var indicatorRequest:[String:Any]{["backup_directory":backupDirectory,"backup_password":backupPassword,"indicator_file":indicatorFile,"sources":["apps"]+(indicatorFiles ? ["filenames"]:[])+(indicatorSMS ? ["sms"]:[])+(indicatorSafari ? ["safari"]:[])]}
    func checkIndicators()async {await perform{self.indicatorResult=try self.decode(IndicatorResult.self,await self.call(self.request("ioc_check",self.indicatorRequest)));self.status="Проверка индикаторов завершена. Изучи охват и пропуски; это не заключение об отсутствии угроз."}}
    func exportIndicators()async {guard let parent=PrivatePanels.folder() else{return};var data=indicatorRequest;data["destination"]=parent.path;await stage("ioc_export_plan",values:data,title:"Сохранить отчет проверки индикаторов?")}
    func exportQueue()async {guard let parent=PrivatePanels.folder() else{return};await perform{
        let rows=self.queue.map{item->[String:Any] in ["app_id":item.id,"name":item.name,"state":item.state,"error":item.error,"bundle":item.bundle,"version":item.version,"minimum_ios":item.minimumIOS,"checked_ios":item.checkedIOS,"launch_confirmed_by_owner":item.launchConfirmed]}
        let object:[String:Any]=["schema":1,"items":rows,"contains_credentials":false,"installation_does_not_prove_launch":true]
        self.lastDirectory=try PrivateReportWriter.write(PrivateReportWriter.jsonHTML(object,title:"AppRestore queue report"),parent:parent,kind:"Queue").path;self.status="Отчет очереди сохранен. Запуск подтверждается отдельно владельцем устройства."
    }}
}

struct HomeWorkspace:View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject var work:DeviceWorkspace
    var body:some View {VStack(alignment:.leading,spacing:16){HStack{Button(L("Прочитать расположение значков")){Task{await work.readHome()}};Button(L("Сохранить снимок…")){Task{await work.exportHome()}}.disabled(work.homeItems.isEmpty)};Text(L("Снимок сохраняет доступные названия, папки и порядок. Виджеты могут быть неподдержаны. Обратное изменение расположения отключено.")).foregroundStyle(.secondary);if work.homeUnsupported>0{Text(LF("Неподдержанных элементов: %@",String(work.homeUnsupported))).foregroundStyle(.orange)};List{OutlineGroup(work.homeItems,children:\.children){item in HStack{Image(systemName:item.kind=="folder" || item.kind=="section" ? "folder":"app");Text(item.name);Spacer();Text(item.bundle).font(.caption).foregroundStyle(.secondary)}}}}.padding(24).disabled(work.busy || work.app.busy || work.app.preview)}
}

struct ToolsWorkspace:View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject var work:DeviceWorkspace
    private var blocked:Bool{work.busy || work.app.busy || work.app.preview}
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:22){
        GroupBox(L("Экран и запуск приложений")){VStack(alignment:.leading,spacing:14){Text(L("Нужны совместимая iOS, уже включенный режим разработчика и подготовленные инструменты Apple. AppRestore не включает их и не скачивает образы автоматически.")).foregroundStyle(.secondary);HStack{Button(L("Проверить условия")){Task{await work.readDeveloper()}};Button(L("Снять экран iPhone")){Task{await work.captureScreen()}};if work.screenData != nil{Button(L("Сохранить PNG…")){Task{await work.saveScreen()}};Button(L("Закрыть снимок")){work.screenData=nil}}};ForEach(work.developer.keys.sorted(),id:\.self){key in LabeledContent(key,value:work.developer[key]!)};if let data=work.screenData,let png=PublicMediaPolicy.normalizedPNG(data),let image=NSImage(data:png){Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:320)};HStack{Button(L("Прочитать приложения")){Task{await work.readInstalled()}};Picker(L("Открыть на iPhone"),selection:$work.launchBundle){Text(L("Выбрать…")).tag("");ForEach(work.installed){Text($0.name).tag($0.bundle)}};Button(L("Открыть")){Task{await work.launchApp()}}.disabled(work.launchBundle.isEmpty)}}.padding(12)}
        GroupBox(L("Локальная проверка индикаторов")){VStack(alignment:.leading,spacing:14){Text(L("Ограниченная проверка выбранной копии по локальному STIX2: домены, URL, App ID и имена файлов. Совпадения требуют разбора специалистом; отсутствие совпадений не доказывает безопасность. Это не полный MVT.")).foregroundStyle(.secondary);HStack{Button(L("Выбрать копию…")){Task{await work.chooseBackup()}};Text(URL(fileURLWithPath:work.backupDirectory).lastPathComponent).lineLimit(1)};SecureField(L("Пароль резервной копии"),text:$work.backupPassword).textFieldStyle(.roundedBorder).frame(minHeight:28);HStack{Button(L("Выбрать STIX2…")){work.chooseIndicators()};Text(URL(fileURLWithPath:work.indicatorFile).lastPathComponent).lineLimit(1)};Text(L("Всегда: идентификаторы приложений. Дополнительные источники читаются только после выбора:"));Toggle(L("Имена файлов в каталоге копии"),isOn:$work.indicatorFiles);Toggle(L("Ссылки в текстах SMS / iMessage"),isOn:$work.indicatorSMS);Toggle(L("Адреса истории Safari"),isOn:$work.indicatorSafari);HStack{Button(L("Проверить локально")){Task{await work.checkIndicators()}}.disabled(work.backupDirectory.isEmpty || work.indicatorFile.isEmpty);Button(L("Сохранить отчет…")){Task{await work.exportIndicators()}}.disabled(work.indicatorResult==nil)};if let result=work.indicatorResult{Text(LF("Поддержано индикаторов: %@. Пропущено: %@. Совпадений: %@.",String(result.feed.supported),String(result.feed.unsupported_or_inactive),String(result.matches.count))).font(.headline);Text(result.feed.sha256).font(.caption.monospaced()).textSelection(.enabled);ForEach(result.coverage){row in LabeledContent(row.source,value:String(row.count)+" · "+row.status)};if result.partial{Text(L("Охват неполный: проверь пропущенные источники и лимиты.")).foregroundStyle(.orange)};ForEach(result.matches){match in VStack(alignment:.leading){Text(match.value).font(.headline);Text(match.dataset+" · "+match.record+" · "+match.kind).font(.caption).foregroundStyle(.secondary)}.textSelection(.enabled)}}}.padding(12)}
    }.padding(24)}.disabled(blocked).onChange(of:work.indicatorSMS){_,_ in work.indicatorResult=nil}.onChange(of:work.indicatorSafari){_,_ in work.indicatorResult=nil}.onChange(of:work.indicatorFiles){_,_ in work.indicatorResult=nil}.onChange(of:work.backupDirectory){_,_ in work.indicatorResult=nil}.onChange(of:work.backupPassword){_,_ in work.indicatorResult=nil}}
}

@MainActor final class DocumentDropState:ObservableObject {@Published var targeted=false}
struct DocumentDropArea:View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject var work:DeviceWorkspace
    @StateObject private var state=DocumentDropState()
    var body:some View {Label(L("Перетащи сюда файлы для выбранного приложения"),systemImage:"square.and.arrow.up.on.square").frame(maxWidth:.infinity).padding(18).background(state.targeted ? Color.accentColor.opacity(0.16):Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(state.targeted ? Color.accentColor:Color.secondary.opacity(0.2))).onDrop(of:[UTType.fileURL.identifier],isTargeted:$state.targeted){providers in
        guard !work.busy,!work.app.busy,!work.app.preview,!work.sharingBundle.isEmpty,providers.count<=100 else{return false}
        let bundle=work.sharingBundle,path=work.documentPath,device=work.app.target
        Task{@MainActor in
            var urls:[URL]=[]
            for provider in providers {
                let data:Data
                do {data=try await withCheckedThrowingContinuation{continuation in
                    let gate=MediaReadReply(continuation)
                    DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+15){gate.finish(.failure(BridgeError(code:"operation_cancelled")))}
                    provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){value,_ in
                        if let value,value.count<=65536{gate.finish(.success(value))}else{gate.finish(.failure(BridgeError(code:"invalid_request")))}
                    }
                }}catch{work.status="Не удалось прочитать перетаскиваемые файлы. Выбери их кнопкой «На iPhone».";return}
                guard let url=URL(dataRepresentation:data,relativeTo:nil),url.isFileURL else{return};urls.append(url)
            }
            guard !work.busy,!work.app.busy,work.app.target==device,work.sharingBundle==bundle,work.documentPath==path else{work.status="Назначение изменилось. Повтори перетаскивание файлов.";return};await work.uploadDocuments(urls)
        };return true
    }.disabled(work.sharingBundle.isEmpty)}
}
