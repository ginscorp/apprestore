import Foundation
import AppKit
import CryptoKit
import CoreText

enum PrivatePDF {
    static func render(textURL:URL,directory:URL)throws {
        guard textURL.standardizedFileURL.path==directory.appendingPathComponent("conversation.txt").standardizedFileURL.path,textURL.resolvingSymlinksInPath().path==textURL.standardizedFileURL.path,directory.resolvingSymlinksInPath().path==directory.standardizedFileURL.path else{throw BridgeError(code:"unsafe_export_path")}
        let data=try Data(contentsOf:textURL);guard data.count<=64*1024*1024,let text=String(data:data,encoding:.utf8) else{throw BridgeError(code:"archive_text_limit")}
        let output=directory.appendingPathComponent("conversation.pdf");guard !FileManager.default.fileExists(atPath:output.path) else{throw BridgeError(code:"export_exists")}
        var media=CGRect(x:0,y:0,width:595,height:842)
        guard let consumer=CGDataConsumer(url:output as CFURL),let context=CGContext(consumer:consumer,mediaBox:&media,nil) else{throw BridgeError(code:"pdf_export_failed")}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        let body=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.black])
        let setter=CTFramesetterCreateWithAttributedString(body)
        var offset=0,pages=0
        repeat {
            guard pages<1000 else{throw BridgeError(code:"pdf_page_limit")}
            context.beginPDFPage(nil);context.setFillColor(CGColor(gray:1,alpha:1));context.fill(media)
            let path=CGPath(rect:CGRect(x:36,y:36,width:523,height:770),transform:nil)
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:0),path,nil)
            CTFrameDraw(frame,context);let visible=CTFrameGetVisibleStringRange(frame)
            guard visible.length>0 || body.length==0 else{throw BridgeError(code:"pdf_export_failed")}
            offset+=visible.length;pages+=1;context.endPDFPage()
        }while offset<body.length
        context.closePDF()
    }
}

final class PhotoExportJob {
    let root:URL
    private var entries:[[String:Any]]=[]
    init(parent:URL,total:Int64)throws {
        let fm=FileManager.default,p=parent.standardizedFileURL.path
        guard parent.resolvingSymlinksInPath().path==p,!p.hasPrefix("/Applications"),!p.hasPrefix(FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AppRestore").path),!p.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path),total>0 else{throw BridgeError(code:"unsafe_export_path")}
        let free=(try fm.attributesOfFileSystem(forPath:p)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free>total+512*1024*1024 else{throw BridgeError(code:"insufficient_disk_space")}
        root=parent.appendingPathComponent("AppRestore-Photos-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try receipt("incomplete")
    }
    func checkSpace()throws{let free=(try FileManager.default.attributesOfFileSystem(forPath:root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0;guard free>256*1024*1024 else{throw BridgeError(code:"insufficient_disk_space")}}
    static func hash(_ url:URL)throws->String{let h=try FileHandle(forReadingFrom:url);defer{try? h.close()};var hash=SHA256();while let data=try h.read(upToCount:1024*1024),!data.isEmpty{hash.update(data:data)};return hash.finalize().map{String(format:"%02x",$0)}.joined()}
    func record(_ url:URL,size:Int64,sourceSHA:String)throws {
        guard url.resolvingSymlinksInPath().path==url.standardizedFileURL.path,(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.int64Value==size,try Self.hash(url)==sourceSHA else{throw BridgeError(code:"export_verification_failed")}
        entries.append(["path":String(url.path.dropFirst(root.path.count+1)),"bytes":size,"sha256":sourceSHA]);try receipt("incomplete")
    }
    private func receipt(_ state:String)throws {let url=root.appendingPathComponent("receipt.json");let data=try JSONSerialization.data(withJSONObject:["schema":1,"kind":"photos","status":state,"files":entries,"count":entries.count,"bytes":entries.reduce(Int64(0)){$0+($1["bytes"] as? Int64 ?? 0)},"source_deleted":false],options:[.sortedKeys,.prettyPrinted]);try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    func finish()throws{for entry in entries{let url=root.appendingPathComponent(entry["path"] as! String);guard try Self.hash(url)==entry["sha256"] as? String else{throw BridgeError(code:"export_verification_failed")}};try receipt("verified")}
}
