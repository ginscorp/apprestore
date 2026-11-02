import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import CryptoKit
import Darwin

struct PhoneAlbumFile:Sendable {let url:URL;let name:String;let bytes:Int64;let modified:Date;let created:Date?;let sha256:String}
struct PhoneAlbumPlan:Sendable {let id:String;let parent:URL;let album:String;let deviceFingerprint:String;let deviceName:String;let files:[PhoneAlbumFile];var bytes:Int64{files.reduce(0){$0+$1.bytes}}}

actor PhoneAlbumBuilder {
    static func hash(_ url:URL,cancel:MediaCancellation)throws->String {
        _=try MediaIntegrity.regular(url)
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw BridgeError(code:"unsafe_local_file")};let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? file.close()}
        var hash=SHA256();while let data=try file.read(upToCount:1024*1024),!data.isEmpty{try cancel.check();hash.update(data:data)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    func plan(urls:[URL],parent:URL,album:String,device:String,name:String,cancel:MediaCancellation)async throws->PhoneAlbumPlan {
        guard !urls.isEmpty,urls.count<=2000,MediaIntegrity.name(album),album.utf8.count<=100,MediaIntegrity.canonical(parent),!device.isEmpty else{throw BridgeError(code:"invalid_album_plan")}
        let forbidden=["/Applications",PublicEdition.dataRoot.path,Bundle.main.bundleURL.standardizedFileURL.path]
        guard !forbidden.contains(where:{parent.path==$0 || parent.path.hasPrefix($0+"/")}) else{throw BridgeError(code:"private_data_in_public_folder")}
        var names=Set<String>(),files:[PhoneAlbumFile]=[],total:Int64=0
        for url in urls {
            try cancel.check();let filename=url.lastPathComponent,ext=url.pathExtension.lowercased(),bytes=try MediaIntegrity.regular(url)
            guard MediaIntegrity.name(filename),names.insert(filename.precomposedStringWithCanonicalMapping.lowercased()).inserted else{throw BridgeError(code:"ambiguous_media_names")}
            guard bytes>0,bytes<=32*1024*1024*1024 else{throw BridgeError(code:"transfer_size_limit")}
            if ["png","jpg","jpeg","heic","heif"].contains(ext){guard let image=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(image)>0 else{throw BridgeError(code:"unsupported_sync_media")}}
            else if ["mov","mp4","m4v"].contains(ext){guard try await AVURLAsset(url:url,options:[AVURLAssetReferenceRestrictionsKey:NSNumber(value:0xFFFF)]).load(.isPlayable) else{throw BridgeError(code:"unsupported_sync_media")}}
            else{throw BridgeError(code:"unsupported_sync_media")}
            let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard let modified=attrs[.modificationDate] as? Date else{throw BridgeError(code:"unsafe_local_file")}
            let sha=try Self.hash(url,cancel:cancel),after=try FileManager.default.attributesOfItem(atPath:url.path)
            guard try MediaIntegrity.regular(url)==bytes,after[.modificationDate] as? Date==modified else{throw BridgeError(code:"source_changed")}
            total+=bytes;guard total<=32*1024*1024*1024 else{throw BridgeError(code:"transfer_size_limit")}
            files.append(PhoneAlbumFile(url:url,name:filename,bytes:bytes,modified:modified,created:attrs[.creationDate] as? Date,sha256:sha))
        }
        try OriginalMediaJob.checkSpace(parent,need:total)
        return PhoneAlbumPlan(id:UUID().uuidString,parent:parent,album:album,deviceFingerprint:OriginalMediaJob.fingerprint(device),deviceName:name,files:files)
    }
    func build(_ plan:PhoneAlbumPlan,cancel:MediaCancellation,progress:@escaping @Sendable(Double)->Void)async throws->URL {
        try OriginalMediaJob.checkSpace(plan.parent,need:plan.bytes)
        let root=plan.parent.appendingPathComponent("AppRestore-USB-Album-"+plan.id),sync=root.appendingPathComponent("Sync"),album=sync.appendingPathComponent(plan.album)
        guard MediaIntegrity.canonical(root),!FileManager.default.fileExists(atPath:root.path) else{throw BridgeError(code:"export_exists")}
        try FileManager.default.createDirectory(at:album,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var records:[[String:Any]]=[],copied:Int64=0
        func receipt(_ state:String)throws {
            let obj:[String:Any]=["schema":1,"component":"apprestore-usb-album","state":state,"device_fingerprint":plan.deviceFingerprint,"files":records,"bytes":copied,"source_deleted":false,"shared_cache":false,"finder_sync_performed":false,"phone_import_verified":false,"sync_folder":"Sync","album":plan.album]
            let path=root.appendingPathComponent("receipt.json");try JSONSerialization.data(withJSONObject:obj,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        try receipt("incomplete")
        for item in plan.files {
            try cancel.check();let before=try FileManager.default.attributesOfItem(atPath:item.url.path)
            guard try MediaIntegrity.regular(item.url)==item.bytes,before[.modificationDate] as? Date==item.modified else{throw BridgeError(code:"source_changed")}
            let sourceFD=open(item.url.path,O_RDONLY|O_NOFOLLOW),target=album.appendingPathComponent(item.name)
            guard sourceFD>=0,MediaIntegrity.canonical(target) else{throw BridgeError(code:"unsafe_local_file")}
            let source=FileHandle(fileDescriptor:sourceFD,closeOnDealloc:true)
            let targetFD=open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard targetFD>=0 else{try? source.close();throw BridgeError(code:"export_exists")}
            let output=FileHandle(fileDescriptor:targetFD,closeOnDealloc:true)
            var size:Int64=0,hash=SHA256()
            do {
                while let data=try source.read(upToCount:1024*1024),!data.isEmpty{try cancel.check();try OriginalMediaJob.checkSpace(root);guard size+Int64(data.count)<=item.bytes else{throw BridgeError(code:"source_changed")};try output.write(contentsOf:data);hash.update(data:data);size+=Int64(data.count);progress(Double(copied+size)/Double(plan.bytes))}
                try output.synchronize();try output.close();try source.close()
            }catch{try? output.close();try? source.close();throw error}
            let sha=hash.finalize().map{String(format:"%02x",$0)}.joined(),after=try FileManager.default.attributesOfItem(atPath:item.url.path)
            guard size==item.bytes,sha==item.sha256,after[.modificationDate] as? Date==item.modified,try MediaIntegrity.hashFile(target)==item.sha256 else{throw BridgeError(code:"copy_verification_failed")}
            var dates:[FileAttributeKey:Any]=[.posixPermissions:0o600,.modificationDate:item.modified];if let date=item.created{dates[.creationDate]=date};try FileManager.default.setAttributes(dates,ofItemAtPath:target.path)
            copied+=size;records.append(["path":"Sync/"+plan.album+"/"+item.name,"bytes":size,"sha256":sha]);try receipt("incomplete")
        }
        try cancel.check()
        let written=try FileManager.default.contentsOfDirectory(at:album,includingPropertiesForKeys:nil)
        guard written.count==plan.files.count,copied==plan.bytes else{throw BridgeError(code:"copy_verification_failed")}
        for item in plan.files{let path=album.appendingPathComponent(item.name);guard try MediaIntegrity.regular(path)==item.bytes,try MediaIntegrity.hashFile(path)==item.sha256 else{throw BridgeError(code:"copy_verification_failed")}}
        try receipt("prepared_verified")
        return root
    }
}

