import SwiftUI

@main
struct MimicApp: App {
    @StateObject private var engine = Engine()
    @NSApplicationDelegateAdaptor(MimicAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Mimic", id: "main") {
            ContentView()
                .environmentObject(engine)
                .tint(Palette.blood)
                .task {
                    delegate.engine = engine
                    if engine.state == .idle { await engine.connect() }
                    await engine.syncVoices()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}                      // no New Window
            CommandGroup(after: .appInfo) {
                Button("Open the Web App") {
                    NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8455")!)
                }
                .disabled(!engine.state.isReady)
            }
        }
    }


}

/// Keep the shared engine alive when the window closes; stop an owned child
/// only when the application quits.
@MainActor
final class MimicAppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: Engine?
    func applicationWillTerminate(_ notification: Notification) { engine?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Where the Python engine lives.
///
/// The app does not bundle Python. Vendoring an interpreter, ONNX Runtime and a
/// gigabyte of weights into a .app would quadruple its size and pin the engine
/// to whatever was frozen at build time — and the engine is the part most
/// likely to be iterated on. Instead the app finds a checkout and runs it,
/// which also means the web app and this one are always the same version.
enum Install {
    struct Location {
        let root: URL
        let python: URL
    }

    /// Candidate checkouts, nearest first.
    private static var candidates: [URL] {
        var roots: [URL] = []
        if let configured = UserDefaults.standard.string(forKey: "MimicRoot") {
            roots.append(URL(filePath: configured))
        }
        // Running from inside the repo during development: Mimic.app sits in
        // macos/build/, so the checkout is two levels up.
        let bundle = Bundle.main.bundleURL
        roots.append(bundle.deletingLastPathComponent()
                           .deletingLastPathComponent()
                           .deletingLastPathComponent())
        roots.append(URL(filePath: NSHomeDirectory()).appending(path: "Developer/Mimic"))
        roots.append(URL(filePath: NSHomeDirectory()).appending(path: "Mimic"))
        return roots
    }

    static func find() -> Location? {
        for root in candidates {
            let marker = root.appending(path: "core/server.py")
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            for python in [root.appending(path: ".venv/bin/python3"),
                           root.appending(path: ".venv/bin/python")] {
                if FileManager.default.isExecutableFile(atPath: python.path) {
                    return Location(root: root, python: python)
                }
            }
        }
        return nil
    }

    /// What to tell someone when it cannot be found.
    static var advice: String {
        "Could not find a Mimic checkout with a virtual environment. Set one with:\n"
        + "    defaults write dev.mimic.app MimicRoot /path/to/Mimic"
    }
}
