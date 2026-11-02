import SwiftUI

struct PassportPresentation:Identifiable {let id=UUID();let observation:TechnicalObservation}
@MainActor final class PassportViewState:ObservableObject {@Published var presented:PassportPresentation?;@Published var section="identity"}
struct DevicePassportContent:View {
    @ObservedObject private var interface=InterfaceSettings.shared
    @StateObject private var state=PassportViewState()
    let observation:TechnicalObservation
    private var visibleFields:[HardwareField]{observation.passport.fields.filter{$0.key != "app_event_context" && $0.value != "requires_forma_sdk"}}
    private let sections=["identity","hardware","system","storage","network","battery","components","availability"]
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Label(L("Сохранено технических снимков"),systemImage:"externaldrive");Spacer();Text(String(observation.samples)).monospacedDigit()}.font(.callout)
            Text(LF("Последнее обновление: %@",observation.passport.date.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(interface.locale)))).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:4),spacing:8){
                ForEach(sections.filter{section in visibleFields.contains{$0.section==section}},id:\.self){section in
                    Button{state.section=section}label:{VStack(alignment:.leading,spacing:8){HStack{Image(systemName:sectionIcon(section));Spacer();Text(String(visibleFields.filter{$0.section==section}.count)).font(.caption2).foregroundStyle(.secondary)};Text(L(sectionTitle(section))).font(.caption.weight(.medium)).lineLimit(2).frame(height:30,alignment:.topLeading)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(state.section==section ? Color.accentColor.opacity(0.14):Palette.card,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(state.section==section ? Color.accentColor.opacity(0.6):Palette.border.opacity(0.65)))}.buttonStyle(.plain)
                }
            }
            let fields=visibleFields.filter{$0.section==state.section}
            if state.section=="storage",let used=fields.first(where:{$0.key.hasPrefix("NVMe.") && $0.key.hasSuffix(".PercentageUsed")}),let value=Double(used.value) {
                VStack(alignment:.leading,spacing:10){
                    HStack{Label(L("Износ SSD по контроллеру"),systemImage:"internaldrive");Spacer();Text(used.value+" %").font(.title2.bold()).monospacedDigit()}
                    ProgressView(value:min(100,value),total:100).tint(value>=90 ? .orange:.blue)
                    Text(L("Оценка использованного ресурса NVMe. Это не прогноз срока службы.")).font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(Palette.card,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(Palette.border.opacity(0.65)))
            }
            VStack(alignment:.leading,spacing:0){
                Label(L(sectionTitle(state.section)),systemImage:sectionIcon(state.section)).font(.headline).padding(.bottom,16)
                ForEach(fields){field in VStack(alignment:.leading,spacing:8){HStack(alignment:.top,spacing:24){Text(label(field)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true);Spacer(minLength:16);Text(value(field)).multilineTextAlignment(.trailing).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).font(.system(.callout,design:field.section=="identity" || field.section=="components" ? .monospaced:.default))};if field.key=="AppleCameraRollUsageCount"{AppleCameraRollMetricNote()}}.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,11).help(field.source);if field.id != fields.last?.id{Divider().opacity(0.6)}}
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Palette.card,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(Palette.border.opacity(0.65)))
            Text(LF("Наблюдалось идентификаторов батарей: %@. Смена идентификатора сама по себе не подтверждает ремонт.",String(observation.batteryIdentifiers))).font(.caption).foregroundStyle(.secondary)
            Text(L("Технический паспорт и история батареи связаны одним ID в частной локальной базе. Серийные номера, IMEI и MAC-адреса сохраняются, если доступны. Данные аккаунтов и личные файлы сюда не входят.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func sectionIcon(_ section:String)->String{["identity":"number.square","hardware":"cpu","system":"desktopcomputer","storage":"internaldrive","network":"network","battery":"battery.100percent","components":"square.stack.3d.up","availability":"checkmark.shield"][section] ?? "info.circle"}
    private func sectionTitle(_ section:String)->String{["identity":"Идентификаторы","hardware":"Аппаратная часть","system":"Система","storage":"Хранилище","network":"Сеть","battery":"Батарея","components":"Модули","availability":"Доступность диагностики"][section] ?? section}
    private func label(_ field:HardwareField)->String {
        if field.key=="TotalDataAvailable",field.source=="apple_disk_usage" {return L("Счетчик iOS TotalDataAvailable")}
        return label(field.key)
    }
    private func label(_ key:String)->String {
        let diagnosticLabels=["AppleCameraRollUsageCount":"Служебный счетчик медиатеки Apple","AppleCameraRollUsageObservedAtUnixSeconds":"Время служебного показания Apple","AppleCameraRollUsageInterpretation":"Интерпретация служебного счетчика Apple"]
        if let label=diagnosticLabels[key]{return L(label)}
        let countLabels=["ContentCountsObservedAtUnixSeconds":"Время подсчета содержимого","SongCountStatus":"Доступность счетчика песен","VideoCountStatus":"Доступность счетчика видео","PhotoCountStatus":"Доступность счетчика фото","ApplicationCountStatus":"Доступность счетчика приложений"]
        if let label=countLabels[key]{return L(label)}
        if key.hasPrefix("NVMe.") {
            let labels=["PercentageUsed":"Износ SSD по контроллеру","EstimatedRemainingPercent":"Оценка оставшегося ресурса SSD","AvailableSparePercent":"Резервные блоки SSD","SpareThresholdPercent":"Порог резервных блоков SSD","CriticalWarning":"Предупреждения контроллера SSD","TemperatureC":"Температура SSD","DataReadBytes":"Всего прочитано SSD","DataWrittenBytes":"Всего записано SSD","PowerOnHours":"Наработка SSD","PowerCycles":"Включений SSD","UnsafeShutdowns":"Нештатных отключений SSD","MediaErrors":"Ошибки данных SSD"]
            let parts=key.split(separator:".");if let suffix=parts.last,let label=labels[String(suffix)]{return L(label)+" · "+String(parts.dropFirst().first ?? "")}
        }
let extra:[String:String]=["SettingsAvailableBytes":"Доступно по расчету iOS","SettingsFreeBytes":"Свободные блоки по расчету iOS","SettingsPurgeableBytes":"Место, которое может освободить iOS","SettingsObservedAtUnixSeconds":"Время расчета iOS","AmountDataAvailable":"Свободно для записи по USB","AmountDataReserved":"Зарезервировано iOS","AmountRestoreAvailable":"Доступно для восстановления iOS","AFCTotalBytes":"Объем файловой системы по USB","AFCFreeBytes":"Свободно в файловой системе по USB","PartNumber":"Артикул модели","RegulatoryModelNumber":"Номер модели A","IntegratedCircuitCardIdentity":"ICCID SIM","ICCID":"ICCID SIM","EID":"EID eSIM","EUICCIdentifier":"EID eSIM","SEID":"SEID Secure Element","CarrierName":"Оператор","CarrierBundleVersion":"Версия настроек оператора","MobileCountryCode":"Код страны оператора (MCC)","MobileNetworkCode":"Код сети оператора (MNC)","CurrentMCC":"Текущий MCC","CurrentMNC":"Текущий MNC","RadioAccessTechnology":"Радиотехнология","SIMStatus":"Состояние SIM","SIMTrayStatus":"Состояние лотка SIM","CarrierLock":"Блокировка оператора","NetworkName":"Сеть оператора","WiFi.SSID":"Название сети Wi-Fi","WiFi.IO80211SSID":"Название сети Wi-Fi","WiFi.BSSID":"BSSID точки доступа Wi-Fi","WiFi.IO80211BSSID":"BSSID точки доступа Wi-Fi","LocalIPv4":"Локальные IPv4","LocalIPv6":"Локальные IPv6","VPNConnectionsReportedBySC":"VPN-подключения, видимые SystemConfiguration","ChipDescription":"Чип","BootROMVersion":"Прошивка Boot ROM","OSLoaderVersion":"Версия загрузчика ОС","ProcessorDescription":"Описание процессора","vpn_status":"Состояние VPN","external_ip":"Внешний IP","warranty_expiry":"Дата окончания гарантии","media_counts":"Количество медиа и приложений","carrier_details":"Сведения оператора","sim_identifiers":"Идентификаторы SIM/eSIM","regulatory_model":"Номер модели A","wifi_connection":"Подключенная сеть Wi-Fi","ssd_lifetime_counters":"Счетчики износа SSD","SongCount":"Количество песен","VideoCount":"Количество видео","PhotoCount":"Количество фотографий","ApplicationCount":"Количество приложений","AmountCameraUsage":"Место, занятое камерой","AmountApplicationUsage":"Место приложений","AmountMusicUsage":"Место музыки","AmountVideoUsage":"Место видео","AmountPhotoUsage":"Место фотографий","AmountDataUsed":"Занято данных"];if let label=extra[key]{return L(label)};return L(["battery":"Батарея","storage":"Хранилище","ActivationState":"Состояние активации","BasebandStatus":"Состояние модема","BoardId":"Идентификатор платы","ChipID":"Модель чипа","ChipSerialNo":"Серийный номер чипа","DeviceColor":"Код цвета устройства","DeviceEnclosureColor":"Код цвета корпуса","FirmwareVersion":"Версия прошивки","BootloaderVersion":"Версия загрузчика","HasSiDP":"Флаг SiDP","MLBSerialNumber":"Серийный номер системной платы","ProductionSOC":"Серийный SoC","ProtocolVersion":"Версия протокола","SupportedDeviceFamilies":"Поддерживаемые семейства устройств","TelephonyCapability":"Поддержка телефонии","WiFi.IO80211Channel":"Канал Wi-Fi","WiFi.IOInterfaceUnit":"Номер интерфейса Wi-Fi","WiFi.IO80211RSSI":"Уровень сигнала Wi-Fi","WiFi.IO80211Noise":"Шум Wi-Fi","WiFi.CurrentPowerState":"Состояние питания Wi-Fi","SerialNumber":"Серийный номер устройства","HardwareUUID":"Аппаратный UUID","UniqueDeviceID":"UDID","UniqueChipID":"Идентификатор чипа","InternationalMobileEquipmentIdentity":"IMEI","InternationalMobileEquipmentIdentity2":"IMEI 2","MobileEquipmentIdentifier":"MEID","DeviceName":"Название устройства","ProductType":"Модель","ProductName":"Семейство устройства","DeviceClass":"Тип устройства","ProductVersion":"Версия системы","BuildVersion":"Сборка системы","HardwareModel":"Плата","HardwarePlatform":"Платформа","ModelNumber":"Артикул модели (основание)","RegionInfo":"Регион модели","CPUArchitecture":"Архитектура процессора","CPUModel":"Процессор","PhysicalCPUs":"Физические ядра","LogicalCPUs":"Логические ядра","MemoryBytes":"Оперативная память","SystemUptimeSeconds":"Время с перезапуска","ThermalState":"Тепловое состояние","TotalDiskCapacity":"Объем накопителя","TotalDataAvailable":"Свободно","TotalDataCapacity":"Раздел данных","TotalSystemCapacity":"Системный раздел","WiFiAddress":"MAC Wi-Fi","BluetoothAddress":"MAC Bluetooth","EthernetAddress":"MAC Ethernet","BatterySerialNumber":"Серийный номер батареи","BasebandVersion":"Прошивка модема","PrimaryInterface":"Основной сетевой интерфейс","ActiveWirelessTechnology":"Радиотехнология, переданная системой","mobilegestalt":"Расширенные сведения iOS","repair_history":"История замен модулей","live_sensor_tests":"Проверка датчиков в реальном времени","wifi_diagnostics":"Диагностика Wi-Fi"][key] ?? key)}
    private func value(_ field:HardwareField)->String {
        if field.key=="AppleCameraRollUsageInterpretation",field.value=="requires_interpretation"{return L("Значение требует интерпретации")}
        if field.key=="AppleCameraRollUsageObservedAtUnixSeconds",let seconds=Double(field.value){return Date(timeIntervalSince1970:seconds).formatted(Date.FormatStyle(date:.abbreviated,time:.standard).locale(interface.locale))}
        if field.key=="AppleCameraRollUsageCount",let number=Int64(field.value){return number.formatted(.number.locale(interface.locale))}
        if ["SettingsObservedAtUnixSeconds","ContentCountsObservedAtUnixSeconds"].contains(field.key),let seconds=Double(field.value){return Date(timeIntervalSince1970:seconds).formatted(Date.FormatStyle(date:.abbreviated,time:.standard).locale(interface.locale))}
        if field.key.hasPrefix("Settings"),field.key.hasSuffix("Bytes"),let bytes=Int64(field.value){return humanSize(bytes)}
        if ["SongCount","VideoCount","PhotoCount","ApplicationCount"].contains(field.key),let number=Int64(field.value){return number.formatted(.number.locale(interface.locale))}
        let statuses=["partial":"Получено частично","requires_device_network_request":"Нужен запрос с самого устройства","requires_external_request":"Нужен внешний сетевой запрос","requires_apple_coverage_check":"Проверяется отдельно у Apple","requires_native_smart_provider":"Нужен отдельный SMART-сборщик","true":"Да","false":"Нет","available":"Доступно","unavailable":"Недоступно","not_returned":"Не передано","deprecated_by_ios":"Этот интерфейс отключен в данной iOS","not_exposed_by_trust":"Не передается через обычное доверенное подключение","not_exposed_by_system_api":"Не передается этим системным интерфейсом","requires_device_app":"Нужно диагностическое приложение на устройстве","requires_forma_sdk":"Нужен модуль диагностики внутри Forma","nominal":"Нормальное","fair":"Повышенное","serious":"Высокое","critical":"Критическое"]
        if field.key.hasPrefix("NVMe.") {
            if field.key.hasSuffix("Bytes"),let bytes=Int64(field.value){return humanSize(bytes)}
            if field.key.hasSuffix("PowerOnHours"),let hours=Double(field.value){return humanDuration(hours*3600)}
            if field.key.hasSuffix("Percent") || field.key.hasSuffix("PercentageUsed"){return field.value+" %"}
            if field.key.hasSuffix("TemperatureC"){return field.value+" °C"}
        }
        if (["MemoryBytes","AmountDataAvailable","AmountDataReserved","AmountRestoreAvailable","AFCTotalBytes","AFCFreeBytes","TotalSystemAvailable","TotalDiskCapacity","TotalDataAvailable","TotalDataCapacity","TotalSystemCapacity","AmountCameraUsage","AmountApplicationUsage","AmountMusicUsage","AmountVideoUsage","AmountPhotoUsage","AmountDataUsed"].contains(field.key) || field.key.hasSuffix("CapacityBytes")),let bytes=Int64(field.value){return humanSize(bytes)}
        if field.key=="SystemUptimeSeconds"{return humanDuration(Double(field.value))}
        return statuses[field.value].map(L) ?? field.value
    }
}
struct AppleCameraRollMetricNote:View {
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            Label(L("Значение требует интерпретации"),systemImage:"info.circle").foregroundStyle(.orange)
            Text(L("Источник: Apple · Photo.CameraRoll._Count")).font(.system(.caption2,design:.monospaced)).foregroundStyle(.secondary)
            Text(L("Формула Apple не подтверждена. Показание сохраняется для диагностики и не используется для подсчета фото, видео, свободного места или объема переноса.")).foregroundStyle(.secondary)
        }.font(.caption)
    }
}
struct DevicePassportPanel:View {
    let observation:TechnicalObservation
    let close:()->Void
    var body:some View {VStack(alignment:.leading,spacing:18){HStack{Text(L("Технический паспорт")).font(.title2.bold());Spacer();Button(L("Готово"),action:close).keyboardShortcut(.cancelAction)};ScrollView{DevicePassportContent(observation:observation).padding(.vertical,6)}}.padding(26).frame(width:700,height:700)}
}
