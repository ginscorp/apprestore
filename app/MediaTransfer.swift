import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum MediaIntegrity {
    static func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func encoded<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(value)}
    static func name(_ value:String)->Bool {!value.isEmpty && value.utf8.count<=240 && !value.hasPrefix(".") && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains(where:{$0.value<32})}
    static func hex(_ value:String,_ count:Int=64)->Bool {value.count==count && value.allSatisfy{"0123456789abcdef".contains($0)}}
    static func canonical(_ url:URL)->Bool {url.isFileURL && url.resolvingSymlinksInPath().path==url.standardizedFileURL.path}
    static func hashFile(_ url:URL)throws->String {guard canonical(url) else{throw BridgeError(code:"unsafe_export_path")};return try PhotoExportJob.hash(url)}
    static func regular(_ url:URL)throws->Int64 {
        guard canonical(url),let attrs=try? FileManager.default.attributesOfItem(atPath:url.path),attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.referenceCount] as? NSNumber)?.intValue==1,(attrs[.ownerAccountID] as? NSNumber)?.uint32Value==geteuid(),
              let size=attrs[.size] as? NSNumber else{throw BridgeError(code:"unsafe_export_path")}
        return size.int64Value
    }
}

struct MediaSource:Codable,Hashable,Sendable,Identifiable {
    let name:String
    let devicePath:String
    let bytes:Int64
    let created:Date?
    let modified:Date?
    var group:String
    var id:String {
        struct Identity:Encodable {let name:String;let devicePath:String;let bytes:Int64;let created:Date?;let modified:Date?}
        return MediaIntegrity.sha((try? MediaIntegrity.encoded(Identity(name:name,devicePath:devicePath,bytes:bytes,created:created,modified:modified))) ?? Data())
    }
    var relative:String {"Originals/"+group+"/"+name}
    var fileExtension:String {URL(fileURLWithPath:name).pathExtension.lowercased()}
    var kind:String {
        if ["heic","heif","jpg","jpeg","png","gif","tif","tiff","dng","raw","cr2","arw","jxl","avif"].contains(fileExtension){return "image"}
        if ["mov","mp4","m4v"].contains(fileExtension){return "video"}
        return "other"
    }
    func validate()throws {
        guard MediaIntegrity.name(name),devicePath.utf8.count<=2048,!devicePath.contains("\0"),bytes>0,bytes<=64*1024*1024*1024,
              MediaIntegrity.hex(group,32),["image","video"].contains(kind) || ["aae","xmp","wav","m4a","mp3","aac","aif","aiff"].contains(fileExtension),
              [created,modified].compactMap({$0}).allSatisfy({$0.timeIntervalSince1970.isFinite}) else{throw BridgeError(code:"invalid_media_plan")}
    }
}
enum MediaGrouping {
    static func plan(_ sources:[MediaSource],selected:Set<String>,groups:[String:String],related:[String:[String]])throws->[MediaSource] {
        guard sources.count<=200000,selected.count<=10000 else{throw BridgeError(code:"invalid_media_plan")}
        let sourceMap=Dictionary(sources.map{($0.id,$0)},uniquingKeysWith:{$1})
        var byGroup:[String:[String]]=[:],byStem:[String:[String]]=[:]
        for source in sources {
            if let group=groups[source.id],!group.isEmpty,group.utf8.count<=256{byGroup[group,default:[]].append(source.id)}
            byStem[(source.devicePath as NSString).deletingPathExtension.lowercased(),default:[]].append(source.id)
        }
        var union:[String:String]=[:],chosen=Set<String>()
        func root(_ id:String)->String{var cursor=id;while let parent=union[cursor],parent != cursor{cursor=parent};return cursor}
        func link(_ a:String,_ b:String){let ra=root(a),rb=root(b);if ra != rb{union[max(ra,rb)]=min(ra,rb)}}
        var queue=selected.sorted(),queued=selected,usedGroups=Set<String>(),usedStems=Set<String>(),index=0
        while index<queue.count {
            let id=queue[index];index+=1
            guard let source=sourceMap[id],(related[id]?.count ?? 0)<=64 else{throw BridgeError(code:"source_changed")}
            chosen.insert(id)
            var members=related[id] ?? []
            if let group=groups[id],usedGroups.insert(group).inserted {
                let peers=byGroup[group] ?? []
                guard peers.count<=10000 else{throw BridgeError(code:"invalid_media_plan")};members+=peers
            }
            let stem=(source.devicePath as NSString).deletingPathExtension.lowercased()
            if usedStems.insert(stem).inserted {
                let siblings=byStem[stem] ?? []
                if source.kind=="image" || siblings.contains(where:{sourceMap[$0]?.kind=="image"}) {
                    guard siblings.count<=10000 else{throw BridgeError(code:"invalid_media_plan")};members+=siblings
                }
            }
            for member in members where sourceMap[member] != nil {
                link(id,member);chosen.insert(member)
                if queued.insert(member).inserted {queue.append(member)}
                guard queue.count<=10000 else{throw BridgeError(code:"invalid_media_plan")}
            }
        }
        let result=chosen.sorted().compactMap{id->MediaSource? in guard var source=sourceMap[id] else{return nil};source.group=String(root(id).prefix(32));return source}
        try OriginalMediaJob.validateSources(result)
        return result
    }
}
struct MediaCopyRecord:Codable,Sendable {
    let sourceID:String
    let path:String
    let bytes:Int64
    let sha256:String
    let kind:String
    let sourceSHA256:String
    let verifiedAt:Date
}
struct MediaCopyReceipt:Codable,Sendable {
    var schema=2
    var component="apprestore-original-media"
    let jobID:String
    let deviceFingerprint:String
    let sources:[MediaSource]
    let jpegCopies:Bool
    var status="incomplete"
    var files:[MediaCopyRecord]=[]
    var partial:[String:Int64]=[:]
    var bytes:Int64=0
    var count=0
    var sourceDeleted=false
}
final class MediaCancellation:@unchecked Sendable {
    private let lock=NSLock()
    private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    func check()throws{lock.lock();let current=value;lock.unlock();if current{throw BridgeError(code:"operation_cancelled")}}
}

