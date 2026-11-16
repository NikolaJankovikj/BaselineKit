import SwiftUI

@main
struct BaselineApp: App {
    init() {
        BaselineBackground.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
                .tint(.brand)
        }
    }
}
