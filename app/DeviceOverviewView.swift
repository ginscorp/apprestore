import SwiftUI

struct DeviceOverviewView:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    @StateObject private var state=PassportViewState()
    @ObservedObject var work:DeviceWorkspace
    @ObservedObject var monitor:BatteryMonitor
    private var blocked:Bool{work.app.busy || work.busy || work.photos.busy || monitor.busy || work.app.preview}
    var body:some View {
        ScrollView{VStack(alignment:.leading,spacing:22){
            HStack{Button{Task{await monitor.refresh(target:work.app.target)}}label:{Label(L("Обновить сведения"),systemImage:"arrow.clockwise")}.disabled(blocked).buttonStyle(.bordered);if let phone=monitor.phone,monitor.observations[phone.device.id] != nil{Button{if let observation=monitor.observations[phone.device.id]{state.presented=PassportPresentation(observation:observation)}}label:{Label(L("Технический паспорт"),systemImage:"info.circle")}};Spacer();if work.overview != nil{Label(L(work.app.preview ? "Демо-данные · USB отключен":"Подключено по USB"),systemImage:"cable.connector").font(.caption).foregroundStyle(.secondary)}}
            if let device=work.overview {
                HStack(spacing:24){
                    ZStack{RoundedRectangle(cornerRadius:26).fill(LinearGradient(colors:[.blue.opacity(0.15),.cyan.opacity(0.06)],startPoint:.topLeading,endPoint:.bottomTrailing));Image(systemName:"iphone").font(.system(size:64,weight:.ultraLight)).foregroundStyle(LinearGradient(colors:[.blue,.cyan],startPoint:.topLeading,endPoint:.bottomTrailing))}.frame(width:122,height:144)
                    VStack(alignment:.leading,spacing:10){Text(device.name).font(.system(size:28,weight:.bold));Text(device.model).font(.title3).foregroundStyle(.secondary);HStack(spacing:10){Label((device.model.hasPrefix("iPad") ? "iPadOS ":"iOS ")+device.ios,systemImage:"checkmark.seal");Text(LF("Сборка %@",device.build))}.font(.callout).foregroundStyle(.secondary);if let id=work.device?.udid{Text(L("ID устройства")+" · #"+BatteryIdentity.hash("iphone:"+id).prefix(12).uppercased()).font(.system(.caption,design:.monospaced)).foregroundStyle(.tertiary)}}
                    Spacer()
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(Palette.card,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Palette.border.opacity(0.65)))
                if let usage=DeviceStorageUsage(device.storage){storage(total:usage.total,free:usage.free,settings:DeviceSettingsStorage(device.storage))}
                else{Label(L("Свободное место пока недоступно. Обнови сведения устройства."),systemImage:"internaldrive").font(.callout).foregroundStyle(.secondary)}
                contentSummary(device)
                battery(device)
            }else{
                ContentUnavailableView(L("Готов к подключению"),systemImage:"iphone",description:Text(L("Подключи устройство и подтверди доверие. Сведения появятся автоматически."))).frame(maxWidth:.infinity,minHeight:300)
            }
        }.padding(24)}
        .sheet(item:$state.presented){presentation in DevicePassportPanel(observation:presentation.observation){state.presented=nil}}
    }
    private func contentSummary(_ device:DeviceOverview)->some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Label(L("Содержимое устройства"),systemImage:"square.grid.2x2").font(.headline);Spacer();if let stamp=device.content_count_observed_at{Text(Date(timeIntervalSince1970:Double(stamp)).formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(interface.locale))).font(.caption).foregroundStyle(.secondary)}}
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:4),spacing:12){
                contentTile(device,"SongCount","Песни","music.note",.pink)
                contentTile(device,"VideoCount","Видео","video",.purple)
                contentTile(device,"PhotoCount","Фото","photo",.orange)
                contentTile(device,"ApplicationCount","Приложения","app.badge",.blue)
            }
            Text(L("Фото и видео: видимая медиатека без скрытых, недавно удаленных и служебных записей. Оригиналы не загружаются.")).font(.caption).foregroundStyle(.secondary)
            Text(L("Если iOS не передала показатель или метаданные превышают безопасный лимит, показывается «Нет данных».")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).background(Palette.card,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Palette.border.opacity(0.65)))
    }
    private func contentTile(_ device:DeviceOverview,_ key:String,_ title:String,_ symbol:String,_ color:Color)->some View {
        let raw=device.content_counts?[key]
        let value=raw.flatMap{(0...100_000_000).contains($0) ? $0:nil}
        let source=device.content_count_sources?[key]
        return VStack(alignment:.leading,spacing:10){
            Label(L(title),systemImage:symbol).font(.caption).foregroundStyle(color)
            Text(value.map{$0.formatted(.number.locale(interface.locale))} ?? "—").font(.system(size:29,weight:.semibold,design:.rounded)).monospacedDigit()
            Text(L(value == nil ? "Нет данных":source=="synthetic_demo" ? "Демо-данные":source=="apple_photos_aggregate" ? "Медиатека iPhone":"Сведения iOS")).font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth:.infinity,minHeight:108,alignment:.leading).background(color.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
    }
    private func storage(total:Int64,free:Int64,settings:DeviceSettingsStorage?)->some View {
        let displayed=settings?.available ?? free
        return VStack(alignment:.leading,spacing:18){
            HStack{Label(L("Хранилище"),systemImage:"internaldrive").font(.headline);Spacer();Text(humanSize(total)).font(.callout).foregroundStyle(.secondary)}
            HStack(alignment:.firstTextBaseline,spacing:10){Text(humanSize(displayed)).font(.system(size:30,weight:.semibold,design:.rounded)).monospacedDigit();Text(L(settings == nil ? "свободно по USB":"доступно по расчету iOS")).foregroundStyle(.secondary)}
            GeometryReader{g in HStack(spacing:0){
                Rectangle().fill(LinearGradient(colors:[.blue,.cyan],startPoint:.leading,endPoint:.trailing)).frame(width:g.size.width*Double(total-displayed)/Double(total))
                if let settings{Rectangle().fill(.orange.opacity(0.7)).frame(width:g.size.width*Double(settings.purgeable)/Double(total))}
                Spacer(minLength:0)
            }.background(.blue.opacity(0.10)).clipShape(Capsule())}.frame(height:13)
            HStack{Label(LF("Занято %@",humanSize(total-displayed)),systemImage:"circle.fill").foregroundStyle(.blue);Spacer();Text(LF("Доступно %@ из %@",humanSize(displayed),humanSize(total))).foregroundStyle(.secondary)}.font(.caption)
            if let settings {
                HStack{Label(LF("Свободные блоки: %@",humanSize(settings.free)),systemImage:"internaldrive");Spacer();Label(LF("Может освободить iOS: %@",humanSize(settings.purgeable)),systemImage:"sparkles").foregroundStyle(.orange)}.font(.caption)
                Text(LF("Последний расчет iOS: %@",settings.date.formatted(Date.FormatStyle(date:.abbreviated,time:.standard).locale(interface.locale)))).font(.caption).foregroundStyle(.secondary)
            }else{Text(L("Для показания как в настройках iPhone открой «Об этом устройстве» во время сверки.")).font(.caption).foregroundStyle(.secondary)}
            HStack{Button{Task{await work.readStorageSettings()}}label:{Label(L("Сверить с настройками iPhone"),systemImage:"arrow.triangle.2.circlepath")}.disabled(blocked);Spacer();Text(L("Без очистки и изменений на iPhone")).font(.caption).foregroundStyle(.secondary)}
        }.padding(24).background(Palette.card,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Palette.border.opacity(0.65)))
    }
    private func battery(_ device:DeviceOverview)->some View {
        let r=device.battery_reading
        return VStack(alignment:.leading,spacing:18){HStack{Label(L("Батарея"),systemImage:"battery.100percent").font(.headline);Spacer();Button{monitor.scope="iphone";work.tab = .battery}label:{Label(L("Подробности и история"),systemImage:"arrow.up.right")}}
            if let r {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:16)],spacing:16){tile("Заряд",r.charge_percent,suffix:"%",symbol:"battery.100percent",color:.green);tile("Состояние",r.health,suffix:"%",symbol:"heart",color:(r.health ?? 100)<80 ? .orange:.green);tile("Циклы",r.cycles,suffix:"",symbol:"arrow.trianglehead.2.clockwise.rotate.90",color:.blue);tile("Температура",r.temperature_c,suffix:" °C",symbol:"thermometer.medium",color:.orange)}
            }else{Text(L("Показания батареи пока недоступны. Открой раздел «Батарея», чтобы снять отдельный замер.")).font(.callout).foregroundStyle(.secondary)}
            Text(L("Полная емкость, сведения контроллера и графики находятся в разделе «Батарея».")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).background(Palette.card,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Palette.border.opacity(0.65)))
    }
    private func tile(_ title:String,_ value:Double?,suffix:String,symbol:String,color:Color)->some View {
        VStack(alignment:.leading,spacing:12){Label(L(title),systemImage:symbol).font(.caption).foregroundStyle(color);Text(value.map{$0.formatted(.number.precision(.fractionLength(0...1)))+suffix} ?? "—").font(.system(size:27,weight:.semibold,design:.rounded)).monospacedDigit()}.padding(18).frame(maxWidth:.infinity,minHeight:102,alignment:.leading).background(color.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
    }
}
