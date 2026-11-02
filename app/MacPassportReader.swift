import Foundation
import IOKit
import SystemConfiguration
import Darwin

actor MacPassportReader {
    func read(_ battery:BatterySnapshot)throws->DevicePassport {
        var fields:[HardwareField]=[]
        func add(_ key:String,_ value:String?,_ section:String,_ source:String="apple_iokit") {if let value,!value.isEmpty,value.utf8.count<=1024,!value.unicodeScalars.contains(where:{$0.value<32}){fields.append(HardwareField(key:key,section:section,value:value,source:source))}}
        func system(_ name:String)->String? {var n=0;guard sysctlbyname(name,nil,&n,nil,0)==0,n>0,n<1024 else{return nil};var bytes=[UInt8](repeating:0,count:n);guard sysctlbyname(name,&bytes,&n,nil,0)==0 else{return nil};return String(bytes:bytes.prefix{ $0 != 0 },encoding:.utf8)}
        func integer(_ name:String)->UInt64?{var value:UInt64=0,n=MemoryLayout<UInt64>.size;guard sysctlbyname(name,&value,&n,nil,0)==0 else{return nil};return value}
        let platform=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPlatformExpertDevice"));defer{if platform != 0{IOObjectRelease(platform)}}
        func property(_ service:io_service_t,_ key:String)->String? {guard service != 0,let value=IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() else{return nil};if let s=value as? String{return s};if let data=value as? Data,data.count<=128{return String(data:data,encoding:.utf8)?.trimmingCharacters(in:.controlCharacters)};return nil}
        add("SerialNumber",battery.transient?.deviceSerial,"identity");add("HardwareUUID",property(platform,"IOPlatformUUID"),"identity");add("BatterySerialNumber",battery.transient?.batterySerial,"battery")
        add("DeviceName",battery.device.name,"identity");add("ProductType",battery.device.model,"hardware");add("ProductVersion",battery.device.system,"system","apple_processinfo");add("BuildVersion",system("kern.osversion"),"system","apple_sysctl");add("CPUArchitecture",system("hw.machine"),"hardware","apple_sysctl");add("CPUModel",system("machdep.cpu.brand_string"),"hardware","apple_sysctl")
        for (key,name) in [("PhysicalCPUs","hw.physicalcpu"),("LogicalCPUs","hw.logicalcpu"),("MemoryBytes","hw.memsize")] {add(key,integer(name).map(String.init),"hardware","apple_sysctl")}
        add("SystemUptimeSeconds",String(Int(ProcessInfo.processInfo.systemUptime)),"system","apple_processinfo")
        let thermal:String;switch ProcessInfo.processInfo.thermalState{case .nominal:thermal="nominal";case .fair:thermal="fair";case .serious:thermal="serious";case .critical:thermal="critical";@unknown default:thermal="unknown"};add("ThermalState",thermal,"system","apple_processinfo")
        if let volumes=try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys:[.volumeTotalCapacityKey,.volumeAvailableCapacityKey]){add("TotalDiskCapacity",volumes.volumeTotalCapacity.map{String($0)},"storage","apple_url_resource");add("TotalDataAvailable",volumes.volumeAvailableCapacity.map{String($0)},"storage","apple_url_resource")}
        if let all=SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]{for item in all.prefix(32){if let name=SCNetworkInterfaceGetBSDName(item) as String?,name.range(of:"^[a-z]+[0-9]+$",options:.regularExpression) != nil{add("Interface."+name+".MAC",SCNetworkInterfaceGetHardwareAddressString(item) as String?,"network","apple_systemconfiguration");add("Interface."+name+".Type",SCNetworkInterfaceGetInterfaceType(item) as String?,"network","apple_systemconfiguration")}}}
        if let state=SCDynamicStoreCopyValue(nil,"State:/Network/Global/IPv4" as CFString) as? [String:Any]{add("PrimaryInterface",state["PrimaryInterface"] as? String,"network","apple_systemconfiguration")}
        let bluetooth=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOBluetoothHCIController"));defer{if bluetooth != 0{IOObjectRelease(bluetooth)}}
        add("BluetoothAddress",property(bluetooth,"BluetoothAddress"),"network")
        add("repair_history","not_exposed_by_system_api","availability","apprestore_capability")
        if let state=SCDynamicStoreCopyValue(nil,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let name=state["PrimaryInterface"] as? String {
            for family in ["IPv4","IPv6"] {
                if let network=SCDynamicStoreCopyValue(nil,"State:/Network/Interface/\(name)/\(family)" as CFString) as? [String:Any],let addresses=network["Addresses"] as? [String]{add("Local"+family,addresses.prefix(8).joined(separator:", "),"network","apple_systemconfiguration")}
            }
            if let wifi=SCDynamicStoreCopyValue(nil,"State:/Network/Interface/\(name)/AirPort" as CFString) as? [String:Any]{add("WiFi.SSID",wifi["SSID_STR"] as? String,"network","apple_systemconfiguration");add("WiFi.BSSID",wifi["BSSID"] as? String,"network","apple_systemconfiguration")}
        }
        if let preferences=SCPreferencesCreate(nil,"AppRestore" as CFString,nil),let services=SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] {
            var active=0
            for service in services {
                guard let id=SCNetworkServiceGetServiceID(service),let connection=SCNetworkConnectionCreateWithServiceID(nil,id,nil,nil) else{continue}
                if SCNetworkConnectionGetStatus(connection) == .connected{active+=1}
            }
            add("VPNConnectionsReportedBySC",String(active),"network","apple_systemconfiguration")
        }
        add("external_ip","requires_external_request","availability","apprestore_capability")
        fields += MacSystemReport.fields()
        let passport=DevicePassport(fields:fields.sorted{$0.key<$1.key},date:Date());try passport.validate();return passport
    }
}
