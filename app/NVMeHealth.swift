import Foundation
import IOKit

struct NVMeHealth:Sendable {
    let percentageUsed:Int,availableSpare:Int,spareThreshold:Int,criticalWarning:Int
    let temperature:Double?
    let readBytes:Int64?,writtenBytes:Int64?,powerOnHours:Int64?,powerCycles:Int64?,unsafeShutdowns:Int64?,mediaErrors:Int64?
    var estimatedRemaining:Int {max(0,100-percentageUsed)}
    static func decode(_ bytes:Data)->Self? {
        guard bytes.count==512,bytes.contains(where:{$0 != 0}) else{return nil}
        let b=[UInt8](bytes)
        func counter(_ offset:Int)->Int64? {
            guard b[(offset+8)..<(offset+16)].allSatisfy({$0==0}) else{return nil}
            let value=(0..<8).reduce(UInt64(0)){$0 | UInt64(b[offset+$1]) << ($1*8)}
            return Int64(exactly:value)
        }
        func amount(_ offset:Int)->Int64? {
            guard let value=counter(offset) else{return nil}
            let (bytes,overflow)=value.multipliedReportingOverflow(by:512_000)
            return overflow ? nil:bytes
        }
        let kelvin=Int(b[1]) | Int(b[2])<<8
        let temperature=kelvin>=173 && kelvin<=473 ? Double(kelvin)-273.15:nil
        return Self(percentageUsed:Int(b[5]),availableSpare:Int(b[3]),spareThreshold:Int(b[4]),criticalWarning:Int(b[0]),temperature:temperature,readBytes:amount(32),writtenBytes:amount(48),powerOnHours:counter(128),powerCycles:counter(112),unsafeShutdowns:counter(144),mediaErrors:counter(160))
    }
}

enum NVMeHealthReader {
    static func fields()->[HardwareField] {
        guard MemoryLayout<NVMeSMARTData>.size==512 else{return []}
        var iterator:io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOBlockStorageDevice"),&iterator)==KERN_SUCCESS else{return []}
        defer{IOObjectRelease(iterator)}
        var fields:[HardwareField]=[],count=0
        while case let device=IOIteratorNext(iterator),device != 0 {
            defer{IOObjectRelease(device)};count+=1;guard count<=32 else{break}
            guard let capable=IORegistryEntryCreateCFProperty(device,"NVMe SMART Capable" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Bool,capable,
                  let bsd=wholeBSD(device),let reading=read(device) else{continue}
            let prefix="NVMe."+bsd+"."
            func add(_ key:String,_ value:String?){if let value{fields.append(HardwareField(key:prefix+key,section:"storage",value:value,source:"apple_nvme_smart"))}}
            add("PercentageUsed",String(reading.percentageUsed));add("EstimatedRemainingPercent",String(reading.estimatedRemaining))
            add("AvailableSparePercent",String(reading.availableSpare));add("SpareThresholdPercent",String(reading.spareThreshold));add("CriticalWarning",String(reading.criticalWarning))
            add("TemperatureC",reading.temperature.map{String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),$0)})
            add("DataReadBytes",reading.readBytes.map(String.init));add("DataWrittenBytes",reading.writtenBytes.map(String.init))
            add("PowerOnHours",reading.powerOnHours.map(String.init));add("PowerCycles",reading.powerCycles.map(String.init))
            add("UnsafeShutdowns",reading.unsafeShutdowns.map(String.init));add("MediaErrors",reading.mediaErrors.map(String.init))
        }
        return fields.sorted{$0.key<$1.key}
    }
    static func wholeBSD(_ device:io_registry_entry_t)->String? {
        var children:io_iterator_t=0
        guard IORegistryEntryCreateIterator(device,kIOServicePlane,IOOptionBits(kIORegistryIterateRecursively),&children)==KERN_SUCCESS else{return nil}
        defer{IOObjectRelease(children)};var count=0
        while case let entry=IOIteratorNext(children),entry != 0 {
            defer{IOObjectRelease(entry)};count+=1;guard count<=256 else{break}
            let whole=IORegistryEntryCreateCFProperty(entry,"Whole" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Bool
            if whole==true,let name=IORegistryEntryCreateCFProperty(entry,"BSD Name" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String,name.range(of:"^disk[0-9]+$",options:.regularExpression) != nil{return name}
        }
        return nil
    }
    private static func read(_ device:io_registry_entry_t)->NVMeHealth? {
        var plugin:UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var smart:UnsafeMutablePointer<UnsafeMutablePointer<IONVMeSMARTInterface>?>?
        var score:Int32=0
        guard IOCreatePlugInInterfaceForService(device,ARNVMeClientID()?.takeUnretainedValue(),ARPluginInterfaceID()?.takeUnretainedValue(),&plugin,&score)==KERN_SUCCESS,let plugin else{return nil}
        defer{IODestroyPlugInInterface(plugin)}
        let status=withUnsafeMutablePointer(to:&smart){p in p.withMemoryRebound(to:Optional<LPVOID>.self,capacity:1){plugin.pointee?.pointee.QueryInterface(plugin,CFUUIDGetUUIDBytes(ARNVMeInterfaceID()?.takeUnretainedValue()),$0) ?? -1}}
        guard status==S_OK,let smart,let table=smart.pointee else{return nil}
        defer{_ = table.pointee.Release(smart)}
        var raw=NVMeSMARTData()
        guard table.pointee.SMARTReadData(smart,&raw)==KERN_SUCCESS else{return nil}
        return withUnsafeBytes(of:&raw){NVMeHealth.decode(Data($0))}
    }
}
