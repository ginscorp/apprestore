import SwiftUI

@MainActor final class BatteryDetailState:ObservableObject {@Published var tab="battery";@Published var reveal=true}
struct BatteryDetailPanel:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    @StateObject private var state=BatteryDetailState()
    let snapshot:BatterySnapshot
    var observation:TechnicalObservation?=nil
    let close:()->Void
    private var r:BatteryReading{snapshot.reading}
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{VStack(alignment:.leading,spacing:5){Text(L("Сведения об устройстве и батарее")).font(.title2.bold());Text(snapshot.device.name+" · "+snapshot.device.model).foregroundStyle(.secondary)};Spacer();Button(L("Готово"),action:close).keyboardShortcut(.cancelAction)}
            Picker(L("Раздел сведений"),selection:$state.tab){Text(L("Устройство")).tag("device");Text(L("Батарея")).tag("battery");Text(L("За весь срок")).tag("lifetime")}.pickerStyle(.segmented).labelsHidden()
            ScrollView{VStack(alignment:.leading,spacing:16){
                if state.tab=="device" {
                    if let observation{DevicePassportContent(observation:observation)}else{GroupBox{VStack(spacing:12){row("Модель",snapshot.device.model);row("Версия системы",snapshot.device.system);row("Уникальный локальный ID",snapshot.device.id);row("Серийный номер устройства",serial(snapshot.transient?.deviceSerial));row("Неделя производства устройства",r.details?.device_manufacture_date)}}}
                    Text(L("Устройства сопоставляются по аппаратным идентификаторам. Имя можно менять; одинаковые имена не объединяют историю.")).font(.caption).foregroundStyle(.secondary)
                }else if state.tab=="battery" {
                    GroupBox{VStack(spacing:12){row("Емкость полной зарядки",unit(r.full_mah,"мА·ч"));row("Заводская емкость",unit(r.design_mah,"мА·ч"));row("Циклы зарядки",number(r.cycles));row("Температура батареи",unit(r.temperature_c,"°C"));row("Производитель по коду",r.details?.manufacturer);row("Неделя производства батареи",r.details?.manufacture_date);if let date=r.details?.manufacture_date,let age=age(date){row("Возраст от указанной недели",LF("Примерно %@ дней",String(age)))};row("Серийный номер батареи",serial(snapshot.transient?.batterySerial ?? observation?.passport.value("BatterySerialNumber")));row("ID батареи",r.pack_hash.map{String($0.prefix(12)).uppercased()});row("Мощность адаптера",unit(r.details?.charger_watts,"W"));row("Адаптер",r.details?.charger_name)}}
                    if let cells=r.details?.cell_voltage_mv,!cells.isEmpty {GroupBox(L("Напряжение ячеек")){VStack(spacing:10){ForEach(Array(cells.enumerated()),id:\.offset){index,value in row(LF("Ячейка %@",String(index+1)),unit(value,"mV"))}}}}
                    Text(L("Производитель и неделя могут быть расшифрованы из кода батареи. Неделя — приблизительная дата, а не подтвержденный день изготовления.")).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(L("Источники показаний")){VStack(alignment:.leading,spacing:8){Text("FCC: "+(r.full_source ?? "—"));Text(L("Температура батареи")+": "+(r.details?.temperature_source ?? "—"));Text(L("Источник")+": "+r.source)}.font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(.top,8)}
                }else if let l=r.details?.lifetime {
                    GroupBox{VStack(spacing:12){row("Наработка батареи",humanDuration(l.operating_hours.map{$0*3600}));row("Средняя температура",unit(l.average_temp_c,"°C"));row("Диапазон температур",range(l.min_temp_c,l.max_temp_c,"°C"));row("Максимальный ток заряда",unit(l.max_charge_ma,"mA"));row("Максимальный ток разряда",unit(l.max_discharge_ma.map{abs($0)},"mA"));row("Диапазон напряжения",range(l.min_voltage_mv.map{$0/1000},l.max_voltage_mv.map{$0/1000},"V"));row("Температурные отсчеты контроллера",number(l.temperature_samples));row("Цикл последней калибровки Qmax",number(l.last_calibration_cycles));if let cycle=r.cycles,let last=l.last_calibration_cycles,last<=cycle{row("Циклов после калибровки",number(cycle-last))};row("Обновление счетчиков",l.updated_epoch.map{Date(timeIntervalSince1970:$0).formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(interface.locale))})}}
                    Text(L("Эти счетчики накоплены контроллером за время работы батареи. Они доступны отдельно от истории наблюдений AppRestore. Состав и точность зависят от устройства.")).font(.caption).foregroundStyle(.secondary)
                }else{ContentUnavailableView(L("Счетчики за весь срок не переданы"),systemImage:"clock.badge.questionmark",description:Text(L("История AppRestore продолжает сохранять доступные текущие замеры.")))}
            }.padding(.vertical,4)}
            Text(L("Серийные номера сохраняются в частном техническом паспорте. История связана по отдельным ID устройства и батареи; имена не используются для объединения.")).font(.caption2).foregroundStyle(.secondary)
        }.padding(26).frame(width:660,height:650)
    }
    private func row(_ label:String,_ value:String?)->some View {HStack(alignment:.top,spacing:24){Text(L(label)).foregroundStyle(.secondary);Spacer(minLength:20);Text(value?.isEmpty==false ? value!:"—").multilineTextAlignment(.trailing).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)}.frame(maxWidth:.infinity,alignment:.leading)}
    private func number(_ n:Double?)->String?{n.map{$0.formatted(.number.precision(.fractionLength(0...2)))}}
    private func unit(_ n:Double?,_ u:String)->String?{number(n).map{$0+" "+L(u)}}
    private func range(_ lo:Double?,_ hi:Double?,_ u:String)->String?{guard let lo,let hi else{return nil};return (number(lo) ?? "—")+" … "+(number(hi) ?? "—")+" "+L(u)}
    private func serial(_ value:String?)->String?{guard let value else{return nil};return state.reveal ? value:"•••• "+value.suffix(4)}
    private func age(_ iso:String)->Int?{let f=ISO8601DateFormatter();f.formatOptions=[.withFullDate];guard let date=f.date(from:iso),date<=Date() else{return nil};return Calendar.current.dateComponents([.day],from:date,to:Date()).day}
}

