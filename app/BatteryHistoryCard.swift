import SwiftUI
import Charts

@MainActor final class HistoryChartState:ObservableObject {@Published var date:Date?;@Published var showRows=false}
struct BatteryHistoryCard:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    @ObservedObject var monitor:BatteryMonitor
    @StateObject private var state=HistoryChartState()
    private var points:[BatteryPoint]{monitor.dailyPoints.filter{value($0) != nil}}
    private var unit:String{monitor.chartMetric=="full" ? L("мА·ч"):monitor.chartMetric=="health" ? "%":L("Циклы")}
    private var selected:BatteryPoint?{guard let date=state.date else{return points.last};return points.min{abs($0.date.timeIntervalSince(date))<abs($1.date.timeIntervalSince(date))}}
    private var domain:ClosedRange<Double>{let values=points.compactMap(value),lo=values.min() ?? 0,hi=values.max() ?? 1;let pad=max((hi-lo)*0.15,monitor.chartMetric=="health" ? 1:max(hi*0.015,1));return max(0,lo-pad)...(hi+pad)}
    private var dates:ClosedRange<Date>{let a=points.first?.date ?? Date(),b=points.last?.date ?? a;return b.timeIntervalSince(a)<86400 ? a.addingTimeInterval(-43200)...b.addingTimeInterval(43200):a...b}
    var body:some View {
        VStack(alignment:.leading,spacing:22){
            HStack{VStack(alignment:.leading,spacing:5){Label(L("История батареи"),systemImage:"chart.xyaxis.line").font(.title3.bold());Text(LF("%@ замеров · %@ дней наблюдений",String(monitor.visiblePoints.count),String(Set(points.map{Calendar.current.startOfDay(for:$0.date)}).count))).font(.caption).foregroundStyle(.secondary)};Spacer();Button{Task{await monitor.exportCSV()}}label:{Label(L("Вся история CSV…"),systemImage:"square.and.arrow.up")}.disabled(monitor.points.isEmpty || monitor.busy)}
            HStack{Picker(L("Показатель"),selection:$monitor.chartMetric){Text(L("Полная емкость")).tag("full");Text(L("Состояние, %")).tag("health");Text(L("Циклы")).tag("cycles")}.pickerStyle(.segmented).frame(maxWidth:470);Spacer();Picker(L("Период истории"),selection:$monitor.period){Text(L("30 дней")).tag("30");Text(L("Год")).tag("365");Text(L("Все время")).tag("all")}.labelsHidden().frame(width:145)}
            if points.isEmpty{ContentUnavailableView(L("В выбранном периоде нет сохраненных замеров."),systemImage:"chart.line.uptrend.xyaxis").frame(height:210)}else{
                HStack(alignment:.top,spacing:28){
                    VStack(alignment:.leading,spacing:6){Text(state.date==nil ? L("Последний замер"):L("Выбранный замер")).font(.caption).foregroundStyle(.secondary);HStack(alignment:.firstTextBaseline,spacing:8){Text(number(selected.flatMap(value))).font(.system(size:34,weight:.semibold,design:.rounded)).monospacedDigit();Text(unit).foregroundStyle(.secondary)};if let selected{Text(date(selected.date)).font(.caption).foregroundStyle(.secondary)}}
                    Spacer()
                    if let latest=points.last,let first=points.first(where:{$0.reading.pack_hash==latest.reading.pack_hash}),let a=value(first),let b=value(latest),latest.date != first.date{VStack(alignment:.trailing,spacing:6){Text(L("Изменение за период")).font(.caption).foregroundStyle(.secondary);Text((b-a>0 ? "+":"")+number(b-a)+" "+unit).font(.title2.weight(.semibold)).monospacedDigit();Text(L("Для той же батареи")).font(.caption2).foregroundStyle(.tertiary)}}
                }
                plot.frame(height:260)
                HStack{Label(L("Наведи курсор на график, чтобы увидеть замер"),systemImage:"cursorarrow").font(.caption).foregroundStyle(.secondary);Spacer();if let first=points.first,let last=points.last{Text(shortDate(first.date)+" — "+shortDate(last.date)).font(.caption).foregroundStyle(.secondary)}}
                if points.count<2{Text(L("Пока есть один день наблюдений. История появится по мере новых замеров.")).font(.callout).foregroundStyle(.secondary)}
                DisclosureGroup(L("Последние замеры"),isExpanded:$state.showRows){VStack(spacing:0){ForEach(Array(monitor.visiblePoints.suffix(20).reversed())){p in HStack{Text(date(p.date));Spacer();Text(number(value(p))+" "+unit).monospacedDigit();Text(p.reading.source=="coconutBattery_import" ? "coconutBattery":"AppRestore").foregroundStyle(.secondary).frame(width:110,alignment:.trailing)}.font(.caption).padding(.vertical,9);Divider()}}.padding(.top,8)}
            }
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(Palette.card,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(Palette.border.opacity(0.65)))
        .onChange(of:monitor.chartMetric){_,_ in state.date=nil}.onChange(of:monitor.period){_,_ in state.date=nil}.onChange(of:monitor.historyID){_,_ in state.date=nil}.onChange(of:monitor.scope){_,_ in state.date=nil}
    }
    private var plot:some View {
        Chart {
            ForEach(points){p in if let v=value(p){
                LineMark(x:.value(L("Дата"),p.date),y:.value(unit,v)).foregroundStyle(by:.value(L("Батарея"),series(p))).lineStyle(StrokeStyle(lineWidth:2.5)).interpolationMethod(.linear)
                PointMark(x:.value(L("Дата"),p.date),y:.value(unit,v)).foregroundStyle(by:.value(L("Батарея"),series(p))).symbolSize(32)
            }}
            if let selected,state.date != nil,let v=value(selected){RuleMark(x:.value(L("Дата"),selected.date)).foregroundStyle(.secondary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth:1,dash:[4,4]));PointMark(x:.value(L("Дата"),selected.date),y:.value(unit,v)).foregroundStyle(.primary).symbolSize(65)}
        }.chartXScale(domain:dates).chartYScale(domain:domain)
        .chartYAxis{AxisMarks(position:.leading,values:.automatic(desiredCount:5)){AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[3,4]));AxisValueLabel()}}
        .chartXAxis{AxisMarks(values:.automatic(desiredCount:5)){AxisGridLine(stroke:StrokeStyle(lineWidth:0.4));if dates.upperBound.timeIntervalSince(dates.lowerBound)<60*86400{AxisValueLabel(format:.dateTime.day().month(.abbreviated).locale(interface.locale))}else{AxisValueLabel(format:.dateTime.month(.abbreviated).year(.twoDigits).locale(interface.locale))}}}
        .chartLegend(position:.bottom,alignment:.leading)
        .chartOverlay{proxy in GeometryReader{geometry in Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover{phase in switch phase{case .active(let location):if let anchor=proxy.plotFrame{let frame=geometry[anchor];if frame.contains(location){state.date=proxy.value(atX:location.x-frame.minX,as:Date.self)}};case .ended:state.date=nil}}}}
    }
    private func value(_ p:BatteryPoint)->Double?{monitor.chartMetric=="health" ? p.reading.health:monitor.chartMetric=="cycles" ? p.reading.cycles:p.reading.full_mah}
    private func series(_ p:BatteryPoint)->String{L("Батарея")+" "+String(monitor.packIndexes[p.reading.pack_hash ?? "unknown"] ?? 1)}
    private func number(_ value:Double?)->String{value.map{$0.formatted(.number.precision(.fractionLength(0...(monitor.chartMetric=="health" ? 1:0))))} ?? "—"}
    private func date(_ d:Date)->String{d.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(interface.locale))}
    private func shortDate(_ d:Date)->String{d.formatted(Date.FormatStyle(date:.abbreviated,time:.omitted).locale(interface.locale))}
}
