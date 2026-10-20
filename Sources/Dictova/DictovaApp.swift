import SwiftUI

@main
struct DictovaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 460)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
