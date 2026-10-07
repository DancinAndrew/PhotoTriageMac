import AppKit

/// Native QA can capture this app's fictional demo view without screen recording.
/// Real-library pixels can never enter this capture path.
@MainActor
enum DemoUICapture {
    static func schedule(_ model: AppModel) {
        let args = CommandLine.arguments
        guard model.isDemo, let index = args.firstIndex(of: "--capture-demo-ui"),
              args.indices.contains(index + 1), args.contains("--review-root") else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard model.isDemo, let view = NSApp.windows.first(where: {
                $0.isVisible && $0.title.contains("Photo Triage")
            })?.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } catch { NSLog("Demo UI capture failed: %@", error.localizedDescription) }
        }
    }
}
