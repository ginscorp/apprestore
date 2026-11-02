import SwiftUI
import AppKit
import Combine
import Darwin

struct AppMark: View {
    var size: CGFloat = 42
    var body: some View {
        ZStack { RoundedRectangle(cornerRadius:size*0.28).fill(LinearGradient(colors:[Color(red:0.39,green:0.37,blue:0.96),Color(red:0.17,green:0.69,blue:0.85)],startPoint:.topLeading,endPoint:.bottomTrailing))
            Image(systemName:"arrow.down.app").font(.system(size:size*0.51,weight:.semibold)).foregroundStyle(.white)
        }.frame(width:size,height:size)
    }
}
@MainActor final class ArtworkState: ObservableObject { @Published var image:NSImage? }
struct AppArtwork: View {
    let app: CatalogApp
    @ObservedObject var media: CatalogMedia
    var size: CGFloat = 64
    @StateObject private var artwork = ArtworkState()
    var body: some View {
        Group {
            if let image = artwork.image { Image(nsImage:image).resizable().interpolation(.high).scaledToFill() }
            else { ZStack { LinearGradient(colors:[Palette.accent.opacity(0.85),Color.cyan.opacity(0.8)],startPoint:.topLeading,endPoint:.bottomTrailing);Text(String(app.name.prefix(1))).font(.system(size:size*0.44,weight:.bold)).foregroundStyle(.white) } }
        }.task(id:"\(app.id):\(media.imageRevision(app.id))"){artwork.image=await media.loadImage(app.id)}.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:size*0.23)).overlay(RoundedRectangle(cornerRadius:size*0.23).stroke(.black.opacity(0.06),lineWidth:1))
    }
}
final class CardInteraction: ObservableObject {@Published var hovered=false}
struct CatalogTile: View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @StateObject private var interaction=CardInteraction()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: CatalogApp
    @ObservedObject var model: AppModel
    @ObservedObject var media: CatalogMedia
    var body: some View {
        Button { if model.selected != app.id { model.selected = app.id } } label: {
            VStack(alignment:.leading,spacing:13) {
                HStack(alignment:.top) {AppArtwork(app:app,media:media,size:72).shadow(color:.black.opacity(0.12),radius:5,y:3);Spacer();Image(systemName:model.selected == app.id ? "checkmark.circle.fill" : "arrow.down.circle").font(.system(size:22)).foregroundStyle(model.selected == app.id || interaction.hovered ? Palette.accent : Color.gray.opacity(0.4))}
                Text(app.name).font(.system(size:14,weight:.semibold)).foregroundStyle(Palette.ink).lineLimit(2).frame(height:36,alignment:.topLeading)
                Text(L(app.category.isEmpty ? "Приложение" : app.category)).font(.system(size:11)).foregroundStyle(Palette.muted).lineLimit(1).frame(height:14,alignment:.leading)
                Group {
                    if case .missing = media.listingState(app.id) {Label(L("Нет карточки Apple · RU"),systemImage:"archivebox").font(.system(size:9)).foregroundStyle(Palette.muted).lineLimit(1)}
                    else {Color.clear}
                }.frame(height:13,alignment:.leading)
                HStack { Text("ID \(String(app.id))").font(.system(size:10,weight:.medium,design:.monospaced));Spacer();if let version = media.info(app.id)?.publicVersion, !version.isEmpty {Text("v\(version)").font(.system(size:10,weight:.medium)).lineLimit(1)} }.foregroundStyle(Palette.muted).frame(height:12)
            }.padding(19).frame(maxWidth:.infinity,alignment:.leading).frame(height:238,alignment:.topLeading)
                .background(Palette.card,in:RoundedRectangle(cornerRadius:17))
                .overlay(RoundedRectangle(cornerRadius:17).fill(Palette.accent.opacity(interaction.hovered ? 0.055 : 0)))
                .overlay(RoundedRectangle(cornerRadius:17).strokeBorder(LinearGradient(colors:[.white.opacity(colorScheme == .dark ? 0.14 : 0.9),Palette.border.opacity(0.25)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1))
                .overlay(RoundedRectangle(cornerRadius:17).strokeBorder(Palette.accent.opacity(model.selected == app.id ? 1 : interaction.hovered ? 0.55 : 0),lineWidth:model.selected == app.id ? 2 : 1))
                .shadow(color:.black.opacity(colorScheme == .dark ? 0.2 : 0.06),radius:interaction.hovered ? 14 : 8,x:0,y:interaction.hovered ? 7 : 3)
                .contentShape(RoundedRectangle(cornerRadius:17))
        }.buttonStyle(.plain).accessibilityIdentifier("app-card-\(app.id)").accessibilityLabel("\(app.name), App ID \(app.id)").catalogProbe("tile-\(app.id)")
        .zIndex(interaction.hovered ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:interaction.hovered)
        .onHover{interaction.hovered=$0}
    }
}

@MainActor final class MainSession:ObservableObject {
    let model:AppModel
    let workspace:DeviceWorkspace
    init(){let value=AppModel(preview:PublicEdition.preview);model=value;workspace=DeviceWorkspace(app:value)}
}
struct MainView:View {
    // Defer creation to StateObject storage. An eager local AppModel in the
    // view initializer creates discarded helpers every time scenes update.
    @StateObject private var session=MainSession()
    var body:some View{MainContent(model:session.model,workspace:session.workspace)}
}
struct MainContent: View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject private var profiles = LocalAccounts.shared
    @ObservedObject var model:AppModel
    @ObservedObject var workspace:DeviceWorkspace
    @StateObject private var fields = InputFields()
    var body: some View {
        NavigationSplitView {
            sidebar.catalogProbe("sidebar").navigationSplitViewColumnWidth(min:200,ideal:225,max:280)
        } detail: {
            VStack(spacing:0) {
                if workspace.tab == .catalog {HStack(spacing:0) {catalog.catalogProbe("catalog").frame(minWidth:0,maxWidth:.infinity);Divider();detail.catalogProbe("detail").frame(width:325)};Divider();statusbar}
                else {WorkspaceContent(work:workspace,model:model)}
            }
            .navigationTitle("AppRestore")
            .toolbar {
                ToolbarItem {Button{workspace.clearPrivate()}label:{Label(L("Закрыть личные данные"),systemImage:"lock")}.disabled(model.busy || model.preview)}
                ToolbarItem {
                    Picker(L("Устройство"),selection:$model.target){Text(L("Выбери iPhone")).tag("");ForEach(model.devices){Text($0.name+" · iOS "+$0.ios).tag($0.udid)}}.frame(maxWidth:250).disabled(model.busy || model.preview)
                }
                ToolbarItem {
                    Button {Task{await model.refresh()}} label:{Label(L("Обновить каталоги"),systemImage:"arrow.clockwise")}
                        .disabled(model.busy || !model.account.isEmpty || model.preview)
                        .help(L("Обновить каталоги до входа в Apple ID"))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Palette.canvas).foregroundStyle(Palette.ink).frame(minWidth:1000,minHeight:700)
        .environment(\.locale,interface.locale)
        .onAppear { interface.applyAppearance() }
        .task { await model.startup(); await workspace.battery.start(); if model.preview && ProcessInfo.processInfo.environment["APPRESTORE_AUTH_PREVIEW"] == "1" {fields.email = "demo@example.test";fields.showSignIn = true} }
        .onChange(of:model.selected){_,_ in if model.licenseChecked != nil {model.licenseChecked = nil};if !model.preview {Task{if let app = model.selectedApp {await model.media.warm([app])}}}}
        .onChange(of:model.sort){_,value in UserDefaults.standard.set(value.rawValue,forKey:"catalogSort")}
        .onChange(of:model.account){_,value in if !value.isEmpty {fields.showSignIn = false}else{workspace.clearPrivate()}}
        .onChange(of:model.target){_,_ in workspace.clearPrivate();workspace.battery.targetChanged()}
        .onReceive(model.media.objectWillChange){_ in model.objectWillChange.send()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in model.engine.stop();model.usb.cancel();workspace.photos.cancel();workspace.albumSync.cancel();workspace.battery.stop()}
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didMountNotification)){_ in if !model.preview {Task{await model.media.backupNow()}}}
        .onChange(of:fields.showSignIn){_,shown in model.diagnosticCollectionPaused=shown}
        .sheet(isPresented:$fields.showSignIn){signIn}
        .sheet(isPresented:$fields.showCache){CachePanel(media:model.media,model:model)}
        .sheet(isPresented:$model.showTransfer){transfer}
        .confirmationDialog(L("Получить бесплатное приложение на этот Apple ID?"),isPresented:$model.confirmAcquire,titleVisibility:.visible){Button(L("Получить бесплатно")){Task{await model.acquire()}}}message:{Text(L("Будет изменен список покупок текущего аккаунта. Платные приложения и подписки отключены."))}
        .confirmationDialog(L("Установить на выбранный iPhone?"),isPresented:$model.confirmInstall,titleVisibility:.visible){Button(L("Установить")){Task{await model.install()}}}message:{Text(LF("%@ → %@. Если приложение уже установлено, его версия может измениться.",model.selectedApp?.name ?? L("Приложение"),(model.devices.first(where:{$0.udid == model.target})?.name ?? "iPhone")+" · iOS "+(model.compatibility?.ios ?? "")+" · min "+(model.compatibility?.minimum_ios ?? "")))}
        .reportCatalogLayout()
    }
    private func workspaceRow(_ tab:WorkspaceTab)->some View {
        Button{workspace.tab=tab}label:{Label(tab.title,systemImage:tab.symbol).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
            .listRowBackground(workspace.tab==tab ? Color.accentColor.opacity(0.18):Color.clear)
            .accessibilityIdentifier("workspace-"+tab.rawValue)
    }
    private var sidebar: some View {
        List {
            Section(L("УСТРОЙСТВО")){ForEach([WorkspaceTab.overview,.battery,.installed,.home,.diagnostics,.profiles,.tools]){tab in workspaceRow(tab)}}
            Section(L("МЕДИАТЕКА")){ForEach([WorkspaceTab.catalog,.queue,.photos,.documents]){tab in workspaceRow(tab)}}
            Section(L("ЛИЧНЫЙ АРХИВ")){ForEach([WorkspaceTab.backups,.archive]){tab in workspaceRow(tab)}}
            Section {
                Button {fields.showCache=true} label:{Label(L("Кеш и резервная копия"),systemImage:"internaldrive")}.buttonStyle(.plain).accessibilityIdentifier("cache-button")
                SettingsLink {Label(L("Настройки"),systemImage:"gearshape")}.buttonStyle(.plain).accessibilityIdentifier("settings-button")
            }
        }.listStyle(.sidebar).disabled(workspace.busy || workspace.photos.busy).clipped()
        .safeAreaInset(edge:.bottom,spacing:0) {
            VStack(alignment:.leading,spacing:15) {
                Divider()
                HStack(spacing:9) {
                    Image(systemName:"iphone").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:3) {
                        Text(L(model.preview ? "Демо-устройство · без подключения" : model.devices.isEmpty ? "iPhone не выбран" : "iPhone подключен")).font(.callout)
                        Text(model.devices.first(where:{$0.udid==model.target})?.name ?? L("Подключи устройство по кабелю")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                    Button {Task{await model.scanDevices()}} label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.borderless).help(L("Обновить устройства")).disabled(model.busy || model.preview)
                }
                Button {fields.showSignIn=true} label:{
                    Label {
                        VStack(alignment:.leading,spacing:3) {
                            Text(L(model.account.isEmpty ? "Войти в Apple ID" : "Сеанс открыт")).font(.callout)
                            Text(L(model.account.isEmpty ? "Для проверки и загрузки" : "Доступ только в этом сеансе")).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon:{Image(systemName:"person.crop.circle").font(.title2)}
                }.buttonStyle(.plain).disabled(model.preview).accessibilityIdentifier("signin-button")
                Text(model.preview ? L("ПРЕДПРОСМОТР") : "AppRestore "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")).font(.caption2).foregroundStyle(.tertiary)
            }.padding(14)
        }
    }
    private var catalog: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment:.leading,spacing:22){
                if model.search.isEmpty { hero.catalogProbe("hero") }
                if geometry.size.width < 800 {
                    Picker(L("Категория"),selection:$model.section){ForEach(["Все приложения","Банки","Соцсети и мессенджеры","Сервисы"],id:\.self){Text(L($0)).tag($0)}}.pickerStyle(.menu).labelsHidden().frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("catalog-category").catalogProbe("category")
                } else {
                    Picker(L("Категория"),selection:$model.section){ForEach(["Все приложения","Банки","Соцсети и мессенджеры","Сервисы"],id:\.self){Text(L($0)).tag($0)}}.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("catalog-category").catalogProbe("category")
                }
                HStack(alignment:.center){VStack(alignment:.leading,spacing:4){Text(L(model.search.isEmpty ? model.section : "Результаты поиска")).font(.system(size:18,weight:.bold));Text(LF("%@ приложений",String(model.filtered.count))).font(.system(size:11)).foregroundStyle(Palette.muted)};Spacer();Picker(L("Сортировка"),selection:$model.sort){ForEach(CatalogSort.allCases){Text($0.title).tag($0)}}.labelsHidden().frame(width:210).id(interface.language).accessibilityIdentifier("sort-control")}
                if model.filtered.isEmpty {VStack(spacing:14){Image(systemName:"magnifyingglass").font(.system(size:35));Text(L("Ничего не найдено")).font(.headline);Text(L("Попробуй другое название или App ID")).font(.caption)}.foregroundStyle(Palette.muted).frame(maxWidth:.infinity,minHeight:250)}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:166,maximum:240),spacing:15)],spacing:15){ForEach(model.filtered){app in CatalogTile(app:app,model:model,media:model.media)}}.catalogProbe("grid")
                HStack { TextField(L("Добавить известный App ID"),text:$fields.manualID).textFieldStyle(.roundedBorder).frame(maxWidth:240);Button(L("Добавить")){addManualID()}.disabled(Int64(fields.manualID) == nil);Spacer() }.padding(.top,6)
                Text(L("Названия и варианты предоставлены сообществом. Больший App ID не означает более свежую версию; право на загрузку проверяет Apple.")).font(.system(size:10)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
            }.padding(25).frame(width:geometry.size.width,alignment:.topLeading)
        }
        }.searchable(text:$model.search,placement:.toolbar,prompt:Text(L("Название или App ID")))
    }
    private var hero: some View {
        HStack(spacing:15) {
            AppMark(size:48)
            VStack(alignment:.leading,spacing:5) {
                Text(L("Восстановление приложений")).font(.title2.weight(.semibold))
                Text(L("Найди приложение. Верни его на iPhone.")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical,8)
    }
    private var detail: some View {
        ScrollView {if let app = model.selectedApp {VStack(alignment:.leading,spacing:20){
            HStack {Text(L("КАРТОЧКА ПРИЛОЖЕНИЯ")).font(.system(size:9,weight:.bold)).tracking(1.2).foregroundStyle(Palette.muted);Spacer();Button{model.selected = nil}label:{Image(systemName:"xmark").font(.system(size:11,weight:.bold))}.buttonStyle(.plain)}
            AppArtwork(app:app,media:model.media,size:85)
            VStack(alignment:.leading,spacing:7){Text(app.name).font(.system(size:23,weight:.bold)).foregroundStyle(Palette.ink);Text(L(app.category.isEmpty ? "Приложение" : app.category)).font(.system(size:12)).foregroundStyle(Palette.muted);Text("App ID \(String(app.id))").font(.system(size:11,design:.monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)}
            versionInfo(app)
            listingInfo(app)
            if let info = model.media.info(app.id), !info.publisher.isEmpty {detailLine("Издатель",info.publisher);if !info.minimumOS.isEmpty{detailLine("Требуется iOS",LF("%@ или новее",info.minimumOS))}}
            Divider().opacity(0.4)
            workflow(app)
            Button{workspace.addToQueue(app)}label:{Label(L("В очередь восстановления"),systemImage:"text.badge.plus")}.disabled(model.busy || workspace.queue.count>=25)
            if !model.checkDiagnostic.isEmpty {DisclosureGroup(L("Диагностика запроса Apple")){Text(model.checkDiagnostic).font(.system(size:9,design:.monospaced)).textSelection(.enabled)}}
            if !model.devices.isEmpty {Picker(L("Устройство"),selection:$model.target){Text(L("Выбери iPhone")).tag("");ForEach(model.devices){Text("\($0.name) · …\($0.udid.suffix(4))").tag($0.udid)}}.font(.caption)}
            if !model.packagePath.isEmpty && model.packageApp == app.id {Label(L("Лицензия Apple подготовлена"),systemImage:"checkmark.shield.fill").font(.system(size:10,weight:.medium)).foregroundStyle(.green);if model.cacheUsed {Text(L("Пакет взят из локального кеша. Лицензия получена для текущего аккаунта.")).font(.system(size:10)).foregroundStyle(Palette.muted)}else if model.cacheStored {Text(L("Общий пакет сохранен на Mac для следующих загрузок.")).font(.system(size:10)).foregroundStyle(Palette.muted)}}
            Button(L("Добавить бесплатное приложение в покупки…")){model.confirmAcquire = true}.font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(model.account.isEmpty || model.busy || model.preview)
                .help(L("Если приложение доступно бесплатно в магазине этого Apple ID. Добавление в покупки требует отдельного подтверждения."))
            Divider().opacity(0.4)
            if app.aliases.count > 1 {Text(L("ДРУГИЕ НАЗВАНИЯ")).font(.system(size:9,weight:.bold)).tracking(1.1).foregroundStyle(Palette.muted);Text(app.aliases.filter{$0 != app.name}.joined(separator:"\n")).font(.system(size:11)).foregroundStyle(Palette.muted)}
            Text(L("ИСТОЧНИКИ")).font(.system(size:9,weight:.bold)).tracking(1.1).foregroundStyle(Palette.muted);Text(app.sources.map(L).joined(separator:" · ")).font(.system(size:10)).foregroundStyle(Palette.muted)
            Text(L("Установка не переносит покупку на другой Apple ID и не переносит данные приложения.")).font(.system(size:10)).foregroundStyle(Palette.muted)
        }.padding(23)} else {
            VStack(spacing:12){
                Image(systemName:"square.grid.2x2").font(.system(size:34)).foregroundStyle(Palette.accent)
                Text(L("Выбери приложение")).font(.headline).foregroundStyle(Palette.ink)
                Text(L("Здесь появятся сведения и действия для выбранного приложения.")).font(.callout).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }.frame(maxWidth:.infinity,minHeight:280).padding(23)
        }}.background(Palette.surface)
    }
    private func detailLine(_ label:String,_ value:String)->some View{VStack(alignment:.leading,spacing:4){Text(L(label)).font(.system(size:9)).foregroundStyle(Palette.muted);Text(value).font(.system(size:11,weight:.medium)).foregroundStyle(Palette.ink)}}
    private func versionInfo(_ app:CatalogApp)->some View {
        VStack(alignment:.leading,spacing:10){
            if model.licenseChecked == app.id && !model.availableVersion.isEmpty {HStack{Label(L("Apple выдает"),systemImage:"checkmark.seal.fill").foregroundStyle(.green);Spacer();Text(model.availableVersion).bold()}.font(.system(size:11))}
            if let cached = model.media.observations(app.id).first {HStack{Text(L("Проверяли ранее")).foregroundStyle(Palette.muted);Spacer();Text(cached.version).fontWeight(.semibold)}.font(.system(size:11));Text(cached.date.formatted(.dateTime.day().month(.abbreviated).year().locale(interface.locale))).font(.system(size:9)).foregroundStyle(Palette.muted)}
            if let info = model.media.info(app.id), !info.publicVersion.isEmpty {HStack{Text(L(model.media.index.lookupPresence?[String(app.id)] == false ? "Сохраненные сведения Apple" : "Публичный каталог")).foregroundStyle(Palette.muted);Spacer();Text(info.publicVersion).fontWeight(.semibold)}.font(.system(size:11))}
            if model.media.observations(app.id).isEmpty && (model.media.info(app.id)?.publicVersion.isEmpty ?? true){Text(L("Версия появится после проверки Apple")).font(.system(size:11)).foregroundStyle(Palette.muted)}
            Text(L("Сохраненная версия — справочная. Доступ текущего Apple ID проверяется заново.")).font(.system(size:9)).foregroundStyle(Palette.muted)
        }.padding(13).frame(maxWidth:.infinity,alignment:.leading).background(Palette.canvas,in:RoundedRectangle(cornerRadius:13))
    }
    private func listingInfo(_ app:CatalogApp)->some View {
        VStack(alignment:.leading,spacing:7) {
            switch model.media.listingState(app.id) {
            case .unknown:
                Text(L("Публичная карточка еще не проверена")).font(.system(size:10)).foregroundStyle(Palette.muted)
            case .listed(let date):
                Label(L("Есть в публичном каталоге RU"),systemImage:"globe").font(.system(size:10)).foregroundStyle(Palette.muted)
                Text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(interface.locale))).font(.system(size:9)).foregroundStyle(Palette.muted)
            case .missing(let date):
                Label(L("Нет в публичном каталоге RU"),systemImage:"archivebox").font(.system(size:11,weight:.medium)).foregroundStyle(.orange)
                Text(L("Apple не вернула карточку в публичном поиске этого региона. Сохраненные сведения и иконка остаются. Возможность повторной загрузки проверяется отдельно для текущего Apple ID.")).font(.system(size:10)).foregroundStyle(Palette.muted)
                Text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(interface.locale))).font(.system(size:9)).foregroundStyle(Palette.muted)
            }
            Button(L("Обновить сведения")) { Task { await model.media.warm([app],force:true) } }
                .font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(model.media.preloading || model.preview)
        }
    }
    private func workflow(_ app:CatalogApp)->some View {
        VStack(alignment:.leading,spacing:11){
            HStack(spacing:7){stage("1",model.licenseChecked == app.id);Text(L("Доступ"));Image(systemName:"chevron.right");stage("2",model.packageApp == app.id);Text(L("Пакет"));Image(systemName:"chevron.right");stage("3",false);Text("iPhone")}.font(.system(size:9)).foregroundStyle(Palette.muted)
            Button { primaryAction(app) } label:{HStack{if model.busy{ProgressView().controlSize(.small)}else{Image(systemName:primarySymbol(app))};Text(L(primaryTitle(app))).fontWeight(.semibold);Spacer()}.frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.preview).accessibilityIdentifier("primary-action")
            if !model.account.isEmpty && (model.licenseChecked == app.id || model.packageApp == app.id) {Button(L("Проверить доступность еще раз")){Task{await model.check()}}.font(.system(size:10)).foregroundStyle(Palette.accent).buttonStyle(.plain).disabled(model.busy || model.preview)}
            if model.packageApp == app.id {Button(L("Загрузить пакет заново")){Task{await model.download()}}.font(.system(size:10)).foregroundStyle(Palette.accent).buttonStyle(.plain).disabled(model.busy || model.preview)}
        }
    }
    private func stage(_ n:String,_ done:Bool)->some View{Text(done ? "✓" : n).font(.system(size:9,weight:.bold)).frame(width:19,height:19).background(done ? Color.green.opacity(0.13) : Palette.canvas,in:Circle()).foregroundStyle(done ? .green : Palette.muted)}
    private func primaryTitle(_ app:CatalogApp)->String{if model.account.isEmpty{return "Войти и проверить"};if model.packageApp == app.id && !model.packagePath.isEmpty{return model.target.isEmpty ? "Выбрать iPhone" : "Установить на iPhone"};return model.licenseChecked == app.id ? "Загрузить с Apple" : "Проверить доступность"}
    private func primarySymbol(_ app:CatalogApp)->String{model.packageApp == app.id ? "iphone.and.arrow.forward" : "arrow.down.circle"}
    private func primaryAction(_ app:CatalogApp){if model.account.isEmpty{fields.showSignIn = true}else if model.packageApp == app.id && !model.packagePath.isEmpty{if model.target.isEmpty{Task{await model.scanDevices()}}else{Task{await model.prepareInstall()}}}else if model.licenseChecked == app.id{Task{await model.download()}}else{Task{await model.check()}}}
    private var statusbar: some View {HStack(spacing:10){if model.busy{ProgressView().controlSize(.small)}else{Image(systemName:"info.circle").foregroundStyle(Palette.accent)};Text(model.message.text).font(.system(size:10)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(3);Spacer()}.padding(.horizontal,24).padding(.vertical,13).frame(maxWidth:.infinity,alignment:.leading).background(Palette.surface.opacity(0.85))}
    private var signIn: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {AppMark(size:45);Spacer();Button(L("Закрыть")) {
                fields.showSignIn=false;fields.password="";fields.code="";model.needsCode=false
            }.buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(model.busy)}
            Text(L(model.account.isEmpty ? "Твой Apple ID" : "Сеанс App Store")).font(.system(size:25,weight:.bold))
            if model.account.isEmpty {
                Text(L(model.needsCode ? "Apple запросила код подтверждения. Пароль повторно вводить не нужно." : "Войди один раз и восстанавливай несколько приложений подряд.")).font(.system(size:12)).foregroundStyle(Palette.muted)
                Picker(L("Режим входа"),selection:$fields.accountMode) {ForEach(AccountMode.allCases){Text(L($0 == .guest ? "Гостевой аккаунт" : "Личный аккаунт")).tag($0)}}.pickerStyle(.segmented).disabled(model.busy || model.needsCode).id(interface.language)
                if fields.accountMode == .personal && !profiles.accounts.isEmpty {
                    Picker(L("Сохраненный Apple ID"),selection:$fields.savedAccountID) {
                        Text(L("Ввести другой Apple ID")).tag(Optional<UUID>.none)
                        ForEach(profiles.accounts){Text($0.appleID).tag(Optional($0.id))}
                    }.disabled(model.busy || model.needsCode || fields.vaultBusy)
                    .onChange(of:fields.savedAccountID){_,value in
                        fields.password="";fields.code="";fields.savePassword=false
                        if let value,let account=profiles.accounts.first(where:{$0.id==value}) {fields.email=account.appleID}
                    }
                    if let account=profiles.accounts.first(where:{$0.id==fields.savedAccountID}),account.passwordSaved {
                        Button(L("Заполнить пароль через macOS")) {Task{
                            fields.vaultBusy=true;defer{fields.vaultBusy=false}
                            do{fields.password=try await PersonalPasswordVault.load(account:account.appleID,personalConsent:fields.accountMode == .personal)}
                            catch{fields.vaultMessage="Связка ключей не выдала пароль. Можно ввести его вручную."}
                        }}.disabled(!PersonalPasswordVault.supported || !interface.allowPasswordSaving || model.busy || fields.vaultBusy)
                    }
                }
                TextField("Apple ID",text:$fields.email).textFieldStyle(.roundedBorder).foregroundStyle(Palette.ink).disabled(model.busy || model.needsCode)
                SecureField(L("Пароль"),text:$fields.password).textFieldStyle(.roundedBorder).disabled(model.busy || model.needsCode)
                if model.needsCode {SecureField(L("Код Apple"),text:$fields.code).textFieldStyle(.roundedBorder).disabled(model.busy)}
                if fields.accountMode == .personal {
                    Toggle(L("Запомнить этот личный Apple ID без пароля"),isOn:$fields.saveAccountName).font(.caption).disabled(model.busy || model.needsCode)
                    if interface.allowPasswordSaving && PersonalPasswordVault.supported {
                        Toggle(L("Сохранить пароль в Связке ключей этого Mac"),isOn:$fields.savePassword).font(.caption).disabled(model.busy || model.needsCode)
                    }
                }
                Text(L(fields.savePassword && fields.accountMode == .personal ? "После успешного входа пароль будет сохранен только в защищенной Связке ключей этого Mac." : "Пароль остается только в памяти этого окна до входа или закрытия. На диск он не сохраняется.")).font(.system(size:10)).foregroundStyle(Palette.muted)
                if !fields.vaultMessage.isEmpty {Text(fields.vaultMessage.text).font(.caption).foregroundStyle(.secondary)}
                if model.preview {Text(L("Просмотр формы: соединение с Apple отключено.")).font(.caption).foregroundStyle(Palette.muted)}
                HStack {
                    Button(L(model.needsCode ? "Подтвердить код" : "Войти")) {
                        let email=fields.email.trimmingCharacters(in:.whitespacesAndNewlines)
                        let password=fields.password,code=fields.code
                        let rememberName=fields.accountMode == .personal && fields.saveAccountName
                        let rememberPassword=fields.accountMode == .personal && fields.savePassword && interface.allowPasswordSaving && PersonalPasswordVault.supported
                        Task {
                            await model.login(email:email,password:password,code:code)
                            fields.code=""
                            if !model.account.isEmpty {
                                fields.password=""
                                do {
                                    if rememberPassword {try await PersonalPasswordVault.save(account:email,password:password,personalConsent:true)}
                                    if rememberName || rememberPassword {try profiles.saveName(email,passwordSaved:rememberPassword,personalConsent:true)}
                                } catch {model.message="Вход выполнен. Сохранить личный аккаунт не удалось; пароль в файл не записан."}
                            }
                        }
                    }.buttonStyle(.borderedProminent).tint(Palette.hero)
                    .disabled(model.preview || model.busy || fields.vaultBusy || fields.email.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || fields.password.isEmpty || (model.needsCode && fields.code.count<4))
                    if model.busy {ProgressView().controlSize(.small)}
                    if model.needsCode {Button(L("Изменить Apple ID")) {model.needsCode=false;fields.password="";fields.code=""}.font(.caption).disabled(model.busy)}
                }
            } else {
                Text(model.account).font(.system(size:13))
                Text(L("Один активный аккаунт. После завершения сеанса временные лицензионные данные удаляются.")).font(.system(size:11)).foregroundStyle(Palette.muted)
                Button(L("Завершить сеанс")) {Task {await model.end();fields.email="";fields.password="";fields.code="";fields.showSignIn=false}}.disabled(model.busy)
            }
            Text(model.message.text).font(.system(size:11)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
        }.padding(32).frame(width:430).background(Palette.surface).foregroundStyle(Palette.ink)
        .onChange(of:fields.accountMode){_,_ in fields.email="";fields.password="";fields.code="";fields.saveAccountName=false;fields.savePassword=false;fields.savedAccountID=nil;fields.vaultMessage=""}
        .onDisappear {fields.email="";fields.password="";fields.code="";fields.accountMode = .guest;fields.saveAccountName=false;fields.savePassword=false;fields.savedAccountID=nil;fields.vaultMessage=""}
    }
    private var transfer: some View {VStack(alignment:.leading,spacing:15){Text(L("Приложения на iPhone")).font(.title2.bold());Text(L("Выбери приложение, чтобы найти его в каталоге. Читаются только названия, App ID и версии.")).font(.caption).foregroundStyle(.secondary);List(model.sourceApps){app in Button{model.chooseSource(app)}label:{HStack{VStack(alignment:.leading){Text(app.name);Text(app.bundle).font(.caption).foregroundStyle(.secondary)};Spacer();Text(app.version)}}.buttonStyle(.plain)};Button(L("Закрыть")){model.showTransfer = false}}.padding(24).frame(width:650,height:540)}
    private func addManualID(){guard let id=Int64(fields.manualID),id>0,id<=99999999999 else{return};if !model.apps.contains(where:{$0.id==id}){model.apps.append(CatalogApp(id:id,name:"App ID \(id)",aliases:[],sources:["Добавлен вручную"],category:""));model.media.setCatalog(model.apps)};model.section="Все приложения";model.search="";model.selected=id;fields.manualID=""}
}

