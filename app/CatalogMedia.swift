import Foundation
import AppKit
import Combine
import ImageIO

enum CatalogSort: String, CaseIterable, Identifiable {
    case nameAscending, nameDescending, idDescending, idAscending
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nameAscending: return L("Название: А → Я")
        case .nameDescending: return L("Название: Я → А")
        case .idDescending: return L("App ID: сначала большие")
        case .idAscending: return L("App ID: сначала маленькие")
        }
    }
    func order(_ apps: [CatalogApp]) -> [CatalogApp] {
        apps.sorted { a,b in
            switch self {
            case .idDescending: return a.id > b.id
            case .idAscending: return a.id < b.id
            case .nameAscending, .nameDescending:
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                if c == .orderedSame { return a.id < b.id }
                return self == .nameAscending ? c == .orderedAscending : c == .orderedDescending
            }
        }
    }
}

struct PublicAppInfo: Codable {
    let id: Int64
    var title: String = ""
    var publisher: String = ""
    var bundle: String = ""
    var publicVersion: String = ""
    var releaseDate: String = ""
    var minimumOS: String = ""
    var region: String = ""
    var checkedAt: Date = .distantPast
}
struct VersionObservation: Codable, Identifiable {
    let version: String
    let date: Date
    var id: String { version }
}
struct MediaIndex: Codable {
    var schema = 1
    var apps: [String:PublicAppInfo] = [:]
    var versions: [String:[VersionObservation]] = [:]
    var lookupChecked: [String:Date] = [:]
    // Public storefront presence only; never an account entitlement or purchase result.
    // Optional so old schema-1 files round-trip without adding fields during verification.
    var lookupPresence: [String:Bool]? = nil
}

enum PublicListingState: Equatable {
    case unknown, listed(Date), missing(Date)
}

struct PublicLookupSnapshot {
    let rows: [[String:Any]]
    let returnedIDs: Set<Int64>
    static func decode(_ data: Data, requestedIDs: Set<Int64>) throws -> Self {
        guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let count = json["resultCount"] as? Int, let rows = json["results"] as? [[String:Any]],
              count == rows.count, count >= 0, count <= requestedIDs.count else { throw BridgeError(code:"invalid_public_lookup") }
        var ids = Set<Int64>()
        for row in rows {
            guard let number = row["trackId"] as? NSNumber,
                  requestedIDs.contains(number.int64Value), ids.insert(number.int64Value).inserted,
                  row["trackName"] is String, row["version"] is String else { throw BridgeError(code:"invalid_public_lookup") }
        }
        return Self(rows:rows,returnedIDs:ids)
    }
}

