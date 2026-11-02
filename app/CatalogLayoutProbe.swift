import SwiftUI

// Diagnostic geometry exists only in the isolated synthetic UI test build.
#if APPRESTORE_LAYOUT_TEST
struct CatalogGeometryKey:PreferenceKey {
    static var defaultValue:[String:CGRect]=[:]
    static func reduce(value:inout [String:CGRect],nextValue:()->[String:CGRect]) {value.merge(nextValue(),uniquingKeysWith:{_,new in new})}
}
@MainActor enum CatalogLayoutProbe {static var frames:[String:CGRect]=[:]}
#endif
extension View {
    @ViewBuilder func catalogProbe(_ key:String)->some View {
        #if APPRESTORE_LAYOUT_TEST
        self.background(GeometryReader {proxy in Color.clear.preference(key:CatalogGeometryKey.self,value:[key:proxy.frame(in:.named("catalog-layout"))])})
        #else
        self
        #endif
    }
    @ViewBuilder func reportCatalogLayout()->some View {
        #if APPRESTORE_LAYOUT_TEST
        self.coordinateSpace(name:"catalog-layout").onPreferenceChange(CatalogGeometryKey.self){CatalogLayoutProbe.frames=$0}
        #else
        self
        #endif
    }
}