struct CachePanel: View {
    @ObservedObject private var interface = InterfaceSettings.shared
    @ObservedObject var media: CatalogMedia
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {VStack(alignment:.leading,spacing:22){HStack{AppMark();Spacer();Button(L("Готово")){dismiss()}};Text(L("Все нужное — на твоем Mac")).font(.system(size:26,weight:.bold));Text(L("Кеш не исчезнет при обновлении или удалении файла программы. Предзагрузка сохраняет картинки и сведения; большие IPA загружаются только по твоей команде.")).font(.system(size:12)).foregroundStyle(Palette.muted);HStack(spacing:30){metric(String(media.imageCount),"иконок в каталоге");metric(String(media.index.apps.count),"карточек Apple");metric(String(media.versionCount),"сохраненных версий")};Divider();Label(localizedBackupMessage(media.backupMessage),systemImage:"externaldrive.badge.checkmark").font(.system(size:12));Text(L("На Резервная копия копируются только публичные данные библиотеки и общие пакеты. Пароли, сеансы и индивидуальные лицензии исключены.")).font(.system(size:11)).foregroundStyle(Palette.muted);HStack{Button(L(media.preloading ? "Идет предзагрузка…" : "Предзагрузить сведения и иконки")){Task{await media.prepare(model.apps)}}.buttonStyle(.borderedProminent).tint(Palette.hero).disabled(media.preloading);Button(L("Проверить резервную копию")){Task{await media.backupNow()}}.disabled(media.preloading).disabled(model.preview)};if media.preloading{ProgressView();Text(media.progress.text).font(.caption)};Text(L("Серверы Apple заново проверяют право каждого аккаунта, даже если общий пакет уже есть на Mac.")).font(.system(size:10)).foregroundStyle(Palette.muted)}.padding(30).frame(width:570).background(Palette.surface).foregroundStyle(Palette.ink)}
    private func metric(_ value:String,_ label:String)->some View{VStack(alignment:.leading,spacing:5){Text(value).font(.system(size:25,weight:.bold));Text(L(label)).font(.system(size:10)).foregroundStyle(Palette.muted)}}
}

final class AppDelegate: NSObject,NSApplicationDelegate {func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}}
#if !APPRESTORE_LAYOUT_TEST
@main struct AppRestoreApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init(){var limit=rlimit(rlim_cur:0,rlim_max:0);_ = setrlimit(RLIMIT_CORE,&limit)}
    var body: some Scene {Window("AppRestore",id:"main"){MainView()}.windowStyle(.titleBar).windowToolbarStyle(.unified).windowResizability(.contentMinSize).defaultSize(width:1280,height:830).commands{CommandGroup(replacing:.newItem){}}
        Settings {PreferencesView()}

    }
}
#endif
