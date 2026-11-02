import SwiftUI
import AppKit

struct WorkspaceContent:View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject var work:DeviceWorkspace
    @ObservedObject var model:AppModel
    var body:some View {
        GeometryReader{geometry in
            content.frame(width:max(680,geometry.size.width),height:max(600,geometry.size.height),alignment:.topLeading)
        }
    }
    private var content:some View {
        VStack(alignment:.leading,spacing:0){
            HStack(spacing:14){Image(systemName:work.tab.symbol).font(.largeTitle).foregroundStyle(.tint);VStack(alignment:.leading,spacing:4){Text(work.tab.title).font(.title.bold());Text(subtitle).font(.callout).foregroundStyle(.secondary)};Spacer()}.padding(24)
            Divider()
            Group {switch work.tab {
            case .overview:overview
            case .battery:BatteryWorkspace(monitor:work.battery)
            case .installed:installed
            case .queue:queue
            case .diagnostics:diagnostics
            case .photos:PhotoWorkspace(work:work,photos:work.photos,model:model)
            case .documents:documents
            case .backups:backups
            case .archive:archive
            case .profiles:profiles
            case .home:HomeWorkspace(work:work)
            case .tools:ToolsWorkspace(work:work)
            case .catalog:EmptyView()
            }}.frame(maxWidth:.infinity,alignment:.topLeading)
            Divider()
            HStack{if work.busy{ProgressView(value:work.fraction).frame(width:90)};Text(work.tab == .battery ? L("История батареи хранится отдельно от публичного кеша."):work.tab == .overview ? L("Технические сведения обновляются автоматически и сохраняются локально."):work.status.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3);Spacer();if work.busy && work.canCancel{Button(L("Отменить")){model.usb.cancel()}};if !work.lastDirectory.isEmpty{Button(L("Показать в Finder")){NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:work.lastDirectory)}}}.padding(14)
        }
        .sheet(isPresented:$work.showConfirmation){VStack(alignment:.leading,spacing:20){Text(work.confirmationTitle).font(.title2.bold());Text(work.confirmationDetail).textSelection(.enabled);HStack{Button(L("Отменить")){work.discardPlan()};Spacer();Button(L("Продолжить")){Task{await work.commitPlan()}}.buttonStyle(.borderedProminent)}}.padding(28).frame(width:540).interactiveDismissDisabled()}
        .confirmationDialog(L("Восстановить очередь на выбранном iPhone?"),isPresented:$work.showQueueConfirmation,titleVisibility:.visible){Button(L("Восстановить")){Task{await work.restoreQueue()}}}message:{Text((work.device?.name ?? "iPhone")+" · iOS "+(work.device?.ios ?? "")+"\n"+work.queue.map(\.name).joined(separator:", ")+"\n"+L("Для каждого приложения Apple проверит доступ текущего аккаунта. Платные покупки и автоматическое получение лицензий отключены."))}
    }
    private var subtitle:String {if work.tab == .overview{return L("Устройство, свободная память и состояние батареи.")};if work.tab == .battery{return L("Заряд, емкость и локальная история Mac и iPhone.")};return L(work.tab == .archive ? "Выбранная локальная копия. Данные не отправляются в сеть." : "Выбранное устройство и явное действие для каждого набора данных.")}
    private var blocked:Bool{model.busy || work.busy || work.photos.busy || model.preview}
    private func action(_ title:String,_ symbol:String,_ body:@escaping ()async->Void)->some View{Button{Task{await body()}}label:{Label(L(title),systemImage:symbol)}.disabled(blocked)}
    private func note(_ title:String)->some View{Text(L(title)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
    private func metric(_ title:String,_ value:String)->some View{GroupBox{VStack(alignment:.leading,spacing:10){Text(L(title)).foregroundStyle(.secondary);Text(value).font(.title2.weight(.semibold)).textSelection(.enabled)}.frame(maxWidth:.infinity,alignment:.leading).padding(8)}}
    private var overview:some View {DeviceOverviewView(work:work,monitor:work.battery)}
    private var installed:some View {
        VStack(alignment:.leading,spacing:14){HStack{action("Прочитать установленные приложения","app.badge"){await work.readInstalled()};TextField(L("Название или bundle ID"),text:$work.installedSearch).textFieldStyle(.roundedBorder)}.padding(.horizontal,24).padding(.top,18)
            List(work.filteredInstalled){app in HStack(spacing:14){Group{if let image=work.deviceImages[app.bundle]{Image(nsImage:image).resizable().scaledToFill()}else{Image(systemName:"app.fill").resizable().scaledToFit().padding(8).foregroundStyle(.tint)}}.frame(width:48,height:48).clipShape(RoundedRectangle(cornerRadius:11));VStack(alignment:.leading,spacing:4){Text(app.name).font(.headline);Text(app.bundle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled);Text("v"+app.version+" · min iOS "+(app.minimum_ios ?? "—")).font(.caption2).foregroundStyle(.secondary)};Spacer();Button(L("Иконка")){Task{await work.readIcon(app)}}.disabled(blocked);Button(L("В каталоге")){work.findInCatalog(app)}.disabled(blocked || app.app_id==nil)}.padding(.vertical,5)}
        }
    }
    private var queue:some View {
        VStack(alignment:.leading,spacing:16){HStack{Button(L("Восстановить")){work.showQueueConfirmation=true}.buttonStyle(.borderedProminent).disabled(blocked || work.queue.isEmpty || model.account.isEmpty || model.target.isEmpty);if work.busy{Button(L("Остановить после текущего")){work.queueStop=true}}else{Button(L("Очистить очередь")){work.queue=[]}}}.padding(.horizontal,24).padding(.top,18)
            Toggle(L("Разрешить замену уже установленных приложений"),isOn:$work.queueReplaceExisting).disabled(blocked).padding(.horizontal,24)
            note("Добавляй приложения из карточек каталога. Очередь выполняется последовательно в одном сеансе Apple ID; уже установленные приложения по умолчанию пропускаются.").padding(.horizontal,24)
            Button(L("Сохранить отчет очереди…")){Task{await work.exportQueue()}}.disabled(blocked || work.queue.isEmpty).padding(.horizontal,24)
            List($work.queue){$item in HStack{VStack(alignment:.leading){Text(item.name).font(.headline);Text("App ID "+String(item.id)+" · "+item.version).font(.caption).foregroundStyle(.secondary)};Spacer();Text(L(item.state)).foregroundStyle(item.error.isEmpty ? Color.secondary:Color.orange);if !item.error.isEmpty{Text(item.error).font(.caption).textSelection(.enabled)};Toggle(L("Запуск проверен владельцем"),isOn:$item.launchConfirmed).toggleStyle(.checkbox).disabled(blocked || item.state != "Установлено")}}
        }
    }
    private var diagnostics:some View {
        VStack(alignment:.leading,spacing:16){HStack{action("Прочитать отчеты о сбоях","stethoscope"){await work.readReports()};action("Сохранить полный отчет…","square.and.arrow.down"){await work.exportCrash()}.disabled(work.selectedReport==nil)}.padding(.horizontal,24).padding(.top,18);note("В просмотре только технические поля. Полный выбранный отчет может содержать личные сведения и сохраняется лишь по отдельной команде. Отчеты с iPhone не удаляются.").padding(.horizontal,24)
            HSplitView{List(work.reports){report in Button(report.name){Task{await work.readReport(report)}}.buttonStyle(.plain).disabled(blocked)}.frame(minWidth:240);ScrollView{VStack(alignment:.leading,spacing:16){ForEach(work.crashSummary.keys.sorted(),id:\.self){key in LabeledContent(key,value:work.crashSummary[key]!)}}.padding(20).textSelection(.enabled)}.frame(minWidth:260)}
        }
    }
    private var documents:some View {
        VStack(alignment:.leading,spacing:14){HStack{action("Найти приложения с обменом файлами","folder"){await work.readSharingApps()};Picker(L("Приложение"),selection:$work.sharingBundle){Text(L("Выбрать…")).tag("");ForEach(work.sharingApps){Text($0.name).tag($0.bundle)}}.disabled(blocked)}
            note("Доступны только Documents приложений с поддержкой File Sharing. При передаче на iPhone создается новая папка AppRestore-Import; существующие файлы не заменяются.")
            HStack{TextField(L("Папка в приложении"),text:$work.documentPath).textFieldStyle(.roundedBorder);action("Открыть папку","arrow.right"){await work.readFiles()}.disabled(work.sharingBundle.isEmpty);action("На Mac…","square.and.arrow.down"){await work.exportDocuments()}.disabled(work.selectedFiles.isEmpty);action("На iPhone…","square.and.arrow.up"){await work.uploadDocuments()}.disabled(work.sharingBundle.isEmpty)}
            List(selection:$work.selectedFiles){ForEach(work.files){file in HStack{Image(systemName:file.directory ? "folder":"doc");Text(file.name);Spacer();if file.directory{Button(L("Открыть")){Task{await work.readFiles(path:file.id)}}.disabled(blocked)}else{Text(humanSize(file.bytes)).foregroundStyle(.secondary);if !file.exportable{Image(systemName:"lock")}}}.tag(file.id)}}
            DocumentDropArea(work:work)
        }.padding(24).onChange(of:work.sharingBundle){_,_ in work.files=[];work.selectedFiles=[];work.documentPath="/"}
    }
    private var backupCredentials:some View {VStack(alignment:.leading,spacing:10){HStack{action("Выбрать копию…","folder"){await work.chooseBackup()};if !work.backupDirectory.isEmpty{Text(URL(fileURLWithPath:work.backupDirectory).lastPathComponent).font(.caption).textSelection(.enabled)}};SecureField(L("Пароль резервной копии — только в памяти"),text:$work.backupPassword).textFieldStyle(.roundedBorder).frame(minWidth:260,maxWidth:480,minHeight:26);if let summary=work.backupSummary{Text(summary.name+" · iOS "+summary.ios+" · "+summary.date+" · "+L(summary.encrypted ? "Зашифровано":"Без шифрования")).font(.caption).foregroundStyle(.secondary)}}}
    private var backups:some View {
        VStack(alignment:.leading,spacing:16){GroupBox(L("Новая частная копия")){VStack(alignment:.leading,spacing:12){note("Полная зашифрованная копия iPhone в выбранную папку. App Store приложения в нее не входят; IPA хранятся отдельно. Старые копии не заменяются.");SecureField(L("Пароль резервной копии — только в памяти"),text:$work.backupPassword).textFieldStyle(.roundedBorder).frame(minWidth:260,maxWidth:480,minHeight:26);HStack{Picker(L("Лимит копии"),selection:$work.backupLimitGiB){ForEach([16,32,64,128,256,512,1024],id:\.self){Text(String($0)+" GB").tag($0)}}.frame(width:230);action("Создать копию…","externaldrive.badge.plus"){await work.createBackup()}.disabled(work.backupPassword.isEmpty)};Toggle(L("Разрешаю включить шифрование резервных копий на iPhone, если оно выключено"),isOn:$work.enableEncryption)}.padding(10).frame(minWidth:540,maxWidth:.infinity,alignment:.leading)}
            backupCredentials
            HStack{TextField(L("Поиск пути в копии"),text:$work.backupSearch).textFieldStyle(.roundedBorder).frame(minWidth:120,minHeight:26);action("Прочитать каталог копии","list.bullet"){await work.readBackupFiles()}.disabled(work.backupDirectory.isEmpty);action("Экспорт выбранных файлов…","square.and.arrow.down"){await work.exportArchive(filesOnly:true)}.disabled(work.selectedBackupFiles.isEmpty)}
            List(selection:$work.selectedBackupFiles){ForEach(work.backupFiles){file in VStack(alignment:.leading,spacing:4){HStack{Text(file.name);Spacer();if !file.exportable{Image(systemName:"lock")}};Text(file.domain+" · "+humanSize(file.bytes)).font(.caption).foregroundStyle(.secondary)}.tag(file.id)}}
            if work.backupHasMore{action("Показать еще","ellipsis"){await work.readBackupFiles(append:true)}}
        }.padding(24)
    }
    private var archive:some View {
        VStack(alignment:.leading,spacing:14){backupCredentials
            VStack(alignment:.leading,spacing:8){Text(L("Набор данных")).font(.caption).foregroundStyle(.secondary)
                HStack{Picker(L("Набор данных"),selection:$work.archiveKind){Text("SMS / iMessage").tag("sms");Text("WhatsApp").tag("whatsapp");Text(L("Контакты")).tag("contacts")}.labelsHidden().pickerStyle(.segmented);action("Прочитать выбранный набор","lock.open"){await work.readArchive()}.disabled(work.backupDirectory.isEmpty)}
            }
            note("Поддерживаются совместимые базы локальной копии. iCloud-only данные и отсутствующие вложения могут быть недоступны. Неподдержанный формат отмечается или останавливает экспорт.")
            HStack{Picker(L("Формат"),selection:$work.exportFormat){if work.archiveKind=="contacts"{Text("vCard (VCF)").tag("vcf");Text("CSV").tag("csv")}else{Text("HTML").tag("html");Text("PDF + TXT").tag("pdf");Text("TXT").tag("txt");Text("CSV").tag("csv")}}.frame(width:220);if work.archiveKind != "contacts"{Toggle(L("Доступные вложения"),isOn:$work.includeAttachments)};Spacer();action("Экспорт выбранного…","square.and.arrow.down"){await work.exportArchive()}.disabled(work.archiveKind=="contacts" ? work.selectedContacts.isEmpty:work.selectedChats.isEmpty)}
            if work.archiveKind=="contacts"{List(selection:$work.selectedContacts){ForEach(work.contacts){contact in VStack(alignment:.leading){Text(contact.name).font(.headline);Text(contact.values.map(\.value).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}.tag(contact.id)}}}
            else{HSplitView{List(selection:$work.selectedChats){ForEach(work.chats){chat in HStack{VStack(alignment:.leading){Text(chat.name).font(.headline);Text(String(chat.count)).font(.caption).foregroundStyle(.secondary)};Spacer();Button(L("Просмотр")){Task{await work.readMessages(chat)}}.disabled(blocked)}.tag(chat.id)}}.frame(minWidth:220);List(work.messages){message in VStack(alignment:.leading,spacing:5){Text(message.date+" · "+L(message.from_me ? "От меня":"Входящее")).font(.caption).foregroundStyle(.secondary);Text(message.text).textSelection(.enabled)}}.frame(minWidth:280)}}
        }.padding(24).onChange(of:work.archiveKind){_,kind in work.chats=[];work.messages=[];work.contacts=[];work.selectedChats=[];work.selectedContacts=[];work.exportFormat=kind=="contacts" ? "vcf":"html"}
    }
    private var profiles:some View {VStack(alignment:.leading,spacing:16){action("Прочитать список профилей","checkmark.shield"){await work.readProfiles()};note("Только названия видимых профилей. Сертификаты, ключи и содержимое профилей не читаются. Удаление профилей отключено.");List(work.profiles){profile in VStack(alignment:.leading){Text(profile.name).font(.headline);Text(profile.organization).font(.caption).foregroundStyle(.secondary)}}}.padding(24)}
}

struct PhotoWorkspace:View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject var work:DeviceWorkspace
    @ObservedObject var photos:PhonePhotoLibrary
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Button(L("Прочитать медиатеку")){Task{model.busy=true;defer{model.busy=false};await photos.connect(udid:model.target);work.status = photos.phase=="ready" || photos.phase=="empty" ? "Медиатека прочитана локально по USB.":"Чтение медиа не завершено. См. сообщение в разделе."}}.disabled(model.busy || photos.busy || model.preview || work.device?.paired != true)
                Button(L("Продолжить копирование…")){photos.prepareResume()}.disabled(model.busy || photos.busy || photos.assets.isEmpty)
                Spacer();Button(L("Экспорт оригиналов…")){photos.prepareExport()}.disabled(model.busy || photos.busy || photos.selected.isEmpty)}
            HStack{TextField(L("Поиск медиа по имени"),text:$photos.search).textFieldStyle(.roundedBorder).frame(minWidth:120,minHeight:26)
                Picker(L("Тип"),selection:$photos.kind){Text(L("Все медиа")).tag("all");Text(L("Фото")).tag("image");Text(L("Видео")).tag("video");Text(L("Другие")).tag("other")}.frame(width:180)
                Button(L("Выбрать показанные")){photos.selectVisible()};Button(L("Снять выбор")){photos.selected=[]}}.disabled(photos.busy)
            HStack{Toggle(L("Период"),isOn:$photos.filterDates);DatePicker(L("С"),selection:$photos.since,displayedComponents:.date).frame(width:180).disabled(!photos.filterDates);DatePicker(L("По"),selection:$photos.until,displayedComponents:.date).frame(width:180).disabled(!photos.filterDates);Spacer();Text(LF("Выбрано: %@",String(photos.selected.count))).font(.caption)}.disabled(photos.busy)
            Text(L("Читаем локальные файлы DCIM напрямую по USB. Скриншоты PNG поддерживаются. Оригиналы только в iCloud и альбомы «С Mac» могут отсутствовать в этом списке.")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("Дополнительно создать JPEG-копии HEIC; оригиналы оставить"),isOn:$photos.jpegCopies).disabled(photos.busy)
            Text(L("Оригиналы сохраняются без перекодирования, Live Photo и сопутствующие файлы — рядом. JPEG — отдельное преобразование с потерями; HDR может измениться.")).font(.caption).foregroundStyle(.secondary)
            if photos.assets.isEmpty && !photos.busy {Text(L(photos.phase=="empty" ? "В доступном DCIM нет файлов":"Нажми «Прочитать медиатеку». iPhone должен быть разблокирован.")).foregroundStyle(.secondary)}
            ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:160))],spacing:14){ForEach(photos.visible){asset in Button{if photos.selected.contains(asset.id){photos.selected.remove(asset.id)}else{photos.selected.insert(asset.id)}}label:{VStack(alignment:.leading,spacing:8){ZStack{RoundedRectangle(cornerRadius:12).fill(.quaternary);if let image=photos.thumbnails[asset.id]{Image(nsImage:image).resizable().scaledToFit()}else{Image(systemName:asset.source.kind=="video" ? "play.rectangle":"photo")}}.frame(height:120);Text(asset.name).lineLimit(1);if let date=asset.source.created{Text(date.formatted(date:.abbreviated,time:.omitted)).font(.caption2).foregroundStyle(.secondary)};Text(humanSize(asset.bytes)).font(.caption).foregroundStyle(.secondary)}.padding(12).background(Palette.card,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(photos.selected.contains(asset.id) ? Color.accentColor:Color.clear,lineWidth:2))}.buttonStyle(.plain).disabled(photos.busy || asset.bytes==0).onAppear{photos.thumbnail(asset)}}}}
            PhoneAlbumSyncView(work:work,sync:work.albumSync)
            HStack{Text(photos.status.text).font(.caption).foregroundStyle(.secondary).lineLimit(3);Spacer();if photos.busy{Group{if photos.loading{ProgressView().controlSize(.small)}else{ProgressView(value:photos.fraction).frame(width:90)}};Button(L("Отменить")){photos.cancel()}};if !photos.lastDirectory.isEmpty{Button(L("Показать в Finder")){NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:photos.lastDirectory)}}}
        }.padding(24)
        .confirmationDialog(L("Экспортировать оригиналы?"),isPresented:$photos.showConfirmation,titleVisibility:.visible){Button(L("Экспортировать")){Task{model.busy=true;defer{model.busy=false};await photos.export()}};Button(L("Отменить"),role:.cancel){photos.discard()}}message:{Text(photos.confirmation)}
    }
}
