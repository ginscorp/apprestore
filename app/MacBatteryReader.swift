import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import Darwin

actor MacBatteryReader {
    func read()throws->BatterySnapshot {
        let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));guard service != 0 else{throw BatteryFailure.unavailable};defer{IOObjectRelease(service)}
        func property(_ key:String)->Any?{IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()}
        let nested=property("BatteryData") as? [String:Any] ?? [:]
        let packService=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceNameMatching("AppleSmartBatteryPack"))
        defer{if packService != 0{IOObjectRelease(packService)}}
        let packData=packService==0 ? [:]:(IORegistryEntryCreateCFProperty(packService,"BatteryData" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [String:Any] ?? [:])
        func num(_ value:Any?,_ range:ClosedRange<Double>)->Double?{guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() else{return nil};let v=n.doubleValue;return v.isFinite && range.contains(v) ? v:nil}
        func get(_ keys:[String],_ range:ClosedRange<Double>)->(Double?,String?){for key in keys{if let v=num(property(key),range){return(v,key)};if let v=num(nested[key],range){return(v,"BatteryData."+key)}};return(nil,nil)}
        var (fcc,fullSource)=get(["AppleRawMaxCapacity","FullChargeCapacity"],100...100000)
        if fcc==nil{(fcc,fullSource)=get(["NominalChargeCapacity"],100...100000)}
        if fcc==nil{(fcc,fullSource)=get(["MaxCapacity"],500...100000)}
        let design=get(["DesignCapacity"],100...100000).0,current=get(["AppleRawCurrentCapacity"],0...100000).0,cycles=get(["CycleCount"],0...100000).0,voltage=get(["Voltage"],1000...30000).0
        var percent=get(["CurrentCapacity"],0...100).0,temp:Double?
        if let blob=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),let sources=IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for item in sources {if let description=IOPSGetPowerSourceDescription(blob,item)?.takeUnretainedValue() as? [String:Any],description["Type"] as? String=="InternalBattery"{if let c=num(description["Current Capacity"],0...100000),let m=num(description["Max Capacity"],1...100000){percent=c/m*100};temp=num(description["Temperature"],-40...100)}}
        }
        // Raw SmartBattery temperature, when published, is hundredths of degrees C.
        if temp==nil,let t=get(["Temperature"],-4000...10000).0{temp=t/100}
        var temperatureSource:String? = temp==nil ? nil:"IOPowerSources/AppleSmartBattery"
        if temp==nil,let raw=num(packData["Temperature"],-4000...10000){temp=raw/100;temperatureSource="AppleSmartBatteryPack.BatteryData.Temperature"}
        var amps:Double?
        for key in ["InstantAmperage","Amperage"]{if let n=property(key) as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(){let v=Double(n.int64Value);if (-50000...50000).contains(v){amps=v;break}}}
        let serial=property("Serial") ?? packData["Serial"],pack:String?
        if let s=serial as? String,!s.isEmpty,s.utf8.count<=256{pack=BatteryIdentity.hash("pack:"+s)}else{pack=nil}
        var reading=BatteryReading(full_mah:fcc,design_mah:design,current_mah:current,charge_percent:percent,cycles:cycles,temperature_c:temp,voltage_mv:voltage,current_ma:amps,power_w:amps.flatMap{a in voltage.map{a*$0/1e6}},full_source:fullSource,pack_hash:pack,source:"apple_iokit_smartbattery",charging:property("IsCharging") as? Bool,external_power:property("ExternalConnected") as? Bool,fully_charged:property("FullyCharged") as? Bool)
        var details=BatteryDetails(temperature_source:temperatureSource,source:"AppleSmartBatteryPack/IOKit")
        if let life=packData["LifetimeData"] as? [String:Any]{details.lifetime=BatteryLifetime.decode(life)}
        if let serial=serial as? String{details.manufacturer=BatteryOrigin.manufacturer(serial);details.manufacture_date=BatteryOrigin.weekDate(serial:serial,hours:details.lifetime?.operating_hours);if details.manufacture_date != nil{details.manufacture_date_source="serial_week_estimate"}}
        if let manufacturer=property("Manufacturer") as? String,manufacturer.utf8.count<=100{details.manufacturer=manufacturer}
        if let adapter=property("AdapterDetails") as? [String:Any]{details.charger_watts=num(adapter["Watts"],0...1000);if let name=adapter["Name"] as? String,name.utf8.count<=200{details.charger_name=name}}
        reading.details=details
        try reading.validate()
        let platform=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPlatformExpertDevice"));guard platform != 0 else{throw BatteryFailure.unavailable};defer{IOObjectRelease(platform)}
        guard let uuid=IORegistryEntryCreateCFProperty(platform,"IOPlatformUUID" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String else{throw BatteryFailure.unavailable}
        var length=0;sysctlbyname("hw.model",nil,&length,nil,0);var data=[CChar](repeating:0,count:max(length,1));guard sysctlbyname("hw.model",&data,&length,nil,0)==0 else{throw BatteryFailure.unavailable}
        var device=BatteryDevice(id:BatteryIdentity.hash("mac:"+uuid),kind:"mac",name:(SCDynamicStoreCopyComputerName(nil,nil) as String?) ?? "Mac",model:String(cString:data),system:"macOS "+[ProcessInfo.processInfo.operatingSystemVersion.majorVersion,ProcessInfo.processInfo.operatingSystemVersion.minorVersion,ProcessInfo.processInfo.operatingSystemVersion.patchVersion].map(String.init).joined(separator:"."),tracking:true)
        let deviceSerial=IORegistryEntryCreateCFProperty(platform,"IOPlatformSerialNumber" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String
        if let deviceSerial,!deviceSerial.isEmpty{device.aliases=[BatteryIdentity.alias(kind:"mac",serial:deviceSerial)];reading.details?.device_manufacture_date=BatteryOrigin.deviceWeek(serial:deviceSerial,kind:"mac",model:device.model);if reading.details?.device_manufacture_date != nil{reading.details?.device_date_source="legacy_serial_week"}}
        reading.system_version=device.system
        try reading.validate()
        return BatterySnapshot(device:device,reading:reading,date:Date(),transient:BatteryTransientIdentity(deviceSerial:deviceSerial,batterySerial:serial as? String))
    }
}
