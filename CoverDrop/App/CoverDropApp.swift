import SwiftUI

@main
struct CoverDropApp: App {
    @State private var appModel: AppModel
    @State private var performanceMonitorTask: Task<Void, Never>?

    init() {
        let environment = AppEnvironment.live
        _appModel = State(initialValue: AppModel(environment: environment))
        _performanceMonitorTask = State(initialValue: nil)
    }

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
                .onAppear {
                    guard performanceMonitorTask == nil else { return }
                    performanceMonitorTask = CoverDropPerformanceLog.makeMainThreadStallMonitor()
                }
                .onDisappear {
                    performanceMonitorTask?.cancel()
                    performanceMonitorTask = nil
                }
        }
        .defaultSize(width: 1_080, height: 720)
    }
}