enum PublicMediaPolicy {
    static let maximumBytes = 2 * 1024 * 1024
    static func allowed(_ u: URL) -> Bool {
        guard u.scheme == "https", u.user == nil, u.password == nil,
              u.port == nil || u.port == 443, u.fragment == nil else { return false }
        let host = u.host?.lowercased() ?? ""
        if host == "itunes.apple.com" {
            guard u.path == "/lookup", let parts = URLComponents(url:u,resolvingAgainstBaseURL:false),
                  let queries = parts.queryItems, queries.count <= 3 else { return false }
            return queries.allSatisfy { item in
                switch item.name {
                case "id": return item.value?.range(of:"^[0-9,]{1,1200}$", options:.regularExpression) != nil
                case "country": return ["ru","us","kz","tr"].contains(item.value ?? "")
                case "entity": return item.value == "software"
                default: return false
                }
            }
        }
        if host.hasSuffix(".mzstatic.com") && u.query == nil { return true }
        if host == "raw.githubusercontent.com", u.query == nil {
            return u.path.range(of:"^/n0hard/back-to-iphone/main/app/ui/icons/[0-9]{1,11}\\.png$",options:.regularExpression) != nil
        }
        return false
    }
    static func normalizedPNG(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let src = CGImageSourceCreateWithData(data as CFData,nil), CGImageSourceGetCount(src) == 1,
              let type = CGImageSourceGetType(src) as String?, ["public.png","public.jpeg"].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let cg = CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(result,"public.png" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(dst,cg,nil)
        guard CGImageDestinationFinalize(dst), result.length <= maximumBytes else { return nil }
        return result as Data
    }
}

// A separate, bounded, cookie-free public client. No account IPC data enters it.
final class PublicMediaClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending { var data = Data(); let completion: CheckedContinuation<Data,Error> }
    private let lock = NSLock()
    private var pending: [Int:Pending] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false; cfg.urlCredentialStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10; cfg.timeoutIntervalForResource = 15
        cfg.httpMaximumConnectionsPerHost = 3
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration:cfg,delegate:self,delegateQueue:queue)
    }()
    func fetch(_ url: URL) async throws -> Data {
        guard PublicMediaPolicy.allowed(url) else { throw BridgeError(code:"media_address_blocked") }
        return try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url:url); request.httpShouldHandleCookies = false
            request.setValue("AppRestorePublic/0.2 PublicCatalog",forHTTPHeaderField:"User-Agent")
            let task = session.dataTask(with:request)
            lock.lock(); pending[task.taskIdentifier] = Pending(completion:continuation); lock.unlock()
            task.resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PublicMediaPolicy.allowed(url) else { completionHandler(nil); return }
        var clean = URLRequest(url:url); clean.httpShouldHandleCookies = false
        clean.setValue("AppRestorePublic/0.2 PublicCatalog",forHTTPHeaderField:"User-Agent")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = response.url, PublicMediaPolicy.allowed(url),
              response.expectedContentLength <= PublicMediaPolicy.maximumBytes else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if var item = pending[dataTask.taskIdentifier] {
            if item.data.count + data.count > PublicMediaPolicy.maximumBytes { lock.unlock(); dataTask.cancel(); return }
            item.data.append(data); pending[dataTask.taskIdentifier] = item
        }
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey:task.taskIdentifier); lock.unlock()
        guard let item else { return }
        if let error { item.completion.resume(throwing:error) }
        else if let status = (task.response as? HTTPURLResponse)?.statusCode, status == 200 { item.completion.resume(returning:item.data) }
        else { item.completion.resume(throwing:BridgeError(code:"media_unavailable")) }
    }
}

