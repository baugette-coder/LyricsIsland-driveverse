#if os(iOS)
import SwiftUI

@main
struct DriveVerseApp: App {
    private let model = AppModel.shared
    private let library = LibraryModel.shared
    private let player = PlayerController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Library first: the player resolves track ids through it.
        LibraryModel.shared.start()
        PlayerController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(library)
                .environmentObject(player)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.foregroundResync()
                        Task { await library.rescan() }
                    }
                }
        }
    }
}
#endif
