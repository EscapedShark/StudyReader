import SwiftUI

@main struct StudyReaderApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(StudyReaderAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var library: LibraryStore = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["STUDYREADER_LIBRARY_PATH"] {
            return LibraryStore(rootURL: URL(fileURLWithPath: path), seedSamples: false, automaticSync: false)
        }
        if environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return LibraryStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("StudyReaderTestHost-\(UUID().uuidString)"),
                                seedSamples: false, automaticSync: false)
        }
        #endif
        return LibraryStore()
    }()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .tint(Color(red: 0.18, green: 0.46, blue: 0.39))
                #if os(macOS)
                .onAppear { appDelegate.flushReadingState = { await library.flush() } }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { library.saveForLifecycle() }
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
    var flushReadingState: (() async -> Bool)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flushReadingState else { return .terminateNow }
        Task { @MainActor in
            let saved = await flushReadingState()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode reuses the bundle path across builds. Load the bundled artwork directly so
        // the Dock does not keep the generic icon cached before an app icon was added.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
#endif
