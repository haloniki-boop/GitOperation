import AppKit

@main
enum GitOperationMain {
    private static let bundleIdentifier = "jp.local.gitoperation"

    @MainActor
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        if let existingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existingApplication.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
