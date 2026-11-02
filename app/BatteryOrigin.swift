// Date/producer codes researched from Citrus Battery (GPL-3.0); no raw serial is retained.
import Foundation

enum BatteryOrigin {
    static func manufacturer(_ serial:String)->String? {
        let code=String(serial.prefix(2)).uppercased()
        let groups:[(String,[String])]=[("Amperex Technology (ATL)",["AC","AE","AF","AX","AZ","YF"]),("Huizhou Desay Battery",["43","F5","FD","FU","LD","LY","RE","ZP"]),("Sony",["FX","RD","YG","YV","YW"]),("Samsung",["LZ","SB","ST"]),("Huapu Technology",["DV","FG","HH","HT"]),("Simplo Technology",["D8","D9","W0"]),("Sunwoda",["64","77","79","F8","LM","YS"]),("LG Chem",["LN","YH"]),("Dynapack Electronics",["9G","C0","DP"]),("TianJin Lishen Battery",["TP"]),("Dongguan NVT Technology",["FQ"])]
        return groups.first{$0.1.contains(code)}?.0
    }
    static func weekDate(serial:String,hours:Double?,now:Date=Date())->String? {
        let s=Array(serial);guard s.count==17,s.allSatisfy({$0.isASCII}),let digit=s[3].wholeNumberValue,let week=Int(String(s[4...5])),(1...53).contains(week),let hours,hours>24,hours<200000 else{return nil}
        let estimate=now.addingTimeInterval(-hours*3600);var cal=Calendar(identifier:.iso8601);cal.timeZone=TimeZone(secondsFromGMT:0)!
        let center=cal.component(.year,from:estimate)
        let candidates=(center-10...center+10).filter{$0%10==digit}.compactMap{year->Date? in
            guard let d=cal.date(from:DateComponents(weekday:2,weekOfYear:week,yearForWeekOfYear:year)),cal.component(.yearForWeekOfYear,from:d)==year,d<=now,abs(d.timeIntervalSince(estimate))<2*366*86400 else{return nil};return d
        }
        guard let date=candidates.min(by:{abs($0.timeIntervalSince(estimate))<abs($1.timeIntervalSince(estimate))}) else{return nil}
        return isoDay(date)
    }
    static func deviceWeek(serial:String,kind:String,model:String,now:Date=Date())->String? {
        let chars=Array(serial.uppercased());guard [11,12].contains(chars.count),chars.allSatisfy({$0.isASCII}) else{return nil}
        let years=Array("CDFGHJKLMNPQRSTVWXYZ"),weeks=Array("123456789CDFGHJKLMNPQRTVWXY"),offset=chars.count==12 ? 3:2
        guard let y=years.firstIndex(of:chars[offset]),let w=weeks.firstIndex(of:chars[offset+1]) else{return nil}
        let modernMac=["MacBookPro17,1","MacBookAir10,1","Macmini9,1","MacBookAir9,1","MacBookPro16,2","MacBookPro16,3","iMac20,1","iMac20,2"].contains(model)
        let mobileMajor=Int(model.replacingOccurrences(of:"iPhone",with:"").split(separator:",").first ?? "") ?? 0
        let year=(modernMac || (kind=="iphone" && mobileMajor>=13) ? 2029:2019)-(19-y)/2,week=w+(y%2==0 ? 1:27)
        var cal=Calendar(identifier:.iso8601);cal.timeZone=TimeZone(secondsFromGMT:0)!
        guard let date=cal.date(from:DateComponents(weekday:2,weekOfYear:week,yearForWeekOfYear:year)),cal.component(.yearForWeekOfYear,from:date)==year,date<=now else{return nil};return isoDay(date)
    }
    static func isoDay(_ date:Date)->String{let f=ISO8601DateFormatter();f.formatOptions=[.withFullDate];f.timeZone=TimeZone(secondsFromGMT:0);return f.string(from:date)}
}
