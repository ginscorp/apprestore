import Foundation

struct BatteryLifetime:Codable,Sendable {
    var operating_hours:Double?,min_temp_c:Double?,max_temp_c:Double?,average_temp_c:Double?,min_voltage_mv:Double?,max_voltage_mv:Double?,max_charge_ma:Double?,max_discharge_ma:Double?,temperature_samples:Double?,last_calibration_cycles:Double?,updated_epoch:Double?
    var temperature_scale:String?
    static func decode(_ raw:[String:Any])->BatteryLifetime {
        func n(_ key:String,_ range:ClosedRange<Double>)->Double?{guard let value=raw[key] as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID() else{return nil};let v=value.doubleValue;return v.isFinite && range.contains(v) ? v:nil}
        let minimum=n("MinimumTemperature",-400...1000),maximum=n("MaximumTemperature",-400...1000),average=n("AverageTemperature",-400...1000)
        let divisor=(maximum ?? 0)>100 ? 10.0:1.0
        let lo=minimum.map{$0/divisor},hi=maximum.map{$0/divisor}
        let validRange=lo != nil && hi != nil && lo!<=hi! && lo!>=(-40) && hi!<=100
        let avg=average.map{$0>100 ? $0/10:$0}
        return BatteryLifetime(operating_hours:n("TotalOperatingTime",0...2_000_000),min_temp_c:validRange ? lo:nil,max_temp_c:validRange ? hi:nil,average_temp_c:avg.flatMap{(-40...100).contains($0) ? $0:nil},min_voltage_mv:n("MinimumPackVoltage",1000...30000),max_voltage_mv:n("MaximumPackVoltage",1000...30000),max_charge_ma:n("MaximumChargeCurrent",0...100000),max_discharge_ma:n("MaximumDischargeCurrent",-100000...0),temperature_samples:n("TemperatureSamples",0...1e10),last_calibration_cycles:n("CycleCountLastQmax",0...100000),updated_epoch:n("UpdateTime",1...4_102_444_800),temperature_scale:validRange ? (divisor==10 ? "controller_tenths":"controller_degrees"):nil)
    }
}
struct BatteryDetails:Codable,Sendable {
    var temperature_source:String?,manufacturer:String?,manufacture_date:String?,manufacture_date_source:String?,charger_watts:Double?,charger_name:String?
    var device_manufacture_date:String?,device_date_source:String?
    var cell_voltage_mv:[Double]?
    var lifetime:BatteryLifetime?
    var source:String?
}
struct CoconutSample:Sendable {
    let device:BatteryDevice
    let date:Date
    let reading:BatteryReading
    let sampleHash:String
    var passport:DevicePassport?=nil
}
struct CoconutPlan:Sendable {
    let file:URL
    let sha256:String
    let bytes:Int
    let samples:[CoconutSample]
    let total:Int
    let skipped:Int
    var devices:[BatteryDevice]{Dictionary(samples.map{($0.device.id,$0.device)},uniquingKeysWith:{$1}).values.sorted{$0.name<$1.name}}
}
struct CoconutImportResult:Sendable {let inserted:Int;let skipped:Int;let devices:Int}

struct CoconutDeviceReview:Sendable,Identifiable {let sourceID:String;let targetID:String;let name:String;let model:String;let existing:Bool;let count:Int;var id:String{sourceID}}
struct CoconutReview:Sendable,Identifiable {var id:String{token};let plan:CoconutPlan;let devices:[CoconutDeviceReview];let token:String}

extension BatteryDetails {
    func validate()throws {
        for value in [temperature_source,manufacturer,manufacture_date,manufacture_date_source,charger_name,source,device_manufacture_date,device_date_source]{if let value{guard value.utf8.count<=256,!value.contains("\0") else{throw BatteryFailure.invalidReading}}}
        if let watts=charger_watts{guard watts.isFinite,(0...1000).contains(watts) else{throw BatteryFailure.invalidReading}}
        if let cells=cell_voltage_mv{guard cells.count<=8,cells.allSatisfy({$0.isFinite && (1000...6000).contains($0)}) else{throw BatteryFailure.invalidReading}}
        if let lifetime {
            let pairs:[(Double?,ClosedRange<Double>)]=[(lifetime.operating_hours,0...2_000_000),(lifetime.min_temp_c,-40...100),(lifetime.max_temp_c,-40...100),(lifetime.average_temp_c,-40...100),(lifetime.min_voltage_mv,1000...30000),(lifetime.max_voltage_mv,1000...30000),(lifetime.max_charge_ma,0...100000),(lifetime.max_discharge_ma,-100000...0),(lifetime.temperature_samples,0...1e10),(lifetime.last_calibration_cycles,0...100000),(lifetime.updated_epoch,1...4_102_444_800)]
            for (value,range) in pairs{if let value{guard value.isFinite,range.contains(value) else{throw BatteryFailure.invalidReading}}}
            guard lifetime.temperature_scale==nil || ["controller_tenths","controller_degrees"].contains(lifetime.temperature_scale!) else{throw BatteryFailure.invalidReading}
        }
    }
}
