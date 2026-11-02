import Foundation

// Separate public storage. Preview data is synthetic and never shares private app state.
enum PublicEdition {
    static var preview:Bool {
        (Bundle.main.object(forInfoDictionaryKey:"AppRestorePreview") as? Bool)==true ||
        ProcessInfo.processInfo.environment["APPRESTORE_PREVIEW"]=="1"
    }
    static var dataRoot:URL {
        if let path=ProcessInfo.processInfo.environment["APPRESTORE_DATA_HOME"],path.hasPrefix("/") {
            return URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL
        }
        if preview { return FileManager.default.temporaryDirectory.appendingPathComponent("AppRestorePublicPreview",isDirectory:true) }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AppRestorePublic",isDirectory:true)
    }
}
