// Read-only SMC ABI informed by exelban/stats (MIT), pinned 032f4a5.
// Only key-info (9) and read-bytes (2) commands; no write or fan-control interface.
import Foundation
import IOKit

private struct BatterySMCMessage {
    struct Version {var major:UInt8=0;var minor:UInt8=0;var build:UInt8=0;var reserved:UInt8=0;var release:UInt16=0}
    struct Limits {var version:UInt16=0;var length:UInt16=0;var cpu:UInt32=0;var gpu:UInt32=0;var memory:UInt32=0}
    struct Info {var size:UInt32=0;var type:UInt32=0;var attributes:UInt8=0}
    var key:UInt32=0;var version=Version();var limits=Limits();var info=Info();var padding:UInt16=0
    var result:UInt8=0;var status:UInt8=0;var command:UInt8=0;var data:UInt32=0
    var bytes:(UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)=(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
enum BatterySMC {
    static func temperature()->(value:Double,source:String)? {
        guard MemoryLayout<BatterySMCMessage>.stride==80 else{return nil}
        let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));guard service != 0 else{return nil};defer{IOObjectRelease(service)}
        var connection:io_connect_t=0;guard IOServiceOpen(service,mach_task_self_,0,&connection)==KERN_SUCCESS else{return nil};defer{IOServiceClose(connection)}
        var readings:[Double]=[],keys:[String]=[]
        for key in ["TB1T","TB2T"] {
            var input=BatterySMCMessage(),output=BatterySMCMessage();input.key=key.utf8.reduce(0){($0<<8)|UInt32($1)};input.command=9
            var size=MemoryLayout<BatterySMCMessage>.stride
            guard IOConnectCallStructMethod(connection,2,&input,MemoryLayout<BatterySMCMessage>.stride,&output,&size)==KERN_SUCCESS,size==80,output.result==0,(1...32).contains(output.info.size) else{continue}
            input.info.size=output.info.size;let type=output.info.type;input.command=2;size=80
            guard IOConnectCallStructMethod(connection,2,&input,80,&output,&size)==KERN_SUCCESS,size==80,output.result==0 else{continue}
            let bytes=withUnsafeBytes(of:output.bytes){Array($0)}
            guard bytes.prefix(Int(input.info.size)).contains(where:{$0 != 0}),let value=decode(type:type,bytes:bytes),value.isFinite,(-40...100).contains(value) else{continue}
            readings.append(value);keys.append(key)
        }
        guard !readings.isEmpty else{return nil};return(readings.reduce(0,+)/Double(readings.count),"SMC "+keys.joined(separator:"/"))
    }
    static func decode(type:UInt32,bytes:[UInt8])->Double? {
        guard bytes.count>=4 else{return nil}
        switch type {
        case 0x666c7420:let bits=UInt32(bytes[0])|UInt32(bytes[1])<<8|UInt32(bytes[2])<<16|UInt32(bytes[3])<<24;return Double(Float(bitPattern:bits))
        case 0x73703738:return Double(Int16(bitPattern:UInt16(bytes[0])<<8|UInt16(bytes[1])))/256
        case 0x66706532:return Double(UInt16(bytes[0])<<8|UInt16(bytes[1]))/4
        default:return nil
        }
    }
}
