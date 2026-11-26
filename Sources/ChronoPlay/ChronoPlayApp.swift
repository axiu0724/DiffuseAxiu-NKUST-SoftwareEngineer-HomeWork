import SwiftUI

@main
struct ChronoPlayApp: App {
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("ChronoPlay") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
