import SwiftUI

@main
struct ScorpioCodesApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .frame(minWidth: 420, minHeight: 680)
        }
        .defaultSize(width: 440, height: 800)
        #else
        WindowGroup {
            RootView()
        }
        #endif
    }
}
