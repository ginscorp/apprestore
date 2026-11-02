import Foundation

// Allowlisted System Information fields, once per capture. Raw reports never leave memory.
enum MacSystemReport {
    static func fields() -> [HardwareField] {
        let task=Process(),pipe=Pipe()
        task.executableURL=URL(fileURLWithPath:"/usr/sbin/system_profiler")
        task.arguments=["-json","-detailLevel","mini","-timeout","12","SPHardwareDataType","SPNVMeDataType","SPSerialATADataType","SPDisplaysDataType"]
        task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
        do{try task.run()}catch{return []}
        let watchdog=DispatchWorkItem {if task.isRunning{task.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+18,execute:watchdog)
        defer{watchdog.cancel();try? pipe.fileHandleForReading.close();if task.isRunning{task.terminate()}}
        var data=Data()
        while true {
            guard let chunk=try? pipe.fileHandleForReading.read(upToCount:65536),!chunk.isEmpty else{break}
            data.append(chunk);if data.count>8*1024*1024{return []}
        }
        task.waitUntilExit()
        guard task.terminationStatus==0,let report=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return []}
        return normalize(report)
    }
    static func normalize(_ report:[String:Any])->[HardwareField] {
        var result:[HardwareField]=[]
        func add(_ key:String,_ value:Any?,_ section:String) {
            let text:String
            if let s=value as? String{text=s}else if let n=value as? NSNumber{text=n.stringValue}else{return}
            guard !text.isEmpty,text.utf8.count<=512,!text.unicodeScalars.contains(where:{$0.value<32}) else{return}
            result.append(HardwareField(key:key,section:section,value:text,source:"apple_system_profiler"))
        }
        if let h=(report["SPHardwareDataType"] as? [[String:Any]])?.first {
            for (source,key) in [("model_number","PartNumber"),("chip_type","ChipDescription"),("boot_rom_version","BootROMVersion"),("os_loader_version","OSLoaderVersion"),("number_processors","ProcessorDescription")] {add(key,h[source],"hardware")}
        }
        var disk=0
        func storage(_ rows:[[String:Any]]) {
            for row in rows.prefix(8) {
                if row["device_model"] != nil || row["spsata_model"] != nil {
                    disk+=1;guard disk<=8 else{return};let prefix="Disk.\(disk)."
                    for (source,key) in [("device_model","Model"),("spsata_model","Model"),("device_revision","Firmware"),("spsata_revision","Firmware"),("smart_status","SMARTStatus"),("spnvme_smart_status","SMARTStatus"),("spsata_smart_status","SMARTStatus"),("spnvme_trim_support","TRIM"),("spsata_trim_support","TRIM"),("size_in_bytes","CapacityBytes"),("detachable_drive","Removable"),("link_width","LinkWidth"),("link_speed","LinkSpeed")] {add(prefix+key,row[source],"storage")}
                }
                if let children=row["_items"] as? [[String:Any]]{storage(children)}
            }
        }
        for type in ["SPNVMeDataType","SPSerialATADataType"] {storage(report[type] as? [[String:Any]] ?? [])}
        for (i,gpu) in (report["SPDisplaysDataType"] as? [[String:Any]] ?? []).prefix(4).enumerated() {
            for key in ["sppci_model","sppci_cores","spdisplays_metal","spdisplays_vendor"] {add("GPU.\(i+1)."+key,gpu[key],"hardware")}
        }
        // SMART status is distinct from controller lifetime read/write/wear counters.
        let health=NVMeHealthReader.fields()
        result += health
        add("ssd_lifetime_counters",health.isEmpty ? "unavailable":"available","availability")
        return Array(Dictionary(result.map{($0.key,$0)},uniquingKeysWith:{first,_ in first}).values).sorted{$0.key<$1.key}
    }
}
