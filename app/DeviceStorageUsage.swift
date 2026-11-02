import Foundation

struct DeviceStorageUsage {
    let total:Int64
    let free:Int64
    var used:Int64 { total-free }
    init?(_ values:[String:Int64]) {
        // TotalDataAvailable is a separate iOS accounting counter, not free bytes.
        for (freeKey,totalKey) in [("AmountDataAvailable","TotalDiskCapacity"),("AFCFreeBytes","AFCTotalBytes")] {
            guard let total=values[totalKey],let free=values[freeKey],total>0,total<=1<<50,free>=0,free<=total else{continue}
            self.total=total;self.free=free;return
        }
        return nil
    }
}

struct DeviceSettingsStorage {
    let available:Int64
    let free:Int64
    let purgeable:Int64
    let date:Date
    init?(_ values:[String:Int64]) {
        guard let total=values["TotalDiskCapacity"],total>0,total<=1<<50,
              let available=values["SettingsAvailableBytes"],let free=values["SettingsFreeBytes"],
              let purgeable=values["SettingsPurgeableBytes"],let stamp=values["SettingsObservedAtUnixSeconds"],
              free>=0,purgeable>=0,free<=total,purgeable<=total,
              available<=total,available==free+purgeable,stamp>=1_577_836_800,
              Double(stamp)<=Date().timeIntervalSince1970+60 else{return nil}
        self.available=available;self.free=free;self.purgeable=purgeable
        self.date=Date(timeIntervalSince1970:Double(stamp))
    }
}
