// Interoperability format researched from citrus-apps/citrus-battery (GPL-3.0), c7cd8a1.
// Reads only the owner's selected backup. No vendor key is bundled, logged or persisted.
import Foundation
import CryptoKit
import Compression
import Darwin

enum CoconutFailure:Error {case invalidFile,appMissing,keyMismatch,decompressionLimit,invalidSchema,identityMissing}
enum CoconutArchive {
    static let binaryURL=URL(fileURLWithPath:"/Applications/coconutBattery.app/Contents/MacOS/coconutBattery")
    static func decodedRecords(_ backup:Data,binary:Data)throws->[[String:Any]] {
        guard (28...16*1024*1024).contains(backup.count),binary.count<=128*1024*1024 else{throw CoconutFailure.invalidFile}
        guard let box=try? AES.GCM.SealedBox(combined:backup) else{throw CoconutFailure.invalidFile}
        var run=Data(),oversized=false,seen=Set<Data>(),candidates:[SymmetricKey]=[]
        func flush()throws {
            defer{run.removeAll(keepingCapacity:true);oversized=false}
            if !oversized,run.count==44,run.last==61,let data=Data(base64Encoded:run),data.count==32,seen.insert(data).inserted{guard candidates.count<512 else{throw CoconutFailure.invalidFile};candidates.append(SymmetricKey(data:data))}
        }
        for byte in binary {if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte==43 || byte==47 || byte==61{if !oversized{run.append(byte);if run.count>44{run.removeAll(keepingCapacity:true);oversized=true}}}else{try flush()}};try flush()
        guard let compressed=candidates.lazy.compactMap({try? AES.GCM.open(box,using:$0)}).first else{throw CoconutFailure.keyMismatch}
        let data=try decompress(compressed,limit:64*1024*1024)
        guard let records=try JSONSerialization.jsonObject(with:data,options:[]) as? [[String:Any]],records.count<=100000 else{throw CoconutFailure.invalidSchema};return records
    }
    static func backupData(at url:URL)throws->Data {
        guard url.pathExtension.lowercased()=="ccba",url.standardizedFileURL.path==url.resolvingSymlinksInPath().path else{throw CoconutFailure.invalidFile}
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,let size=(attrs[.size] as? NSNumber)?.intValue,(28...16*1024*1024).contains(size),(attrs[.referenceCount] as? NSNumber)?.intValue==1 else{throw CoconutFailure.invalidFile}
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw CoconutFailure.invalidFile};let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? file.close()}
        let bytes=try file.read(upToCount:16*1024*1024+1) ?? Data(),after=try FileManager.default.attributesOfItem(atPath:url.path)
        guard bytes.count==size,attrs[.modificationDate] as? Date==after[.modificationDate] as? Date,attrs[.size] as? NSNumber==after[.size] as? NSNumber else{throw CoconutFailure.invalidFile};return bytes
    }
    static func installedBinary()throws->Data {
        guard binaryURL.standardizedFileURL.path==binaryURL.resolvingSymlinksInPath().path,let attrs=try? FileManager.default.attributesOfItem(atPath:binaryURL.path),((attrs[.size] as? NSNumber)?.intValue ?? Int.max)<=128*1024*1024,let bytes=try? Data(contentsOf:binaryURL,options:.mappedIfSafe) else{throw CoconutFailure.appMissing};return bytes
    }
    static func records(at url:URL)throws->[[String:Any]]{try decodedRecords(backupData(at:url),binary:installedBinary())}
    static func decompress(_ input:Data,limit:Int)throws->Data {
        let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:65536);defer{buffer.deallocate()}
        var stream=compression_stream(dst_ptr:buffer,dst_size:0,src_ptr:UnsafePointer(buffer),src_size:0,state:nil)
        guard compression_stream_init(&stream,COMPRESSION_STREAM_DECODE,COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else{throw CoconutFailure.invalidFile};defer{compression_stream_destroy(&stream)}
        return try input.withUnsafeBytes{raw in
            guard let base=raw.bindMemory(to:UInt8.self).baseAddress else{throw CoconutFailure.invalidFile};stream.src_ptr=base;stream.src_size=input.count
            var output=Data()
            while true {
                stream.dst_ptr=buffer;stream.dst_size=65536
                let previous=stream.src_size
                let status=compression_stream_process(&stream,Int32(COMPRESSION_STREAM_FINALIZE.rawValue)),count=65536-stream.dst_size
                guard output.count+count<=limit else{throw CoconutFailure.decompressionLimit};output.append(buffer,count:count)
                if status==COMPRESSION_STATUS_END{guard stream.src_size==0 else{throw CoconutFailure.invalidFile};return output}
                guard status==COMPRESSION_STATUS_OK,count>0 || stream.src_size<previous else{throw CoconutFailure.invalidFile}
            }
        }
    }
}
