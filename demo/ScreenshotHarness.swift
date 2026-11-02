// Native SwiftUI capture of the public edition. All fixtures are invented.
// This executable is an offscreen test harness, not a device connection test.
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct ScreenshotHarness {
    @MainActor static func settle(_ host:NSView) {
        for _ in 0..<18 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.04))
        }
    }
    @MainActor static func save<V:View>(_ view:V,name:String,output:URL,
                                       height:Double=940,afterLayout:(()->Void)?=nil)throws {
        let desired=NSAppearance(named:InterfaceSettings.shared.theme == .dark ? .darkAqua:.aqua)!
        NSApp.appearance=desired
        let host=NSHostingView(rootView:view)
        host.appearance=desired
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:height),
                            styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.appearance=desired
        window.backgroundColor=NSColor.windowBackgroundColor
        window.contentView=host
        settle(host)
        afterLayout?()
        settle(host)
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {
            throw NSError(domain:"demo_capture",code:1)
        }
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let image=bitmap.cgImage,
              let destination=CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw NSError(domain:"demo_capture",code:2)
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else {throw NSError(domain:"demo_capture",code:3)}
        window.close()
    }
    @MainActor static func main() async throws {
        precondition(PublicEdition.preview)
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count==2 else {fatalError("Pass a new capture directory")}
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        let settings=InterfaceSettings.shared
        settings.language = .english
        settings.theme = .light
        let model=AppModel(preview:true)
        let work=DeviceWorkspace(app:model)
        model.loadBundledPreview()
        let phone=Device(udid:"DEMO-DEVICE",name:"Example iPhone",ios:"18.0",model:"iPhone14,7",paired:true)
        model.devices=[phone]
        model.target=phone.udid
        let reading=BatteryReading(full_mah:3100,design_mah:3279,current_mah:2480,
             charge_percent:80,cycles:184,temperature_c:28.4,voltage_mv:3920,
             power_w:-3.2,source:"synthetic_demo",reported_health_percent:95,charging:false,external_power:false)
        let date=Date(timeIntervalSince1970:1_768_478_400)
        let object:[String:Any] = ["model":"iPhone14,7","ios":"18.0","build":"DEMO",
             "name":"Example iPhone","camera_serial":"DEMO", "battery":["CycleCount":184],
             "storage":["TotalDiskCapacity":128*1_073_741_824,"AmountDataAvailable":72*1_073_741_824],
             "battery_available":true,"content_counts":["SongCount":12,"VideoCount":8,"PhotoCount":128,"ApplicationCount":24],
             "content_count_sources":["SongCount":"synthetic_demo","VideoCount":"synthetic_demo","PhotoCount":"synthetic_demo","ApplicationCount":"synthetic_demo"],
             "content_count_observed_at":Int(date.timeIntervalSince1970)]
        work.overview=try JSONDecoder().decode(DeviceOverview.self,from:JSONSerialization.data(withJSONObject:object))
        let identity=BatteryIdentity.hash("DEMO-DEVICE")
        let batteryDevice=BatteryDevice(id:identity,kind:"iphone",name:"Example iPhone",
                                       model:"iPhone14,7",system:"18.0",tracking:true)
        let snapshot=BatterySnapshot(device:batteryDevice,reading:reading,date:date)
        let history=BatteryHistory()
        for index in 0..<30 {
            var point=reading
            point.full_mah=3150-Double(index)*1.7
            point.cycles=155+Double(index)
            let sample=BatterySnapshot(device:batteryDevice,reading:point,date:date.addingTimeInterval(Double(index-29)*86400))
            try await history.record(sample,tracking:true)
        }
        let reopened=BatteryHistory()
        let saved=try await reopened.points(identity)
        let valid=try await reopened.integrity()
        precondition(saved.count==30 && valid)
        let library=output.appendingPathComponent("synthetic-library",isDirectory:true)
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:false)
        try JSONEncoder().encode(MediaIndex()).write(to:library.appendingPathComponent("metadata.json"))
        let backup=output.appendingPathComponent("synthetic-backup",isDirectory:true)
        _=try PublicLibraryBackup.copyLibrary(source:library,destination:backup,capacity:10_000_000_000)
        precondition(FileManager.default.fileExists(atPath:backup.appendingPathComponent("latest.json").path))
        let disabled=await PublicLibraryBackup.run(source:library)
        precondition(disabled.contains("отключено"))
        func seedBattery() {
            work.battery.mac=snapshot
            work.battery.phone=snapshot
            work.battery.devices=[batteryDevice]
            work.battery.points=(0..<30).map { index in
                var point=reading
                point.full_mah=3150-Double(index)*1.7
                point.cycles=155+Double(index)
                return BatteryPoint(id:Int64(index),date:date.addingTimeInterval(Double(index-29)*86400),reading:point)
            }
            work.battery.status="Synthetic demo data · no device connected"
        }
        work.tab = .overview
        seedBattery()
        try save(MainContent(model:model,workspace:work).environment(\.colorScheme,.light),
                 name:"overview-en.png",output:output)
        work.tab = .catalog
        settings.theme = .dark
        try save(MainContent(model:model,workspace:work).environment(\.colorScheme,.dark),
                 name:"catalog-en.png",output:output)
        work.tab = .battery
        settings.theme = .light
        try save(MainContent(model:model,workspace:work).environment(\.colorScheme,.light),
                 name:"battery-en.png",output:output,height:1300,afterLayout:seedBattery)
        let fields=[
            HardwareField(key:"DeviceName",section:"identity",value:"Example iPhone",source:"synthetic_demo"),
            HardwareField(key:"ProductType",section:"identity",value:"iPhone14,7",source:"synthetic_demo"),
            HardwareField(key:"SerialNumber",section:"identity",value:"DEMO-NOT-A-REAL-SERIAL",source:"synthetic_demo"),
            HardwareField(key:"ProductVersion",section:"system",value:"18.0",source:"synthetic_demo"),
            HardwareField(key:"TotalDiskCapacity",section:"storage",value:"137438953472",source:"synthetic_demo"),
            HardwareField(key:"BatteryCycleCount",section:"battery",value:"184",source:"synthetic_demo")]
        let passport=DevicePassport(fields:fields,date:date)
        let observation=TechnicalObservation(passport:passport,samples:30,firstSeen:date.addingTimeInterval(-29*86400),lastSeen:date,batteryIdentifiers:1)
        try save(VStack(alignment:.leading,spacing:22){Text("Technical passport · synthetic demo").font(.largeTitle.bold());DevicePassportContent(observation:observation)}.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,.light),
                 name:"passport-en.png",output:output)
        settings.language = .russian
        work.tab = .overview
        settings.theme = .dark
        try save(MainContent(model:model,workspace:work).environment(\.colorScheme,.dark),
                 name:"overview-ru.png",output:output)
        var engineBlocked=false,usbBlocked=false
        do { _=try await model.engine.call(["action":"ping"]) }
        catch { engineBlocked=(error as? BridgeError)?.code=="preview_read_only" }
        do { _=try await model.usb.call(["action":"devices"]) }
        catch { usbBlocked=(error as? BridgeError)?.code=="preview_read_only" }
        precondition(engineBlocked && usbBlocked)
        print("{\"native_ui_capture\":true,\"synthetic_data_only\":true,\"engine_blocked_in_demo\":true,\"usb_blocked_in_demo\":true,\"visible_window_opened\":false,\"images\":5,\"synthetic_sqlite_reopen_30_points\":true,\"bounded_backup_receipt\":true,\"automatic_backup_blocked_in_demo\":true}")
    }
}
