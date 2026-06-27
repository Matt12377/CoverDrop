import SwiftUI

struct RootView: View {
    let appModel: AppModel

    var body: some View {
        switch appModel.route {
        case .libraries, .coverWall:
            LibraryHomeView(appModel: appModel)
        }
    }
}

#Preview {
    RootView(appModel: AppModel())
}
