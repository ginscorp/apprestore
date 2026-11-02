import Foundation
import CryptoKit
import Darwin

struct PublicBackupFile: Codable { let path:String; let sha256:String; let bytes:Int64; let object:String }
struct PublicBackupManifest: Codable { var schema=1; var component="apprestore-public-cache"; let files:[PublicBackupFile] }
enum PublicLibraryBackup {
    static let budget:Int64=5*1024*1024*1024
    static func digest(_ url:URL)throws->(String,Int64){
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true else{throw BridgeError(code:"unsafe_backup_path")}
        let h=try FileHandle(forReadingFrom:url);defer{try? h.close()};var sha=SHA256();var count:Int64=0
        while let b=try h.read(upToCount:1024*1024),!b.isEmpty{sha.update(data:b);count+=Int64(b.count)}
        return(sha.finalize().map{String(format:"%02x",$0)}.joined(),count)
    }
    static func run(source:URL) async ->String {
        guard !PublicEdition.preview else { return "Демонстрация: резервирование отключено" }
        guard let raw=ProcessInfo.processInfo.environment["APPRESTORE_LIBRARY_BACKUP_DIR"],raw.hasPrefix("/"),!raw.isEmpty else {
            return "Резервирование не настроено: выбери папку назначения"
        }
        let destination=URL(fileURLWithPath:raw,isDirectory:true).standardizedFileURL
        return await Task.detached(priority:.utility){
            let expected=PublicEdition.dataRoot.appendingPathComponent("Library").standardizedFileURL
            guard source.standardizedFileURL.path==expected.path,
                  destination.path != source.path,
                  !destination.path.hasPrefix(source.path+"/"),
                  !source.path.hasPrefix(destination.path+"/"),
                  destination.resolvingSymlinksInPath().path==destination.path else {
                return "Путь резервной копии требует проверки"
            }
            do {
                let parent=destination.deletingLastPathComponent()
                let values=try parent.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
                return try copyLibrary(source:source,destination:destination,capacity:values.volumeAvailableCapacityForImportantUsage ?? 0)
            } catch {
                let code=(error as? BridgeError)?.code ?? "filesystem_\((error as NSError).code)"
                return code=="backup_changed_source" ? "Сведения обновляются: повтори резервирование позже" : "Резервная копия не подтверждена [\(code)]"
            }
        }.value
    }
    // Called only after the production root/volume checks; separate for isolated fault tests.
    static func copyLibrary(source:URL,destination:URL,capacity:Int64,beforeCopy:(()throws->Void)?=nil)throws->String {
        let fm=FileManager.default
        guard source.resolvingSymlinksInPath().path==source.standardizedFileURL.path,
              destination.resolvingSymlinksInPath().path==destination.standardizedFileURL.path else{throw BridgeError(code:"unsafe_backup_root")}
    try fm.createDirectory(at:source,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let lockURL=source.deletingLastPathComponent().appendingPathComponent(".public-backup.lock")
    let fd=open(lockURL.path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard fd>=0 else{return "Не удалось открыть блокировку резервирования"};defer{close(fd)}
    guard flock(fd,LOCK_EX|LOCK_NB)==0 else{return "Резервирование уже выполняется"};defer{flock(fd,LOCK_UN)}
    let entries=try collect(source)
    guard !entries.isEmpty else{return "Библиотека еще пуста · копирование не требуется"}
    let sourceBytes=entries.reduce(Int64(0)){$0+$1.bytes}
    guard sourceBytes<=budget else{return "Библиотека превышает лимит резервирования"}
    let plan:[String:Any]=["schema":1,"component":"apprestore-public-cache","planned_count":entries.count,"planned_bytes":sourceBytes,"destination":destination.path,"deletion":false]
    try JSONSerialization.data(withJSONObject:plan,options:.sortedKeys).write(to:source.deletingLastPathComponent().appendingPathComponent("backup-plan.json"),options:.atomic)
    guard ["objects","manifests"].allSatisfy({let u=destination.appendingPathComponent($0);return u.resolvingSymlinksInPath().path==u.standardizedFileURL.path}) else{throw BridgeError(code:"unsafe_backup_directory")}
    try fm.createDirectory(at:destination.appendingPathComponent("objects"),withIntermediateDirectories:true)
    try fm.createDirectory(at:destination.appendingPathComponent("manifests"),withIntermediateDirectories:true)
    let pending=try fm.contentsOfDirectory(atPath:destination.path).filter{$0.hasPrefix(".incoming-")}
    guard pending.isEmpty else{return "Есть незавершенная копия · нужна проверка перед повтором"}
    let existing=try fm.contentsOfDirectory(at:destination.appendingPathComponent("objects"),includingPropertiesForKeys:[.fileSizeKey])
    let occupied=try existing.reduce(Int64(0)){try $0+Int64($1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)}
    let missing=entries.filter{!fm.fileExists(atPath:destination.appendingPathComponent($0.object).path)}
    let uniqueMissing=Dictionary(grouping:missing,by:{$0.object}).values.compactMap{$0.first}
    let needed=uniqueMissing.reduce(Int64(0)){$0+$1.bytes}
    guard occupied+needed<=budget,existing.count+uniqueMissing.count<=20000 else{return "Резервный кеш заполнен · требуется проверка места"}
    guard capacity>needed+512*1024*1024 else{return "В папке назначения недостаточно свободного места"}
    try beforeCopy?()
    for e in entries {
        let src=source.appendingPathComponent(e.path),dst=destination.appendingPathComponent(e.object)
        if !fm.fileExists(atPath:dst.path) {
            let incoming=destination.appendingPathComponent(".incoming-"+UUID().uuidString)
            if e.path == "metadata.json" {
                let snapshot=try Data(contentsOf:src)
                let sha=SHA256.hash(data:snapshot).map{String(format:"%02x",$0)}.joined()
                guard sha==e.sha256,Int64(snapshot.count)==e.bytes else{throw BridgeError(code:"backup_changed_source")}
                try snapshot.write(to:incoming,options:.atomic)
            } else { try fm.copyItem(at:src,to:incoming) }
            let copy=try digest(incoming);guard copy.0==e.sha256,copy.1==e.bytes else{throw BridgeError(code:"backup_copy_mismatch")}
            try fm.moveItem(at:incoming,to:dst)
        }
        let current=try digest(src),saved=try digest(dst)
        guard current.0==e.sha256,current.1==e.bytes,saved.0==e.sha256,saved.1==e.bytes else{throw BridgeError(code:"backup_changed_source")}
    }
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let manifest=try encoder.encode(PublicBackupManifest(files:entries))
    let hash=SHA256.hash(data:manifest).map{String(format:"%02x",$0)}.joined()
    let path=destination.appendingPathComponent("manifests/\(hash).json")
    if !fm.fileExists(atPath:path.path) {
        let old=try fm.contentsOfDirectory(atPath:destination.appendingPathComponent("manifests").path)
        guard old.count<256 else{return "Сохранено 256 состояний · требуется проверка истории резервов"}
        try manifest.write(to:path,options:.atomic)
    }
    guard try Data(contentsOf:path)==manifest else{throw BridgeError(code:"backup_manifest_mismatch")}
    let receipt:[String:Any]=["schema":1,"component":"apprestore-public-cache","status":"verified","checked_at":ISO8601DateFormatter().string(from:Date()),"manifest":hash,"count":entries.count,"bytes":sourceBytes,"all_sha256_verified":true,"secrets_included":false,"deletion":false]
    let data=try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted])
    try data.write(to:destination.appendingPathComponent("latest.json"),options:.atomic)
    try data.write(to:source.deletingLastPathComponent().appendingPathComponent("backup-receipt.json"),options:.atomic)
    guard try Data(contentsOf:destination.appendingPathComponent("latest.json"))==data else{throw BridgeError(code:"backup_receipt_mismatch")}
    return "Резервная копия · проверено \(entries.count) файлов"
    }
    static func collect(_ source:URL)throws->[PublicBackupFile]{
        let fm=FileManager.default;var entries:[PublicBackupFile]=[]
        func append(_ path:String)throws{
            let url=source.appendingPathComponent(path)
            let value=try digest(url);let ext=url.pathExtension
            entries.append(PublicBackupFile(path:path,sha256:value.0,bytes:value.1,object:"objects/\(value.0).\(ext)"))
        }
        let meta=source.appendingPathComponent("metadata.json")
        if fm.fileExists(atPath:meta.path) {
            let identity=try digest(meta);guard identity.1<=4*1024*1024 else{throw BridgeError(code:"invalid_public_index")};let data=try Data(contentsOf:meta);guard data.count<=4*1024*1024 else{throw BridgeError(code:"invalid_public_index")}
            let parsed=try JSONDecoder().decode(MediaIndex.self,from:data)
            guard parsed.schema==1,parsed.apps.count<=2000,parsed.versions.values.allSatisfy({$0.count<=32}) else{throw BridgeError(code:"invalid_public_index")}
            if let presence=parsed.lookupPresence {
                guard presence.count<=2000,presence.keys.allSatisfy({$0.range(of:"^[0-9]{1,11}$",options:.regularExpression) != nil && parsed.lookupChecked[$0] != nil}) else{throw BridgeError(code:"invalid_public_presence")}
            }
            // Unknown top-level fields cannot silently become a secret backup.
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(object.keys).isSubset(of:["schema","apps","versions","lookupChecked","lookupPresence"]) else{throw BridgeError(code:"unknown_public_index_fields")}
            let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(parsed)) as? [String:Any]
            guard let canonical, NSDictionary(dictionary:object).isEqual(to:canonical) else{throw BridgeError(code:"unexpected_public_index_fields")}
            try append("metadata.json")
        }
        let icons=source.appendingPathComponent("icons")
        if fm.fileExists(atPath:icons.path) {
            guard icons.resolvingSymlinksInPath().path==icons.standardizedFileURL.path else{throw BridgeError(code:"unsafe_icon_directory")}
            let files=try fm.contentsOfDirectory(at:icons,includingPropertiesForKeys:nil)
            guard files.count<=2000 else{throw BridgeError(code:"icon_budget")}
            for file in files where file.lastPathComponent.range(of:"^[0-9]{1,11}\\.png$",options:.regularExpression) != nil {
                let identity=try digest(file);guard identity.1<=2*1024*1024 else{throw BridgeError(code:"invalid_icon")};let data=try Data(contentsOf:file);guard PublicMediaPolicy.normalizedPNG(data) != nil else{throw BridgeError(code:"invalid_icon")};try append("icons/"+file.lastPathComponent)
            }
        }
        let packages=source.appendingPathComponent("packages")
        if fm.fileExists(atPath:packages.path) {
            guard packages.resolvingSymlinksInPath().path==packages.standardizedFileURL.path else{throw BridgeError(code:"unsafe_package_directory")}
            let files=try fm.contentsOfDirectory(at:packages,includingPropertiesForKeys:nil)
            let indices=files.filter{$0.lastPathComponent.range(of:"^[a-f0-9]{64}\\.json$",options:.regularExpression) != nil}
            guard indices.count<=16 else{throw BridgeError(code:"package_budget")}
            for file in indices {
                let identity=try digest(file);guard identity.1<=4096 else{throw BridgeError(code:"invalid_raw_index")};let data=try Data(contentsOf:file);guard data.count<=4096,let m=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(m.keys)==Set(["app_id","platform","md5","sha256","bytes"]),let sha=m["sha256"] as? String,let bytes=m["bytes"] as? Int64,bytes>0,let id=m["app_id"] as? Int64,id>0,let platform=m["platform"] as? String,["iphone","ipad"].contains(platform),let md=m["md5"] as? String,md.range(of:"^[a-fA-F0-9]{32}$",options:.regularExpression) != nil else{throw BridgeError(code:"invalid_raw_index")}
                let name=file.deletingPathExtension().lastPathComponent+".rawipa";let raw=packages.appendingPathComponent(name)
                let checked=try digest(raw);guard checked.0==sha,checked.1==bytes else{throw BridgeError(code:"invalid_raw_payload")}
                try append("packages/"+file.lastPathComponent);try append("packages/"+name)
            }
        }
        return entries.sorted{$0.path<$1.path}
    }
}
