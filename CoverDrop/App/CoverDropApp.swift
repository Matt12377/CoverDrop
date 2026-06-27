import SwiftUI

@main
struct CoverDropApp: App {
    @State private var appModel: AppModel

    init() {
        let environment = AppEnvironment.live
        _appModel = State(initialValue: AppModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
    }
}
