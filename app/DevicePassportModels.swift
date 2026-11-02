import Foundation

struct HardwareField:Codable,Identifiable,Sendable,Equatable {
    let key:String,section:String,value:String,source:String
    var id:String{key}
}
struct DevicePassport:Codable,Sendable {
    var fields:[HardwareField]
    var date:Date
    func value(_ key:String)->String?{fields.first{$0.key==key}?.value}
    func validate()throws {
        guard fields.count<=192,Set(fields.map(\.key)).count==fields.count,date.timeIntervalSince1970.isFinite,date.timeIntervalSince1970>0 else{throw BatteryFailure.invalidReading}
        let sections=["identity","hardware","system","network","battery","components","storage","availability"]
        for f in fields{guard f.key.utf8.count<=100,!f.key.isEmpty,f.key.unicodeScalars.allSatisfy({CharacterSet.alphanumerics.contains($0) || $0=="." || $0=="_" || $0=="-"}),sections.contains(f.section),f.source.utf8.count<=80,f.value.utf8.count<=1024,!f.value.isEmpty,!f.value.unicodeScalars.contains(where:{$0.value<32}) else{throw BatteryFailure.invalidReading}}
    }
    var signature:String {BatteryIdentity.hash(fields.sorted{$0.key<$1.key}.map{$0.key+"="+$0.value+"@"+$0.source}.joined(separator:"\0"))}
    var context:String {let keys=Set(["ProductVersion","BuildVersion","BatterySerialNumber","ActiveWirelessTechnology","PrimaryInterface","ThermalState"]);return BatteryIdentity.hash(fields.filter{keys.contains($0.key)}.sorted{$0.key<$1.key}.map{$0.key+"="+$0.value}.joined(separator:"\0"))}
}
struct TechnicalObservation:Sendable {let passport:DevicePassport;let samples:Int;let firstSeen:Date;let lastSeen:Date;let batteryIdentifiers:Int}
