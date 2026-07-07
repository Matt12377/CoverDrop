import SwiftUI

struct RootView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        switch appModel.route {
        case .libraries, .coverWall:
            LibraryHomeView(appModel: appModel)
        }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView(appModel: AppModel())
    }
}