@MainActor final class CatalogMedia: ObservableObject {
    @Published private(set) var index = MediaIndex()
    @Published private(set) var revision = 0
    @Published private(set) var preloading = false
    @Published private(set) var progress: UIMessage = ""
    @Published var backupMessage = "Резервная копия еще не проверялась"
    let root: URL
    private let client = PublicMediaClient()
    private var images: [Int64:NSImage] = [:]
    private var missingImages = Set<Int64>()
    private var iconVersions: [Int64:Int] = [:]
    private let imageLoader = CatalogImageLoader()
    private var inFlight = Set<Int64>()
    private var bundled: [String:String] = [:]
    private var knownIDs = Set<Int64>()
    private var backupTask: Task<Void,Never>?
    init(preview: Bool = false) {
        #if APPRESTORE_LAYOUT_TEST
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppRestore-layout-\(getpid())/Library")
        #else
        root = PublicEdition.dataRoot.appendingPathComponent(preview ? "PreviewLibrary" : "Library")
        #endif
        if let data = try? Data(contentsOf:root.appendingPathComponent("metadata.json")), data.count <= 4*1024*1024,
           let cached = try? JSONDecoder().decode(MediaIndex.self,from:data), cached.schema == 1 { index = cached }
        if let resources = Bundle.main.resourceURL,
           let data = try? Data(contentsOf:resources.appendingPathComponent("MediaSeed/icon-map.json")),
           let map = try? JSONDecoder().decode([String:String].self,from:data) { bundled = map }
        try? FileManager.default.createDirectory(at:root.appendingPathComponent("icons"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    func setCatalog(_ apps: [CatalogApp]) {
        knownIDs = Set(apps.map(\.id))
        for app in apps {
            let dest = root.appendingPathComponent("icons/\(app.id).png")
            guard !FileManager.default.fileExists(atPath:dest.path),let name = bundled[String(app.id)],let source = Bundle.main.resourceURL?.appendingPathComponent("MediaSeed/icons/\(name)"),let data = try? Data(contentsOf:source),let png = PublicMediaPolicy.normalizedPNG(data) else {continue}
            try? png.write(to:dest,options:.atomic)
        }
    }
    func imageRevision(_ id:Int64)->Int {iconVersions[id] ?? 0}
    func image(_ id:Int64)->NSImage? { images[id] }
    func loadImage(_ id:Int64)async->NSImage? {
        if let image=images[id] {return image}
        guard !missingImages.contains(id) else{return nil}
        let local=root.appendingPathComponent("icons/\(id).png")
        let bundledURL=bundled[String(id)].flatMap { name in
            name.range(of:"^[0-9]+\\.png$",options:.regularExpression) == nil ? nil:Bundle.main.resourceURL?.appendingPathComponent("MediaSeed/icons/\(name)")
        }
        guard let cg=await imageLoader.load(local:local,fallback:bundledURL) else{missingImages.insert(id);return nil}
        let image=NSImage(cgImage:cg,size:NSSize(width:256,height:256));images[id]=image;return image
    }
    private func hasIcon(_ id:Int64)->Bool {images[id] != nil || FileManager.default.fileExists(atPath:root.appendingPathComponent("icons/\(id).png").path) || bundled[String(id)] != nil}
    var imageCount: Int { (try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("icons").path).filter{$0.range(of:"^[0-9]{1,11}\\.png$",options:.regularExpression) != nil}.count) ?? 0 }
    var versionCount: Int { index.versions.values.reduce(0) { $0 + $1.count } }
    func info(_ id: Int64) -> PublicAppInfo? { index.apps[String(id)] }
    func listingState(_ id: Int64) -> PublicListingState {
        guard let present = index.lookupPresence?[String(id)], let date = index.lookupChecked[String(id)] else { return .unknown }
        return present ? .listed(date) : .missing(date)
    }
    func observations(_ id: Int64) -> [VersionObservation] { index.versions[String(id)] ?? [] }
    func recordVersion(id: Int64, version: String) {
        guard knownIDs.contains(id), !version.isEmpty, version.count <= 64 else { return }
        var history = index.versions[String(id)] ?? []
        if !history.contains(where:{$0.version == version}) { history.insert(VersionObservation(version:version,date:Date()),at:0);index.versions[String(id)] = Array(history.prefix(32)); save() }
    }
    private func save() {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard let data = try? encoder.encode(index), data.count <= 4*1024*1024 else { return }
        do { try data.write(to:root.appendingPathComponent("metadata.json"),options:.atomic); revision += 1; scheduleBackup() }
        catch { progress = "Не удалось сохранить сведения на Mac" }
    }
    private func storeIcon(_ data: Data, id: Int64) {
        guard knownIDs.contains(id), let png = PublicMediaPolicy.normalizedPNG(data), let image = NSImage(data:png) else { return }
        do { try png.write(to:root.appendingPathComponent("icons/\(id).png"),options:.atomic); images[id] = image; missingImages.remove(id); iconVersions[id,default:0] += 1; revision += 1; scheduleBackup() } catch {}
    }
    func warm(_ apps: [CatalogApp], all: Bool = false, force: Bool = false) async {
        guard !preloading else { return }
        let candidates = apps.filter { knownIDs.contains($0.id) && !inFlight.contains($0.id) }
        let needed = candidates.filter { force || index.lookupPresence?[String($0.id)] == nil || Date().timeIntervalSince(index.lookupChecked[String($0.id)] ?? .distantPast) > 24*3600 }
        let selected = all ? needed : Array(needed.prefix(40))
        guard !selected.isEmpty else {if all || force {progress = "Сохраненные сведения актуальны"};return}
        preloading = true;defer{preloading = false;scheduleBackup()}
        var done = 0
        for start in stride(from:0,to:selected.count,by:40) {
            if Task.isCancelled { break }
            let group = Array(selected[start..<min(start+40,selected.count)])
            group.forEach{inFlight.insert($0.id)}
            var url = URLComponents(string:"https://itunes.apple.com/lookup")!
            url.queryItems = [URLQueryItem(name:"country",value:"ru"),URLQueryItem(name:"id",value:group.map{String($0.id)}.joined(separator:",")),URLQueryItem(name:"entity",value:"software")]
            var sourceResponded = false
            do {
                let data = try await client.fetch(url.url!)
                let snapshot = try PublicLookupSnapshot.decode(data,requestedIDs:Set(group.map(\.id)))
                sourceResponded = true
                let checkedAt = Date()
                    for row in snapshot.rows {
                        guard let number = row["trackId"] as? NSNumber else { continue }; let id = number.int64Value
                        guard group.contains(where:{$0.id == id}) else { continue }
                        let safe: (String)->String = { key in String((row[key] as? String ?? "").prefix(240)) }
                        let old = index.apps[String(id)]
                        index.apps[String(id)] = PublicAppInfo(id:id,title:safe("trackName"),publisher:safe("sellerName"),bundle:safe("bundleId"),publicVersion:safe("version"),releaseDate:safe("currentVersionReleaseDate"),minimumOS:safe("minimumOsVersion"),region:"ru",checkedAt:checkedAt)
                        let refreshArtwork = !hasIcon(id) || old == nil || old?.publicVersion != safe("version") || checkedAt.timeIntervalSince(old?.checkedAt ?? .distantPast) > 24*3600
                        if refreshArtwork, let value = row["artworkUrl512"] as? String ?? row["artworkUrl100"] as? String, let iconURL = URL(string:value), PublicMediaPolicy.allowed(iconURL),let icon = try? await client.fetch(iconURL) { storeIcon(icon,id:id) }
                    }
                    if index.lookupPresence == nil { index.lookupPresence = [:] }
                    for app in group { index.lookupChecked[String(app.id)] = checkedAt; index.lookupPresence?[String(app.id)] = snapshot.returnedIDs.contains(app.id) }
                    save()
            } catch { progress = "Показываем сохраненные сведения. Источник временно недоступен." }
            for app in group.prefix(all ? 40 : 8) where sourceResponded && !hasIcon(app.id) {
                if let u = URL(string:"https://raw.githubusercontent.com/n0hard/back-to-iphone/main/app/ui/icons/\(app.id).png"), let icon = try? await client.fetch(u) { storeIcon(icon,id:app.id) }
            }
            group.forEach{inFlight.remove($0.id)};done += group.count
            if !sourceResponded { break }
            progress = .format("Сведения: %@ из %@",[String(done),String(selected.count)])
            if all { try? await Task.sleep(nanoseconds:3_000_000_000) }
        }
    }
    func prepare(_ apps: [CatalogApp]) async { await warm(apps,all:true); await backupNow() }
    private func scheduleBackup() {
        backupTask?.cancel()
        backupTask = Task { try? await Task.sleep(nanoseconds:8_000_000_000);guard !Task.isCancelled else{return};await backupNow() }
    }
    func backupNow() async {
        guard !preloading else { backupMessage = "Идет предзагрузка · резерв будет обновлен после нее"; return }
        let result = await PublicLibraryBackup.run(source:root)
        backupMessage = result
    }
}

// One background actor bounds decode concurrency. No filesystem/decode work in View.body.
actor CatalogImageLoader {
    func load(local:URL,fallback:URL?)->CGImage? {
        for url in [local,fallback].compactMap({$0}) {
            guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>0,size<=PublicMediaPolicy.maximumBytes,
                  let data=try? Data(contentsOf:url),let src=CGImageSourceCreateWithData(data as CFData,nil),
                  let type=CGImageSourceGetType(src) as String?,["public.png","public.jpeg"].contains(type),
                  let props=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any],
                  let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,
                  width>0,height>0,width<=4096,height<=4096,
                  let image=CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {continue}
            return image
        }
        return nil
    }
}
