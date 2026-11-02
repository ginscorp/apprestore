import Foundation
import CryptoKit

actor CoconutReader {
    func plan(_ url:URL)throws->CoconutPlan {
        let before=try FileManager.default.attributesOfItem(atPath:url.path),bytes=try CoconutArchive.backupData(at:url)
        guard bytes.count<=16*1024*1024 else{throw CoconutFailure.invalidFile}
        let binary=try CoconutArchive.installedBinary()
        let rows=try CoconutArchive.decodedRecords(bytes,binary:binary),sha=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        let after=try FileManager.default.attributesOfItem(atPath:url.path)
        guard before[.modificationDate] as? Date==after[.modificationDate] as? Date,before[.size] as? NSNumber==after[.size] as? NSNumber else{throw CoconutFailure.invalidFile}
        var samples:[CoconutSample]=[],skipped=0,seen=Set<String>()
        for row in rows {
            do{let sample=try Self.sample(row);if seen.insert(sample.sampleHash).inserted{samples.append(sample)}else{skipped+=1}}catch{skipped+=1}
        }
        guard !samples.isEmpty else{throw CoconutFailure.invalidSchema}
        return CoconutPlan(file:url,sha256:sha,bytes:bytes.count,samples:samples.sorted{$0.date<$1.date},total:rows.count,skipped:skipped)
    }
    static func sample(_ row:[String:Any])throws->CoconutSample {
        func string(_ key:String,_ limit:Int=255)->String?{guard let s=row[key] as? String,!s.isEmpty,s.utf8.count<=limit,!s.contains("\0") else{return nil};return s}
        func n(_ key:String,_ range:ClosedRange<Double>)->Double?{guard let v=row[key] as? NSNumber,CFGetTypeID(v) != CFBooleanGetTypeID(),v.doubleValue.isFinite,range.contains(v.doubleValue) else{return nil};return v.doubleValue}
        guard let serial=string("Device.Serial",128),serial.unicodeScalars.allSatisfy({CharacterSet.alphanumerics.contains($0) || $0=="-"}),let epoch=n("Data.SnapshotDate",946684800...4_102_444_800),epoch<=Date().timeIntervalSince1970+86400,let type=string("Data.Type",20)?.lowercased(),["mac","ios","iphone","ipad"].contains(type) else{throw CoconutFailure.identityMissing}
        let kind=type=="mac" ? "mac":"iphone",alias=BatteryIdentity.alias(kind:kind,serial:serial),id=BatteryIdentity.hash("import:"+alias)
        let device=BatteryDevice(id:id,kind:kind,name:string("Device.Name") ?? "Apple Device",model:string("Device.Model",100) ?? "",system:string("Device.OSVersion",200) ?? "",tracking:false,aliases:[alias])
        let pack=string("Battery.Serial",200).map{BatteryIdentity.pack(kind:kind,serial:$0)}
        var reading=BatteryReading(full_mah:n("Battery.FCC",101...100000),design_mah:n("Battery.DC",101...100000),cycles:n("Battery.CycleCount",0...100000),full_source:"coconutBattery.Battery.FCC",pack_hash:pack,source:"coconutBattery_import")
        reading.system_version=device.system
        reading.reported_health_percent=n("Battery.StateOfHealth",0...200)
        try reading.validate()
        let identity:[String:Any]=["device":alias,"date":epoch,"pack":pack ?? "unknown","full":reading.full_mah.map{NSNumber(value:$0)} ?? NSNull(),"design":reading.design_mah.map{NSNumber(value:$0)} ?? NSNull(),"cycles":reading.cycles.map{NSNumber(value:$0)} ?? NSNull()]
        let hash=SHA256.hash(data:try JSONSerialization.data(withJSONObject:identity,options:.sortedKeys)).map{String(format:"%02x",$0)}.joined()
        var fields=[HardwareField(key:"SerialNumber",section:"identity",value:serial,source:"coconut_import"),HardwareField(key:"DeviceName",section:"identity",value:device.name,source:"coconut_import"),HardwareField(key:"ProductType",section:"hardware",value:device.model.isEmpty ? "unknown":device.model,source:"coconut_import")]
        if let s=string("Battery.Serial",200){fields.append(HardwareField(key:"BatterySerialNumber",section:"battery",value:s,source:"coconut_import"))}
        if !device.system.isEmpty{fields.append(HardwareField(key:"ProductVersion",section:"system",value:device.system,source:"coconut_import"))}
        let passport=DevicePassport(fields:fields,date:Date(timeIntervalSince1970:epoch));try passport.validate()
        return CoconutSample(device:device,date:Date(timeIntervalSince1970:epoch),reading:reading,sampleHash:hash,passport:passport)
    }
}
