import SwiftUI

@main struct StudyReaderApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(StudyReaderAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .tint(Color(red: 0.18, green: 0.46, blue: 0.39))
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { library.flush() }
                    library.syncSceneChanged(isActive: phase != .background)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }
}

#if os(macOS)
final class StudyReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode reuses the bundle path across builds. Load the bundled artwork directly so
        // the Dock does not keep the generic icon cached before an app icon was added.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
#endif
