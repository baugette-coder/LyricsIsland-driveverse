#if os(iOS)
import SwiftUI

/// Two tabs: the library (browse, queue, import) and the existing Now
/// Playing / lyrics screen.
struct RootView: View {
    enum Tab { case library, playing }
    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(openPlayer: { tab = .playing })
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(Tab.library)
            HomeView()
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
                .tag(Tab.playing)
        }
    }
}
#endif
