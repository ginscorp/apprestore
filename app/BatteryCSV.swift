import Foundation

enum BatteryCSV {
    static func csv(_ points:[BatteryPoint],device:BatteryDevice)->Data {
        func cell(_ value:String,protect:Bool=true)->String{let safe=protect && ["=","+","-","@","\t","\r"].contains(where:{value.hasPrefix($0)}) ? "'"+value:value;return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        let date=ISO8601DateFormatter();var lines=["date,device,model,system,full_charge_mAh,design_mAh,health_percent,charge_percent,current_mAh,cycles,temperature_C,voltage_mV,current_mA,battery_power_W,source,full_capacity_field"]
        func n(_ v:Double?)->String{v.map{String($0)} ?? ""}
        for p in points{let r=p.reading;lines.append(([date.string(from:p.date),device.name,device.model,r.system_version ?? "",n(r.full_mah),n(r.design_mah),n(r.health),n(r.charge_percent),n(r.current_mah),n(r.cycles),n(r.temperature_c),n(r.voltage_mv),n(r.current_ma),n(r.power_w),r.source,r.full_source ?? ""]).enumerated().map{cell($0.element,protect:!(4...13).contains($0.offset))}.joined(separator:","))}
        return Data((lines.joined(separator:"\n")+"\n").utf8)
    }
}
