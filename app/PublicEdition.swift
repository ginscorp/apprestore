import Foundation
import Darwin

// Separate public storage. Preview data is synthetic and never shares private app state.
enum PublicEdition {
    private static let invalidRoot = URL(fileURLWithPath:"/dev/null/AppRestore-invalid-root",isDirectory:true)
    private static func isSafeDirectoryPath(_ path:String)->Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components=path.split(separator:"/",omittingEmptySubsequences:true)
        guard !components.isEmpty, !components.contains(where:{$0 == "." || $0 == ".."}) else {return false}
        var current=""
        for component in components {
            current += "/" + component
            var info=stat()
            if lstat(current,&info)==0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {return false}
            } else if errno == ENOENT {
                break
            } else {return false}
        }
        return true
    }
    static var preview:Bool {
        (Bundle.main.object(forInfoDictionaryKey:"AppRestorePreview") as? Bool)==true ||
        ProcessInfo.processInfo.environment["APPRESTORE_PREVIEW"]=="1"
    }
    static var dataRoot:URL {
        if let path=ProcessInfo.processInfo.environment["APPRESTORE_DATA_HOME"] {
            guard isSafeDirectoryPath(path) else {return invalidRoot}
            return URL(fileURLWithPath:path,isDirectory:true)
        }
        if preview {
            guard let resolved=realpath(NSTemporaryDirectory(),nil) else {return invalidRoot}
            let path=String(cString:resolved);free(resolved)
            guard isSafeDirectoryPath(path) else {return invalidRoot}
            return URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent("AppRestorePublicPreview",isDirectory:true)
        }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AppRestorePublic",isDirectory:true)
    }
}
