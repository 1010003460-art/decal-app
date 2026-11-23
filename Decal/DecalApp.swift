import SwiftUI

@main
struct DecalApp: App {
    init() {
        #if DEBUG
        assert(Homography.selfCheck(), "Homography 四点往返自检失败")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