final class OriginalMediaJob:@unchecked Sendable {
    let root:URL
    private(set) var receipt:MediaCopyReceipt
    static func fingerprint(_ udid:String)->String {MediaIntegrity.sha(Data(("AppRestore-media-device:"+udid.lowercased()).utf8))}
    static func validateSources(_ sources:[MediaSource])throws {
        guard !sources.isEmpty,sources.count<=10000 else{throw BridgeError(code:"invalid_media_plan")}
        var paths=Set<String>(),ids=Set<String>(),bytes:Int64=0
        for source in sources {
            try source.validate()
            guard paths.insert(source.relative.precomposedStringWithCanonicalMapping.lowercased()).inserted,ids.insert(source.id).inserted else{throw BridgeError(code:"ambiguous_media_names")}
            bytes+=source.bytes
            guard bytes<=256*1024*1024*1024 else{throw BridgeError(code:"transfer_size_limit")}
        }
    }
    init(parent:URL,sources:[MediaSource],device:String,jpeg:Bool)throws {
        try Self.validateSources(sources)
        let p=parent.standardizedFileURL.path
        guard MediaIntegrity.canonical(parent),!p.hasPrefix("/Applications"),
              !p.hasPrefix(FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AppRestore").path),
              !p.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path) else{throw BridgeError(code:"unsafe_export_path")}
        let id=UUID().uuidString
        root=parent.appendingPathComponent("AppRestore-Photos-"+id,isDirectory:true)
        receipt=MediaCopyReceipt(jobID:id,deviceFingerprint:Self.fingerprint(device),sources:sources,jpegCopies:jpeg)
        try Self.checkSpace(parent,need:sources.reduce(0){$0+$1.bytes})
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try save()
    }
    init(resuming root:URL,device:String)throws {
        guard MediaIntegrity.canonical(root),root.lastPathComponent.hasPrefix("AppRestore-Photos-"),
              !root.path.hasPrefix("/Applications/"),!root.path.hasPrefix(NSHomeDirectory()+"/Library/Application Support/AppRestorePublic/"),
              !root.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path) else{throw BridgeError(code:"invalid_media_receipt")}
        let receiptURL=root.appendingPathComponent("receipt.json")
        let size=try MediaIntegrity.regular(receiptURL)
        guard size<=8*1024*1024 else{throw BridgeError(code:"invalid_media_receipt")}
        let value=try JSONDecoder().decode(MediaCopyReceipt.self,from:Data(contentsOf:receiptURL))
        guard value.schema==2,value.component=="apprestore-original-media",UUID(uuidString:value.jobID) != nil,
              root.lastPathComponent=="AppRestore-Photos-"+value.jobID,value.deviceFingerprint==Self.fingerprint(device),
              ["incomplete","verified"].contains(value.status),!value.sourceDeleted,value.files.count<=20000,value.partial.count<=10000 else{throw BridgeError(code:"media_device_mismatch")}
        try Self.validateSources(value.sources)
        self.root=root;receipt=value
        let attrs=try FileManager.default.attributesOfItem(atPath:root.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value==geteuid(),((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o077==0 else{throw BridgeError(code:"unsafe_export_path")}
        let sources=Dictionary(uniqueKeysWithValues:value.sources.map{($0.id,$0)})
        var paths=Set<String>()
        for record in value.files {
            guard let source=sources[record.sourceID],["original","jpeg"].contains(record.kind),MediaIntegrity.hex(record.sha256),
                  MediaIntegrity.hex(record.sourceSHA256),record.bytes>=0,record.bytes<=64*1024*1024*1024,
                  record.path==(record.kind=="original" ? source.relative:Self.jpegPath(source)),paths.insert(record.path).inserted else{throw BridgeError(code:"invalid_media_receipt")}
        }
        for (id,bytes) in value.partial {guard let source=sources[id],bytes>=0,bytes<=source.bytes else{throw BridgeError(code:"invalid_media_receipt")}}
    }
    static func checkSpace(_ folder:URL,need:Int64=0)throws {
        let free=(try FileManager.default.attributesOfFileSystem(forPath:folder.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free>need+512*1024*1024 else{throw BridgeError(code:"insufficient_disk_space")}
    }
    func save()throws {
        let data=try MediaIntegrity.encoded(receipt)
        guard data.count<=8*1024*1024 else{throw BridgeError(code:"invalid_media_receipt")}
        let url=root.appendingPathComponent("receipt.json")
        guard MediaIntegrity.canonical(root),MediaIntegrity.canonical(url) else{throw BridgeError(code:"unsafe_export_path")}
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func begin()throws{receipt.status="incomplete";try save()}
    func output(_ path:String)throws->URL {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard parts.count==3,["Originals","JPEG"].contains(parts[0]),MediaIntegrity.hex(parts[1],32),MediaIntegrity.name(parts[2]),MediaIntegrity.canonical(root) else{throw BridgeError(code:"unsafe_export_path")}
        let folder=root.appendingPathComponent(parts[0],isDirectory:true).appendingPathComponent(parts[1],isDirectory:true)
        guard MediaIntegrity.canonical(folder) else{throw BridgeError(code:"unsafe_export_path")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=folder.appendingPathComponent(parts[2])
        guard MediaIntegrity.canonical(url) else{throw BridgeError(code:"unsafe_export_path")}
        return url
    }
    func checkpoint(_ source:MediaSource,bytes:Int64)throws{receipt.partial[source.id]=bytes;try save()}
    func record(_ source:MediaSource,path:String,sha:String,kind:String,sourceSHA:String)throws {
        let url=try output(path),bytes=try MediaIntegrity.regular(url)
        guard try MediaIntegrity.hashFile(url)==sha else{throw BridgeError(code:"export_verification_failed")}
        receipt.files.removeAll{$0.path==path}
        receipt.files.append(MediaCopyRecord(sourceID:source.id,path:path,bytes:bytes,sha256:sha,kind:kind,sourceSHA256:sourceSHA,verifiedAt:Date()))
        if kind=="original"{receipt.partial.removeValue(forKey:source.id)}
        receipt.bytes=receipt.files.reduce(0){$0+$1.bytes};receipt.count=receipt.files.count
        guard receipt.bytes<=512*1024*1024*1024 else{throw BridgeError(code:"transfer_size_limit")}
        try save()
    }
    func restoreDates(_ url:URL,source:MediaSource)throws {
        var dates:[FileAttributeKey:Any]=[.posixPermissions:0o600]
        if let created=source.created{dates[.creationDate]=created}
        if let modified=source.modified{dates[.modificationDate]=modified}
        try FileManager.default.setAttributes(dates,ofItemAtPath:url.path)
    }
    static func jpegPath(_ source:MediaSource)->String {
        "JPEG/"+source.group+"/"+source.id.prefix(10)+"-"+String(URL(fileURLWithPath:source.name).deletingPathExtension().lastPathComponent.prefix(50))+".jpg"
    }
    func jpeg(_ source:MediaSource,sourceSHA:String)throws {
        guard receipt.jpegCopies,["heic","heif"].contains(source.fileExtension) else{return}
        let original=try output(source.relative),path=Self.jpegPath(source),destination=try output(path)
        if FileManager.default.fileExists(atPath:destination.path) {
            guard let record=receipt.files.first(where:{$0.path==path}),record.sourceSHA256==sourceSHA,
                  try MediaIntegrity.regular(destination)==record.bytes,try MediaIntegrity.hashFile(destination)==record.sha256 else{throw BridgeError(code:"unverified_derived_file")}
            return
        }
        try Self.checkSpace(root,need:min(source.bytes*3,256*1024*1024))
        try JPEGCopy.create(from:original,to:destination)
        try restoreDates(destination,source:source)
        try record(source,path:path,sha:MediaIntegrity.hashFile(destination),kind:"jpeg",sourceSHA:sourceSHA)
    }
    func finish()throws {
        for source in receipt.sources {
            guard let row=receipt.files.first(where:{$0.path==source.relative && $0.kind=="original"}),row.bytes==source.bytes else{throw BridgeError(code:"incomplete_export")}
            if receipt.jpegCopies && ["heic","heif"].contains(source.fileExtension){guard receipt.files.contains(where:{$0.path==Self.jpegPath(source) && $0.sourceSHA256==row.sha256}) else{throw BridgeError(code:"incomplete_export")}}
        }
        for row in receipt.files {let url=try output(row.path);guard try MediaIntegrity.regular(url)==row.bytes,try MediaIntegrity.hashFile(url)==row.sha256 else{throw BridgeError(code:"export_verification_failed")}}
        receipt.status="verified";try save()
    }
}

enum JPEGCopy {
    static func create(from input:URL,to output:URL)throws {
        guard MediaIntegrity.canonical(input),MediaIntegrity.canonical(output),!FileManager.default.fileExists(atPath:output.path),
              try MediaIntegrity.regular(input)<=512*1024*1024,
              let source=CGImageSourceCreateWithURL(input as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let type=CGImageSourceGetType(source) as String?,["public.heic","public.heif"].contains(type),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=20000,height<=20000,Int64(width)*Int64(height)<=120000000 else{throw BridgeError(code:"unsupported_heic")}
        let fd=open(output.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else{throw BridgeError(code:"export_exists")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()}
        let buffer=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(buffer,UTType.jpeg.identifier as CFString,1,nil) else{throw BridgeError(code:"jpeg_conversion_failed")}
        CGImageDestinationAddImageFromSource(destination,source,0,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination),buffer.length>0,buffer.length<=256*1024*1024 else{throw BridgeError(code:"jpeg_conversion_failed")}
        try handle.write(contentsOf:Data(referencing:buffer));try handle.synchronize()
        guard let check=CGImageSourceCreateWithURL(output as CFURL,nil),
              let target=CGImageSourceCopyPropertiesAtIndex(check,0,nil) as? [CFString:Any],
              target[kCGImagePropertyPixelWidth] as? Int==width,target[kCGImagePropertyPixelHeight] as? Int==height else{throw BridgeError(code:"jpeg_conversion_failed")}
    }
}

actor MediaCopyWorker {
    func run(_ job:OriginalMediaJob,cancel:MediaCancellation,
             read:@escaping @Sendable (String,Int64,Int)async throws->Data,
             validate:@escaping @Sendable (String)async throws->Void,
             progress:@escaping @Sendable (Double)->Void)async throws {
        try job.begin()
        let sources=job.receipt.sources,total=sources.reduce(Int64(0)){$0+$1.bytes}
        var readBytes:Int64=0
        for source in sources {
            try cancel.check();try await validate(source.id)
            let output=try job.output(source.relative),exists=FileManager.default.fileExists(atPath:output.path)
            let existing=exists ? try MediaIntegrity.regular(output):0
            guard existing<=source.bytes else{throw BridgeError(code:"source_changed")}
            if exists {
                guard job.receipt.partial[source.id] != nil || job.receipt.files.contains(where:{$0.path==source.relative}) else{throw BridgeError(code:"unverified_existing_file")}
            }else{try job.checkpoint(source,bytes:0)}
            let fd=open(output.path,O_RDWR|O_NOFOLLOW|(exists ? O_APPEND:O_CREAT|O_EXCL),0o600)
            guard fd>=0 else{throw BridgeError(code:"unsafe_export_path")}
            let writer=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            let verifier=existing>0 ? try FileHandle(forReadingFrom:output):nil
            var offset:Int64=0,hash=SHA256(),checkpoint=existing
            do {
                while offset<source.bytes {
                    try cancel.check()
                    let count=Int(min(1024*1024,offset<existing ? existing-offset:source.bytes-offset))
                    let chunk=try await read(source.id,offset,count)
                    guard !chunk.isEmpty,chunk.count<=count else{throw BridgeError(code:"photo_read_failed")}
                    if offset<existing {
                        guard let saved=try verifier?.read(upToCount:chunk.count),saved==chunk else{throw BridgeError(code:"media_prefix_mismatch")}
                    }else {
                        try OriginalMediaJob.checkSpace(job.root)
                        try writer.write(contentsOf:chunk)
                    }
                    hash.update(data:chunk);offset+=Int64(chunk.count);readBytes+=Int64(chunk.count)
                    if offset>=existing && offset-checkpoint>=8*1024*1024 {
                        try writer.synchronize();try job.checkpoint(source,bytes:offset);checkpoint=offset
                    }
                    progress(Double(readBytes)/Double(total))
                }
                try writer.synchronize();try writer.close();try verifier?.close()
            }catch {
                try? writer.synchronize();try? writer.close();try? verifier?.close()
                if let actual=try? MediaIntegrity.regular(output){try? job.checkpoint(source,bytes:actual)}
                throw error
            }
            try await validate(source.id)
            let sha=hash.finalize().map{String(format:"%02x",$0)}.joined()
            try job.restoreDates(output,source:source)
            try job.record(source,path:source.relative,sha:sha,kind:"original",sourceSHA:sha)
            try cancel.check();try job.jpeg(source,sourceSHA:sha)
        }
        try job.finish()
    }
}
