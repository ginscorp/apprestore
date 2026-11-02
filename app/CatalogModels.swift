import Foundation

struct CatalogApp: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let aliases: [String]
    let sources: [String]
    let category: String
    var searchable: String { ([name, String(id)] + aliases).joined(separator: " ").lowercased().replacingOccurrences(of: "online", with: "онлайн") }
}
struct CatalogStatus: Decodable { let source: String; let status: String; let count: Int }
struct CatalogPayload: Decodable { let apps: [CatalogApp]; let status: [CatalogStatus] }
struct Device: Decodable, Identifiable, Hashable {
    let udid: String; let name: String; let ios: String; let model: String; let paired: Bool
    var build:String? = nil
    var id: String { udid }
}
struct DeviceApp: Decodable, Identifiable, Hashable {
    let bundle: String; let name: String; let version: String; let app_id: Int64?
    var minimum_ios:String? = nil
    var file_sharing:Bool? = nil
    var id: String { bundle }
}
struct BridgeError: Error { let code: String; var diagnostic: String? = nil }

struct PackageCompatibility: Codable,Equatable {
    let ios:String;let minimum_ios:String;let compatible:Bool;let version:String;let bundle:String
}

