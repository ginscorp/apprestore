import Foundation
import CryptoKit

struct BatteryReading:Codable,Sendable {
    var full_mah:Double?,design_mah:Double?,current_mah:Double?,charge_percent:Double?,cycles:Double?,temperature_c:Double?,voltage_mv:Double?,current_ma:Double?,power_w:Double?
    var full_source:String?,pack_hash:String?
    var source:String=""
    var details:BatteryDetails?
    var system_version:String?
    var reported_health_percent:Double?
    var charging:Bool?,external_power:Bool?,fully_charged:Bool?
    var health:Double? {guard let full_mah,let design_mah,design_mah>0 else{return reported_health_percent};return full_mah/design_mah*100}
    func validate()throws {
        for (value,range) in [(full_mah,100.0...100000),(design_mah,100.0...100000),(current_mah,0.0...100000),(charge_percent,0.0...100),(cycles,0.0...100000),(temperature_c,-40.0...100),(voltage_mv,1000.0...30000),(current_ma,-50000.0...50000),(power_w,-1500.0...1500)] {if let value{guard value.isFinite,range.contains(value) else{throw BatteryFailure.invalidReading}}}
        guard (system_version?.utf8.count ?? 0)<=200,reported_health_percent==nil || (reported_health_percent!.isFinite && (0...200).contains(reported_health_percent!)),source.utf8.count<=80,(full_source?.utf8.count ?? 0)<=100,pack_hash == nil || BatteryIdentity.valid(pack_hash!) else{throw BatteryFailure.invalidReading}
        try details?.validate()
    }
}
enum BatteryFailure:Error {case unavailable,invalidReading,unsafePath,database,historyLimit,unsupportedSchema,exportExists,identityConflict,recoveryLimit}
enum BatteryIdentity {
    static func hash(_ value:String)->String{SHA256.hash(data:Data(("AppRestore battery device v1\0"+value).utf8)).map{String(format:"%02x",$0)}.joined()}
    static func alias(kind:String,serial:String)->String{hash("alias:"+kind+":serial:"+serial.trimmingCharacters(in:.whitespacesAndNewlines).uppercased())}
    static func pack(kind:String,serial:String)->String {
        if kind=="mac"{return hash("pack:"+serial)}
        return SHA256.hash(data:Data(("AppRestore battery v1\0"+serial).utf8)).map{String(format:"%02x",$0)}.joined()
    }
    static func fileHash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func valid(_ value:String)->Bool{value.count==64 && value.allSatisfy{"0123456789abcdef".contains($0)}}
}
struct BatteryDevice:Identifiable,Codable,Sendable {let id:String;let kind:String;var name:String;let model:String;var system:String;var tracking:Bool;var aliases:[String]=[]}
struct BatteryPoint:Identifiable,Sendable {let id:Int64;let date:Date;let reading:BatteryReading}
struct BatterySnapshot:Sendable {let device:BatteryDevice;let reading:BatteryReading;let date:Date;var transient:BatteryTransientIdentity?=nil}
struct BatteryTransientIdentity:Sendable {let deviceSerial:String?;let batterySerial:String?}
