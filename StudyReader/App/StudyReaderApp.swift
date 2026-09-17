import SwiftUI

@main struct StudyReaderApp: App {
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .tint(Color(red: 0.18, green: 0.46, blue: 0.39))
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { library.flush() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }
}