struct CoconutImportPanel:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    let review:CoconutReview
    let cancel:()->Void
    let apply:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16){Text(L("Перенос истории coconutBattery")).font(.title2.bold());Text(review.plan.file.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            Text(LF("Замеров: %@. Устройств: %@. Пропущено при чтении: %@.",String(review.plan.samples.count),String(review.devices.count),String(review.plan.skipped)))
            if let first=review.plan.samples.map(\.date).min(),let last=review.plan.samples.map(\.date).max(){Text(first.formatted(Date.FormatStyle(date:.abbreviated,time:.omitted).locale(interface.locale))+" — "+last.formatted(Date.FormatStyle(date:.abbreviated,time:.omitted).locale(interface.locale))).font(.caption).foregroundStyle(.secondary)}
            ScrollView{VStack(spacing:12){ForEach(review.devices){d in HStack{Image(systemName:d.existing ? "link.circle.fill":"plus.circle").foregroundStyle(d.existing ? Color.green:Color.blue);VStack(alignment:.leading,spacing:5){Text(d.name).font(.headline);Text(d.model+" · #"+d.targetID.prefix(12).uppercased()).font(.caption).foregroundStyle(.secondary);Text(L(d.existing ? "Продолжить существующую историю":"Добавить отдельное устройство")).font(.caption)};Spacer();Text(LF("%@ замеров",String(d.count))).font(.caption)}.padding(14).background(Palette.card,in:RoundedRectangle(cornerRadius:14))}}}
            let missing=review.plan.samples.filter{$0.reading.full_mah==nil || $0.reading.design_mah==nil}.count
            if missing>0{Text(LF("Без подтвержденной емкости: %@. Даты и циклы сохранятся; процент не будет выдуман.",String(missing))).font(.caption).foregroundStyle(.secondary)}
            Text(L("Сопоставление использует аппаратные идентификаторы. Перед записью будет создан проверенный снимок нашей базы. Исходная история coconutBattery сохраняется; повторный перенос пропускает те же замеры.")).font(.caption).foregroundStyle(.secondary)
            HStack{Button(L("Отменить"),action:cancel);Spacer();Button(L("Перенести историю"),action:apply).buttonStyle(.borderedProminent)}
        }.padding(26).frame(width:660,height:590).interactiveDismissDisabled()
    }
}
