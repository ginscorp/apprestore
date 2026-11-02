import SwiftUI
import Charts

struct BatteryWorkspace:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    @ObservedObject var monitor:BatteryMonitor
    var snapshot:BatterySnapshot?{
        if monitor.scope=="history"{guard let device=monitor.savedDevice,let last=monitor.points.last else{return nil};return BatterySnapshot(device:device,reading:last.reading,date:last.date)}
        return monitor.current
    }
    var body:some View {
        VStack(spacing:0){
            HStack{
                Picker(L("Устройство батареи"),selection:$monitor.scope){Text(L("Этот Mac")).tag("mac");Text(L("iPhone по USB")).tag("iphone");Text(L("История")).tag("history")}.pickerStyle(.segmented).labelsHidden().frame(width:420)
                Spacer();Button{Task{await monitor.refresh()}}label:{Label(L("Снять замер"),systemImage:"arrow.clockwise")}.disabled(monitor.busy || monitor.scope=="history")
            }.padding(.horizontal,24).padding(.vertical,16)
            ScrollView{VStack(alignment:.leading,spacing:20){
                if monitor.scope=="history" {
                    Picker(L("Сохраненное устройство"),selection:$monitor.historyID){Text(L("Выбери устройство")).tag("");ForEach(monitor.devices){Text($0.name+" · "+$0.model+" · #"+$0.id.prefix(12).uppercased()).tag($0.id)}}.frame(maxWidth:550)
                }
                if let snapshot {
                    deviceHeader(snapshot)
                    HStack(alignment:.top,spacing:16){gauge(title:"Заряд батареи",value:snapshot.reading.charge_percent,detail:capacity(snapshot.reading.current_mah),symbol:"bolt.fill",tint:.blue);gauge(title:"Состояние батареи",value:snapshot.reading.health,detail:L("От заводской емкости"),symbol:"heart.fill",tint:healthColor(snapshot.reading.health))}
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:220))],spacing:14){
                        metric("Емкость полной зарядки",value:capacity(snapshot.reading.full_mah),symbol:"battery.100percent",subtitle:"Full Charge Capacity")
                        metric("Заводская емкость",value:capacity(snapshot.reading.design_mah),symbol:"battery.100percent.circle",subtitle:"Design Capacity")
                        metric("Циклы зарядки",value:formatted(snapshot.reading.cycles,decimals:0),symbol:"arrow.triangle.2.circlepath")
                        metric("Температура батареи",value:snapshot.reading.temperature_c.map{formatted($0)+" °C"} ?? "—",symbol:"thermometer.medium")
                        metric("Напряжение",value:snapshot.reading.voltage_mv.map{formatted($0/1000,decimals:2)+" V"} ?? "—",symbol:"bolt.horizontal")
                        metric("Мощность батареи",value:snapshot.reading.power_w.map{formatted($0,decimals:3)+" W"} ?? "—",symbol:"waveform.path",subtitle:"Со знаком: заряд / разряд")
                    }
                    HStack{
                        Toggle(L("Сохранять историю этого устройства"),isOn:Binding(get:{monitor.tracking},set:{value in Task{await monitor.setTracking(value)}})).toggleStyle(.switch).disabled(monitor.busy)
                        Spacer();Label(L(snapshot.reading.external_power==nil ? "Источник питания не передан":snapshot.reading.external_power==true ? "Питание подключено":"Работа от батареи"),systemImage:snapshot.reading.external_power==true ? "powerplug.fill":"battery.75percent").foregroundStyle(.secondary)
                    }.padding(18).background(Palette.card,in:RoundedRectangle(cornerRadius:16))
                }else{
                    ContentUnavailableView(L(monitor.scope=="iphone" ? "Подключи и разблокируй iPhone":"Первые замеры еще не сохранены"),systemImage:monitor.scope=="iphone" ? "iphone":"chart.xyaxis.line",description:Text(L("Подключи устройство и подтверди доверие. Сведения появятся автоматически.")))
                }
                historyCard
                Text(L("Замер iPhone сохраняется при подключении, этого Mac — при запуске AppRestore. Повторный замер — по кнопке. Проверка подключения не заполняет историю; после закрытия сбор не выполняется.")).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L("Как читать показания")){
                    VStack(alignment:.leading,spacing:8){
                        Text(L("Full Charge Capacity — оценка полной емкости контроллером. Состояние = полная емкость / заводская емкость. Значение может меняться от температуры и калибровки, а у новой батареи превышать 100%. Это не прогноз срока службы и может отличаться от процента в настройках iOS."))
                        Text(L("Заряд — системный процент. Мощность рассчитана по току и напряжению самой батареи, а не по мощности зарядного устройства. Прочерк означает, что система не передала показатель."))
                        Text(L("На графике показан последний замер каждого дня. Новая батарея, если контроллер сообщает ее идентификатор, получает отдельную линию. При первом запуске история начинается с сегодняшнего замера."))
                        Text(L("Общая частная база содержит паспорт устройства и историю батареи. Apple ID и пароли в нее не входят. Экспорт CSV содержит только выбранное устройство и замеры батареи."))
                        if let field=snapshot?.reading.full_source{Text("Full Charge Capacity: "+field).font(.system(.caption,design:.monospaced))}
                    }.font(.caption).foregroundStyle(.secondary).padding(.top,8)
                }
                HStack{if monitor.busy{ProgressView().controlSize(.small)};Text(monitor.status.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            }.padding(24)}
        }
        .sheet(isPresented:$monitor.showDetails){if let snapshot{BatteryDetailPanel(snapshot:snapshot,observation:monitor.observations[snapshot.device.id]){monitor.showDetails=false}}}
        .sheet(item:$monitor.importReview){review in CoconutImportPanel(review:review,cancel:{monitor.importReview=nil},apply:{Task{await monitor.applyCoconutImport()}})}
        .task{await monitor.start();await monitor.selectScope()}
        .onChange(of:monitor.scope){_,_ in Task{await monitor.selectScope()}}
        .onChange(of:monitor.historyID){_,_ in Task{await monitor.reloadHistory()}}
    }
    private func deviceHeader(_ snapshot:BatterySnapshot)->some View {
        HStack(spacing:18){
            Image(systemName:snapshot.device.kind=="mac" ? "laptopcomputer":"iphone").font(.system(size:44,weight:.light)).foregroundStyle(LinearGradient(colors:[.blue,.cyan],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:86,height:86).background(.blue.opacity(0.1),in:RoundedRectangle(cornerRadius:22))
            VStack(alignment:.leading,spacing:6){Text(snapshot.device.name).font(.title2.bold());Text(snapshot.device.model+" · "+snapshot.device.system+" · #"+snapshot.device.id.prefix(12).uppercased()).font(.callout).foregroundStyle(.secondary);Text(LF("Последний замер: %@",dateLabel(snapshot.date))).font(.caption).foregroundStyle(.secondary)}
            Spacer()
            VStack(alignment:.trailing,spacing:10){if monitor.tracking{Label(L("Отслеживается"),systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(.green)};Button{monitor.showDetails=true}label:{Label(L("Подробнее"),systemImage:"info.circle")}}
        }
    }
    private func gauge(title:String,value:Double?,detail:String,symbol:String,tint:Color)->some View {
        VStack(alignment:.leading,spacing:14){HStack{Label(L(title),systemImage:symbol).foregroundStyle(.secondary);Spacer()};HStack(alignment:.firstTextBaseline){Text(value.map{formatted($0)+"%"} ?? "—").font(.system(size:38,weight:.semibold,design:.rounded)).monospacedDigit();Spacer();Text(detail).font(.callout).foregroundStyle(.secondary)}
            GeometryReader{g in ZStack(alignment:.leading){Capsule().fill(tint.opacity(0.13));Capsule().fill(LinearGradient(colors:[tint,tint.opacity(0.65)],startPoint:.leading,endPoint:.trailing)).frame(width:g.size.width*min(1,max(0,(value ?? 0)/100)))}}.frame(height:12)
        }.padding(22).frame(maxWidth:.infinity).background(Palette.card,in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(Palette.border.opacity(0.65))).shadow(color:.black.opacity(0.05),radius:10,y:4)
    }
    private func metric(_ title:String,value:String,symbol:String,subtitle:String="")->some View{
        VStack(alignment:.leading,spacing:10){Label(L(title),systemImage:symbol).font(.caption).foregroundStyle(.secondary);Text(value).font(.title2.weight(.semibold)).monospacedDigit().textSelection(.enabled);Text(L(subtitle)).font(.caption2).foregroundStyle(.tertiary)}.padding(18).frame(maxWidth:.infinity,minHeight:106,alignment:.leading).background(Palette.card,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(Palette.border.opacity(0.65)))
    }
    private var historyCard:some View {BatteryHistoryCard(monitor:monitor)}
    private func dateLabel(_ date:Date)->String{date.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(interface.locale))}
    private func seriesName(_ point:BatteryPoint)->String{L("Батарея")+" "+String(monitor.packIndexes[point.reading.pack_hash ?? "unknown"] ?? 1)}
    private func chartValue(_ r:BatteryReading)->Double?{monitor.chartMetric=="health" ? r.health:monitor.chartMetric=="cycles" ? r.cycles:r.full_mah}
    private func formatted(_ n:Double?,decimals:Int=1)->String{n.map{$0.formatted(.number.precision(.fractionLength(0...decimals)))} ?? "—"}
    private func capacity(_ n:Double?)->String{n.map{formatted($0,decimals:0)+" "+L("мА·ч")} ?? "—"}
    private func healthColor(_ n:Double?)->Color{guard let n else{return .gray};return n>=80 ? .green:n>=60 ? .orange:.red}
}
