import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct USBMediaFile:Decodable,Sendable {
    let path:String;let name:String;let bytes:Int64;let created:Double?;let modified:Double?;let fingerprint:String
    var source:MediaSource{MediaSource(name:name,devicePath:path,bytes:bytes,created:created.map{Date(timeIntervalSince1970:$0)},modified:modified.map{Date(timeIntervalSince1970:$0)},group:String(repeating:"0",count:32))}
    func validate()throws{guard path.hasPrefix("/DCIM/"),path.utf8.count<=1800,MediaIntegrity.hex(fingerprint),bytes>=0,bytes<=64*1024*1024*1024,MediaIntegrity.name(name),[created,modified].compactMap({$0}).allSatisfy({$0.isFinite && abs($0)<100_000_000_000}) else{throw BridgeError(code:"invalid_media_entry")}}
}
struct USBMediaPage:Decodable {let files:[USBMediaFile];let folders:[String];let catalog_token:String;let next_offset:Int;let has_more:Bool;let skipped:Int}

// One bounded stdout stream per selected source, never a process per megabyte.
final class USBMediaStream:@unchecked Sendable {
    private let queue=DispatchQueue(label:"apprestore.media.stream",qos:.utility)
    private let lock=NSLock()
    private var child:Process?
    private var output:FileHandle?
    private var wire=Data(),pending=Data()
    private var active:String?
    private var row:USBMediaFile?
    private var received:Int64=0,consumed:Int64=0
    private var hash=SHA256()
    func cancel(){lock.lock();let process=child;lock.unlock();if let process,process.isRunning{process.terminate()}}
    private func perform<T>(_ body:@escaping ()throws->T)async throws->T{try await withCheckedThrowingContinuation{c in queue.async{do{c.resume(returning:try body())}catch{self.close();c.resume(throwing:error)}}}}
    private func close(){lock.lock();let process=child;child=nil;lock.unlock();if process?.isRunning==true{process?.terminate()};try? output?.close();output=nil;wire.removeAll();pending.removeAll();active=nil;row=nil}
    private func line()throws->[String:Any]{
        while true {
            if let end=wire.firstIndex(of:10){let data=Data(wire[..<end]);wire.removeSubrange(...end);guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw BridgeError(code:"invalid_media_stream")};if value["ok"] as? Bool==false{throw BridgeError(code:value["error"] as? String ?? "photo_read_failed")};return value}
            guard let output else{throw BridgeError(code:"photo_read_failed")};let bytes=output.availableData
            guard !bytes.isEmpty else{throw BridgeError(code:"photo_read_failed")};wire.append(bytes)
            guard wire.count<=3*1024*1024 else{throw BridgeError(code:"invalid_media_stream")}
        }
    }
    func begin(_ file:USBMediaFile,udid:String)async throws {try await perform{
        self.close();try file.validate()
        guard file.bytes>0,let resources=Bundle.main.resourceURL else{throw BridgeError(code:"media_original_unavailable")}
        let process=Process();process.executableURL=resources.appendingPathComponent("USB/apprestore-usb")
        process.environment=["PATH":"/usr/bin:/bin","PYTHONNOUSERSITE":"1","PYTHONDONTWRITEBYTECODE":"1","TMPDIR":NSTemporaryDirectory()]
        let input=Pipe(),output=Pipe();process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        self.lock.lock();self.child=process;self.lock.unlock();self.output=output.fileHandleForReading
        try process.run()
        var data=try JSONSerialization.data(withJSONObject:["action":"media_stream","udid":udid,"path":file.path,"fingerprint":file.fingerprint]);data.append(10);try input.fileHandleForWriting.write(contentsOf:data);try input.fileHandleForWriting.close()
        let header=try self.line()
        guard header["event"] as? String=="media_header",header["bytes"] as? Int64==file.bytes,header["fingerprint"] as? String==file.fingerprint else{throw BridgeError(code:"source_changed")}
        self.row=file;self.active=file.source.id;self.received=0;self.consumed=0;self.hash=SHA256()
    }}
    func read(_ id:String,offset:Int64,count:Int)async throws->Data{try await perform{
        guard self.active==id,self.consumed==offset,let row=self.row,count>0,count<=1024*1024,offset<row.bytes else{throw BridgeError(code:"invalid_media_stream")}
        if self.pending.isEmpty {
            let value=try self.line()
            guard value["event"] as? String=="media_chunk",value["offset"] as? Int64==self.received,
                  let raw=value["data"] as? String,raw.utf8.count<=1_398_104,let bytes=Data(base64Encoded:raw),!bytes.isEmpty,bytes.count<=1024*1024,self.received+Int64(bytes.count)<=row.bytes else{throw BridgeError(code:"invalid_media_stream")}
            self.pending=bytes;self.received+=Int64(bytes.count);self.hash.update(data:bytes)
        }
        let bytes=Data(self.pending.prefix(count));self.pending.removeFirst(bytes.count);self.consumed+=Int64(bytes.count);return bytes
    }}
    func finish(_ id:String)async throws{try await perform{
        guard self.active==id,let row=self.row,self.pending.isEmpty,self.received==row.bytes,self.consumed==row.bytes else{throw BridgeError(code:"incomplete_export")}
        let final=try self.line(),sha=self.hash.finalize().map{String(format:"%02x",$0)}.joined()
        guard final["ok"] as? Bool==true,let data=final["data"] as? [String:Any],data["bytes"] as? Int64==row.bytes,data["sha256"] as? String==sha,data["fingerprint"] as? String==row.fingerprint else{throw BridgeError(code:"export_verification_failed")}
        self.lock.lock();let process=self.child;self.lock.unlock();process?.waitUntilExit();guard process?.terminationStatus==0 else{throw BridgeError(code:"photo_read_failed")};self.close()
    }}
    func stop()async{try? await perform{self.close()}}
    deinit{cancel()}
}

enum PrivateMediaPreview {
    // Separate from public App Store icon policy; decoded thumbnails stay only in RAM.
    static func png(_ data:Data)->Data? {
        guard !data.isEmpty,data.count<=8*1024*1024,
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              (1...32).contains(CGImageSourceGetCount(source)),let type=CGImageSourceGetType(source) as String?,
              ["public.png","public.jpeg","public.heic","public.heif","public.tiff","com.adobe.raw-image","com.compuserve.gif","public.avif"].contains(type),
              let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=20000,height<=20000,Int64(width)*Int64(height)<=120_000_000,
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:320,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{return nil}
        let buffer=NSMutableData();guard let destination=CGImageDestinationCreateWithData(buffer,UTType.png.identifier as CFString,1,nil) else{return nil};CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination),buffer.length<=2*1024*1024 else{return nil};return buffer as Data
    }
}
