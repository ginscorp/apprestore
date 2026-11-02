import Foundation
import SQLite3
import Darwin

actor BatteryHistory {
    static var defaultDirectory:URL{PublicEdition.dataRoot.appendingPathComponent("BatteryHistory")}
    private let directory:URL
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(directory:URL=BatteryHistory.defaultDirectory){self.directory=directory}
    deinit{if let db{sqlite3_close(db)}}
    private func openStore()throws {
        if db != nil{return}
        guard directory.isFileURL,directory.standardizedFileURL.path==directory.resolvingSymlinksInPath().path else{throw BatteryFailure.unsafePath}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var statbuf=stat();guard lstat(directory.path,&statbuf)==0,statbuf.st_uid==getuid(),statbuf.st_mode & S_IFMT==S_IFDIR else{throw BatteryFailure.unsafePath}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let file=directory.appendingPathComponent("history.sqlite")
        if !FileManager.default.fileExists(atPath:file.path){let fd=Darwin.open(file.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600);guard fd>=0 else{throw BatteryFailure.unsafePath};Darwin.close(fd)}
        guard lstat(file.path,&statbuf)==0,statbuf.st_uid==getuid(),statbuf.st_nlink==1,statbuf.st_mode & S_IFMT==S_IFREG,statbuf.st_size<64*1024*1024 else{throw BatteryFailure.unsafePath}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else{sqlite3_close(db);db=nil;throw BatteryFailure.database}
        do{
            sqlite3_busy_timeout(db,3000)
            try exec("PRAGMA trusted_schema=OFF;")
            let version=try scalar("PRAGMA user_version"),app=try scalar("PRAGMA application_id")
            let tables=try scalar("SELECT count(*) FROM sqlite_master")
            guard (version==0 && app==0 && tables==0) || ([1,2].contains(version) && app==1095914068) else{throw BatteryFailure.unsupportedSchema}
            try exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA max_page_count=16384;")
            if version==1{try BatteryStoreRecovery.snapshot(connection:db!,directory:directory,reason:"schema-2")}
            try exec("BEGIN IMMEDIATE")
            do{
                try exec("CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,kind TEXT NOT NULL,name TEXT NOT NULL,model TEXT NOT NULL,system TEXT NOT NULL,tracking INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY,device_id TEXT NOT NULL REFERENCES devices(id),measured REAL NOT NULL,bucket INTEGER NOT NULL,pack TEXT NOT NULL,reading TEXT NOT NULL,UNIQUE(device_id,bucket,pack)); CREATE INDEX IF NOT EXISTS samples_device_date ON samples(device_id,measured); CREATE TABLE IF NOT EXISTS device_aliases(alias TEXT PRIMARY KEY,device_id TEXT NOT NULL REFERENCES devices(id)); CREATE TABLE IF NOT EXISTS historical_samples(id INTEGER PRIMARY KEY,device_id TEXT NOT NULL REFERENCES devices(id),measured REAL NOT NULL,pack TEXT NOT NULL,reading TEXT NOT NULL,sample_hash TEXT NOT NULL UNIQUE,source_sha TEXT NOT NULL); CREATE INDEX IF NOT EXISTS historical_device_date ON historical_samples(device_id,measured); CREATE TABLE IF NOT EXISTS device_passports(device_id TEXT PRIMARY KEY REFERENCES devices(id),updated REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS technical_snapshots(id INTEGER PRIMARY KEY,device_id TEXT NOT NULL REFERENCES devices(id),measured REAL NOT NULL,bucket INTEGER NOT NULL,digest TEXT NOT NULL,context TEXT NOT NULL,payload TEXT NOT NULL,UNIQUE(device_id,bucket,digest)); CREATE INDEX IF NOT EXISTS technical_device_date ON technical_snapshots(device_id,measured); PRAGMA application_id=1095914068; PRAGMA user_version=2;")
                try exec("COMMIT")
            }catch{try? exec("ROLLBACK");throw error}

        }catch{sqlite3_close(db);db=nil;throw error}
    }
    private func exec(_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw BatteryFailure.database}}
    private func statement(_ sql:String)throws->OpaquePointer {var p:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&p,nil)==SQLITE_OK,let p else{throw BatteryFailure.database};return p}
    private func text(_ p:OpaquePointer,_ index:Int32,_ value:String)throws {guard sqlite3_bind_text(p,index,value,-1,transient)==SQLITE_OK else{throw BatteryFailure.database}}
    private func string(_ p:OpaquePointer,_ index:Int32)->String{sqlite3_column_text(p,index).map{String(cString:$0)} ?? ""}
    private func scalar(_ sql:String)throws->Int64{let p=try statement(sql);defer{sqlite3_finalize(p)};guard sqlite3_step(p)==SQLITE_ROW else{throw BatteryFailure.database};return sqlite3_column_int64(p,0)}
    private func checked(_ device:BatteryDevice)throws{guard BatteryIdentity.valid(device.id),["mac","iphone"].contains(device.kind),device.name.utf8.count<=255,device.model.utf8.count<=100,device.system.utf8.count<=200,device.aliases.count<=8,device.aliases.allSatisfy(BatteryIdentity.valid) else{throw BatteryFailure.invalidReading}}
    func devices()throws->[BatteryDevice]{try openStore();let p=try statement("SELECT id,kind,name,model,system,tracking FROM devices ORDER BY kind DESC,name");defer{sqlite3_finalize(p)};var out:[BatteryDevice]=[];var step=sqlite3_step(p);while step==SQLITE_ROW{guard out.count<1000 else{throw BatteryFailure.historyLimit};out.append(BatteryDevice(id:string(p,0),kind:string(p,1),name:string(p,2),model:string(p,3),system:string(p,4),tracking:sqlite3_column_int(p,5)==1));step=sqlite3_step(p)};guard step==SQLITE_DONE else{throw BatteryFailure.database};return out}
    func setTracking(_ id:String,_ enabled:Bool)throws{try openStore();guard BatteryIdentity.valid(id) else{throw BatteryFailure.invalidReading};let p=try statement("UPDATE devices SET tracking=? WHERE id=?");defer{sqlite3_finalize(p)};sqlite3_bind_int(p,1,enabled ? 1:0);try text(p,2,id);guard sqlite3_step(p)==SQLITE_DONE else{throw BatteryFailure.database}}
    // Legacy column "bucket" is retained for compatibility; new captures use epoch milliseconds.
    // No timer writes history. Replaying the same capture is idempotent, reconnects are distinct.
    @discardableResult func record(_ snapshot:BatterySnapshot,tracking:Bool)throws->Bool {
        try openStore();try checked(snapshot.device);try snapshot.reading.validate();let resolved=try resolveDevice(snapshot.device);let known=try devices();guard known.contains(where:{$0.id==resolved.id}) || known.count<1000 else{throw BatteryFailure.historyLimit};guard snapshot.date.timeIntervalSince1970.isFinite,snapshot.date.timeIntervalSince1970>0,snapshot.date.timeIntervalSince1970<100_000_000_000 else{throw BatteryFailure.invalidReading}
        guard try scalar("SELECT (SELECT count(*) FROM samples)+(SELECT count(*) FROM historical_samples)+(SELECT count(*) FROM technical_snapshots)")<250000 else{throw BatteryFailure.historyLimit}
        try exec("BEGIN IMMEDIATE");do{
            let device=resolved,p=try statement("INSERT INTO devices VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,model=excluded.model,system=excluded.system,tracking=excluded.tracking")
            defer{sqlite3_finalize(p)}
            for (i,s) in [device.id,device.kind,device.name,device.model,device.system].enumerated(){try text(p,Int32(i+1),s)};sqlite3_bind_int(p,6,tracking ? 1:0);guard sqlite3_step(p)==SQLITE_DONE else{throw BatteryFailure.database}
            try registerAliases(device)
            var inserted=false
            if tracking {
                let q=try statement("INSERT OR IGNORE INTO samples(device_id,measured,bucket,pack,reading) VALUES(?,?,?,?,?)");defer{sqlite3_finalize(q)}
                try text(q,1,device.id);sqlite3_bind_double(q,2,snapshot.date.timeIntervalSince1970);sqlite3_bind_int64(q,3,Int64(snapshot.date.timeIntervalSince1970*1000));try text(q,4,snapshot.reading.pack_hash ?? "unknown");var stored=snapshot.reading;if stored.system_version==nil{stored.system_version=device.system};try text(q,5,String(decoding:try JSONEncoder().encode(stored),as:UTF8.self));guard sqlite3_step(q)==SQLITE_DONE else{throw BatteryFailure.database};inserted=sqlite3_changes(db)>0
            }
            try exec("COMMIT");return inserted
        }catch{try? exec("ROLLBACK");throw error}
    }
    func points(_ id:String)throws->[BatteryPoint]{try openStore();guard BatteryIdentity.valid(id) else{throw BatteryFailure.invalidReading};let p=try statement("SELECT id,measured,reading FROM samples WHERE device_id=? UNION ALL SELECT -id,measured,reading FROM historical_samples WHERE device_id=? ORDER BY measured DESC LIMIT 250000");defer{sqlite3_finalize(p)};try text(p,1,id);try text(p,2,id);var rows:[BatteryPoint]=[];var step=sqlite3_step(p);while step==SQLITE_ROW{guard let data=string(p,2).data(using:.utf8) else{throw BatteryFailure.database};let r=try JSONDecoder().decode(BatteryReading.self,from:data);try r.validate();rows.append(BatteryPoint(id:sqlite3_column_int64(p,0),date:Date(timeIntervalSince1970:sqlite3_column_double(p,1)),reading:r));step=sqlite3_step(p)};guard step==SQLITE_DONE else{throw BatteryFailure.database};return rows.reversed()}
    func integrity()throws->Bool{try openStore();let p=try statement("PRAGMA integrity_check");defer{sqlite3_finalize(p)};return sqlite3_step(p)==SQLITE_ROW && string(p,0)=="ok"}
    func resolveDevice(_ incoming:BatteryDevice)throws->BatteryDevice {
        try openStore();try checked(incoming);var targets=Set<String>()
        let known=try devices();if known.contains(where:{$0.id==incoming.id}){targets.insert(incoming.id)}
        for alias in Set(incoming.aliases+[incoming.id]){let p=try statement("SELECT device_id FROM device_aliases WHERE alias=?");try text(p,1,alias);if sqlite3_step(p)==SQLITE_ROW{targets.insert(string(p,0))};sqlite3_finalize(p)}
        guard targets.count<=1 else{throw BatteryFailure.identityConflict}
        guard let id=targets.first else{return incoming}
        if let old=known.first(where:{$0.id==id}){guard old.kind==incoming.kind else{throw BatteryFailure.identityConflict}}
        let aliases=Array(Set(incoming.aliases+[incoming.id])).filter{$0 != id}
        return BatteryDevice(id:id,kind:incoming.kind,name:incoming.name,model:incoming.model,system:incoming.system,tracking:incoming.tracking,aliases:aliases)
    }
    private func registerAliases(_ device:BatteryDevice)throws {
        for alias in Set(device.aliases+[device.id]){
            let p=try statement("SELECT device_id FROM device_aliases WHERE alias=?");try text(p,1,alias);let step=sqlite3_step(p),old=step==SQLITE_ROW ? string(p,0):nil;sqlite3_finalize(p)
            guard old==nil || old==device.id else{throw BatteryFailure.identityConflict}
            let q=try statement("INSERT OR IGNORE INTO device_aliases(alias,device_id) VALUES(?,?)");try text(q,1,alias);try text(q,2,device.id);let code=sqlite3_step(q);sqlite3_finalize(q);guard code==SQLITE_DONE else{throw BatteryFailure.database}
        }
    }
    func passport(_ id:String)throws->TechnicalObservation? {
        try openStore();guard BatteryIdentity.valid(id) else{throw BatteryFailure.invalidReading}
        let p=try statement("SELECT payload FROM device_passports WHERE device_id=?");defer{sqlite3_finalize(p)};try text(p,1,id);guard sqlite3_step(p)==SQLITE_ROW else{return nil}
        let passport=try JSONDecoder().decode(DevicePassport.self,from:Data(string(p,0).utf8));try passport.validate()
        let q=try statement("SELECT count(*),min(measured),max(measured) FROM technical_snapshots WHERE device_id=?");defer{sqlite3_finalize(q)};try text(q,1,id);guard sqlite3_step(q)==SQLITE_ROW else{throw BatteryFailure.database}
        let b=try statement("SELECT count(DISTINCT pack) FROM (SELECT pack FROM samples WHERE device_id=? UNION SELECT pack FROM historical_samples WHERE device_id=?) WHERE pack!='unknown'");defer{sqlite3_finalize(b)};try text(b,1,id);try text(b,2,id);guard sqlite3_step(b)==SQLITE_ROW else{throw BatteryFailure.database}
        return TechnicalObservation(passport:passport,samples:Int(sqlite3_column_int64(q,0)),firstSeen:Date(timeIntervalSince1970:sqlite3_column_double(q,1)),lastSeen:Date(timeIntervalSince1970:sqlite3_column_double(q,2)),batteryIdentifiers:Int(sqlite3_column_int64(b,0)))
    }
    func recordPassport(_ passport:DevicePassport,device:BatteryDevice)throws {
        try openStore();try passport.validate();let resolved=try resolveDevice(device);guard try devices().contains(where:{$0.id==resolved.id}) else{throw BatteryFailure.invalidReading}
        guard try scalar("SELECT (SELECT count(*) FROM samples)+(SELECT count(*) FROM historical_samples)+(SELECT count(*) FROM technical_snapshots)")<250000 else{throw BatteryFailure.historyLimit}
        try exec("BEGIN IMMEDIATE");do{try savePassport(passport,id:resolved.id);try exec("COMMIT")}catch{try? exec("ROLLBACK");throw error}
    }
    private func savePassport(_ passport:DevicePassport,id:String)throws {
        try passport.validate();let encoded=String(decoding:try JSONEncoder().encode(passport),as:UTF8.self)
        let p=try statement("INSERT INTO device_passports VALUES(?,?,?) ON CONFLICT(device_id) DO UPDATE SET updated=excluded.updated,payload=excluded.payload");defer{sqlite3_finalize(p)};try text(p,1,id);sqlite3_bind_double(p,2,passport.date.timeIntervalSince1970);try text(p,3,encoded);guard sqlite3_step(p)==SQLITE_DONE else{throw BatteryFailure.database}
        let bucket=Int64(passport.date.timeIntervalSince1970*1000),q=try statement("SELECT bucket,context FROM technical_snapshots WHERE device_id=? ORDER BY measured DESC LIMIT 1");defer{sqlite3_finalize(q)};try text(q,1,id)
        let row=sqlite3_step(q);if row==SQLITE_ROW,sqlite3_column_int64(q,0)==bucket,string(q,1)==passport.context{return}
        let t=try statement("INSERT OR IGNORE INTO technical_snapshots(device_id,measured,bucket,digest,context,payload) VALUES(?,?,?,?,?,?)");defer{sqlite3_finalize(t)};try text(t,1,id);sqlite3_bind_double(t,2,passport.date.timeIntervalSince1970);sqlite3_bind_int64(t,3,bucket);try text(t,4,passport.signature);try text(t,5,passport.context);try text(t,6,encoded)
        guard sqlite3_step(t)==SQLITE_DONE else{throw BatteryFailure.database}
    }
    func preview(_ plan:CoconutPlan)throws->CoconutReview {
        try openStore();let existing=try devices();var rows:[CoconutDeviceReview]=[]
        for source in plan.devices{let resolved=try resolveDevice(source);let old=existing.first{$0.id==resolved.id};let count=plan.samples.filter{$0.device.id==source.id}.count;rows.append(CoconutDeviceReview(sourceID:source.id,targetID:resolved.id,name:old?.name ?? source.name,model:old?.model ?? source.model,existing:old != nil,count:count))}
        let binding=plan.sha256+rows.sorted{$0.sourceID<$1.sourceID}.map{$0.sourceID+":"+$0.targetID}.joined(separator:"|")
        return CoconutReview(plan:plan,devices:rows,token:BatteryIdentity.hash("import-plan:"+binding))
    }
    func apply(_ review:CoconutReview)throws->CoconutImportResult {
        try openStore();let plan=review.plan
        guard try preview(plan).token==review.token else{throw BatteryFailure.identityConflict}
        let fresh=try CoconutArchive.backupData(at:plan.file)
        guard BatteryIdentity.fileHash(fresh)==plan.sha256 else{throw CoconutFailure.invalidFile}
        var pending:[CoconutSample]=[]
        for sample in plan.samples{let p=try statement("SELECT 1 FROM historical_samples WHERE sample_hash=?");try text(p,1,sample.sampleHash);let step=sqlite3_step(p);sqlite3_finalize(p);if step==SQLITE_DONE{pending.append(sample)}else if step != SQLITE_ROW{throw BatteryFailure.database}}
        guard !pending.isEmpty else{return CoconutImportResult(inserted:0,skipped:plan.samples.count+plan.skipped,devices:0)}
        guard try scalar("SELECT (SELECT count(*) FROM samples)+(SELECT count(*) FROM historical_samples)+(SELECT count(*) FROM technical_snapshots)")+Int64(pending.count)<=250000 else{throw BatteryFailure.historyLimit}
        try BatteryStoreRecovery.snapshot(connection:db!,directory:directory,reason:"coconut-import")
        let original=try devices(),before=try scalar("SELECT count(*) FROM historical_samples");guard original.count+review.devices.filter({!$0.existing}).count<=1000 else{throw BatteryFailure.historyLimit}
        try exec("BEGIN IMMEDIATE")
        do{
            let targets=Dictionary(uniqueKeysWithValues:review.devices.map{($0.sourceID,$0.targetID)})
            var added=Set<String>()
            for source in plan.devices{guard let id=targets[source.id] else{throw BatteryFailure.identityConflict};var d=source;if let existing=original.first(where:{$0.id==id}){d=BatteryDevice(id:id,kind:existing.kind,name:existing.name,model:existing.model,system:existing.system,tracking:existing.tracking,aliases:source.aliases+[source.id])}else{d=BatteryDevice(id:id,kind:source.kind,name:source.name,model:source.model,system:source.system,tracking:true,aliases:source.aliases+[source.id]);added.insert(id)}
                try checked(d);let p=try statement("INSERT OR IGNORE INTO devices VALUES(?,?,?,?,?,?)");for (i,s) in [d.id,d.kind,d.name,d.model,d.system].enumerated(){try text(p,Int32(i+1),s)};sqlite3_bind_int(p,6,d.tracking ? 1:0);let step=sqlite3_step(p);sqlite3_finalize(p);guard step==SQLITE_DONE else{throw BatteryFailure.database};try registerAliases(d)
            }
            for sample in pending{guard let id=targets[sample.device.id] else{throw BatteryFailure.identityConflict};try sample.reading.validate();let p=try statement("INSERT INTO historical_samples(device_id,measured,pack,reading,sample_hash,source_sha) VALUES(?,?,?,?,?,?)");try text(p,1,id);sqlite3_bind_double(p,2,sample.date.timeIntervalSince1970);try text(p,3,sample.reading.pack_hash ?? "unknown");try text(p,4,String(decoding:try JSONEncoder().encode(sample.reading),as:UTF8.self));try text(p,5,sample.sampleHash);try text(p,6,plan.sha256);let step=sqlite3_step(p);sqlite3_finalize(p);guard step==SQLITE_DONE else{throw BatteryFailure.database}}
            for source in plan.devices{if let id=targets[source.id],try passport(id)==nil,let imported=plan.samples.filter({$0.device.id==source.id}).max(by:{$0.date<$1.date})?.passport{try savePassport(imported,id:id)}}
            guard try scalar("SELECT count(*) FROM historical_samples")-before==Int64(pending.count) else{throw BatteryFailure.database}
            try exec("COMMIT")
            guard try integrity() else{throw BatteryFailure.database}
            return CoconutImportResult(inserted:pending.count,skipped:plan.skipped+plan.samples.count-pending.count,devices:added.count)
        }catch{try? exec("ROLLBACK");throw error}
    }

}
