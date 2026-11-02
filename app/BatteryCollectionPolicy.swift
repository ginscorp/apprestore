import Foundation

/// Discovery never creates a sample; a temporary trust/read failure is not a USB disconnect. A successful capture consumes this connection event.
struct BatteryCollectionPolicy {
    private(set) var macCaptured=false
    private var captured=Set<String>()
    mutating func observeConnectedDevices(_ ids:Set<String>){captured.formIntersection(ids)}
    func needsPhone(_ id:String)->Bool{!captured.contains(id)}
    mutating func capturedPhone(_ id:String){captured.insert(id)}
    mutating func capturedMac(){macCaptured=true}
}
