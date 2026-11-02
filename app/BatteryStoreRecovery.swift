import Foundation
import SQLite3
import CryptoKit
import Darwin

// Private native SQLite snapshots for schema/import rollback. No scheduler, deletion or public backup.
enum BatteryStoreRecovery {
    static func snapshot(connection:OpaquePointer,directory:URL,reason:String)throws {
        let folder=directory.appendingPathComponent("Recovery")
        guard folder.standardizedFileURL.path==folder.resolvingSymlinksInPath().path else{throw BatteryFailure.unsafePath}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var metadata=stat();guard lstat(folder.path,&metadata)==0,metadata.st_uid==getuid(),metadata.st_mode & S_IFMT==S_IFDIR else{throw BatteryFailure.unsafePath}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        guard try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter({$0.pathExtension=="sqlite"}).count<3 else{throw BatteryFailure.recoveryLimit}
        let id=UUID().uuidString,path=folder.appendingPathComponent("before-"+reason+"-"+id+".sqlite")
        let fd=open(path.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600);guard fd>=0 else{throw BatteryFailure.unsafePath};close(fd)
        let before=try logical(connection);var target:OpaquePointer?
        guard sqlite3_open_v2(path.path,&target,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK,let target else{throw BatteryFailure.database}
        var closed=false;defer{if !closed{sqlite3_close(target)}}
        guard sqlite3_exec(target,"PRAGMA synchronous=FULL; PRAGMA fullfsync=ON",nil,nil,nil)==SQLITE_OK,let backup=sqlite3_backup_init(target,"main",connection,"main") else{throw BatteryFailure.database}
        let code=sqlite3_backup_step(backup,-1),finish=sqlite3_backup_finish(backup)
        guard code==SQLITE_DONE,finish==SQLITE_OK,try logical(target)==before,try logical(connection)==before,try integrity(target) else{throw BatteryFailure.database}
        guard sqlite3_close(target)==SQLITE_OK else{throw BatteryFailure.database};closed=true
        let bytes=try Data(contentsOf:path),attributes=try FileManager.default.attributesOfItem(atPath:path.path)
        guard !bytes.isEmpty,bytes.count<=64*1024*1024,(attributes[.size] as? NSNumber)?.intValue==bytes.count else{throw BatteryFailure.database}
        let sha=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        guard SHA256.hash(data:try Data(contentsOf:path)).map({String(format:"%02x",$0)}).joined()==sha else{throw BatteryFailure.database}
        let receipt:[String:Any]=["schema":1,"component":"battery-history-recovery","reason":reason,"snapshot":path.lastPathComponent,"files":1,"bytes":bytes.count,"sha256":sha,"logical_source_and_snapshot_verified":true,"sqlite_integrity":true,"source_deleted":false,"complete":true]
        let receiptPath=folder.appendingPathComponent(path.lastPathComponent+".json")
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:receiptPath,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptPath.path)
    }
    static func integrity(_ db:OpaquePointer)throws->Bool{var p:OpaquePointer?;guard sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&p,nil)==SQLITE_OK,let p else{throw BatteryFailure.database};defer{sqlite3_finalize(p)};return sqlite3_step(p)==SQLITE_ROW && sqlite3_column_text(p,0).map{String(cString:$0)}=="ok"}
    private static func logical(_ db:OpaquePointer)throws->String {
        var hash=SHA256()
        for table in ["devices","samples","historical_samples","device_aliases","device_passports","technical_snapshots"] {
            var exists:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",-1,&exists,nil)==SQLITE_OK,let exists else{throw BatteryFailure.database}
            sqlite3_bind_text(exists,1,table,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self));let has=sqlite3_step(exists)==SQLITE_ROW && sqlite3_column_int(exists,0)>0;sqlite3_finalize(exists);if !has{continue}
            hash.update(data:Data(table.utf8));var p:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT * FROM "+table+" ORDER BY rowid",-1,&p,nil)==SQLITE_OK,let p else{throw BatteryFailure.database};defer{sqlite3_finalize(p)}
            var step=sqlite3_step(p)
            while step==SQLITE_ROW{for i in 0..<sqlite3_column_count(p){let type=sqlite3_column_type(p,i),count=sqlite3_column_bytes(p,i);hash.update(data:Data((String(type)+":"+String(count)+":").utf8));if let blob=sqlite3_column_blob(p,i),count>0{hash.update(data:Data(bytes:blob,count:Int(count)))}};step=sqlite3_step(p)}
            guard step==SQLITE_DONE else{throw BatteryFailure.database}
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
}
