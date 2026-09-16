import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, NSMenuItemValidation {
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )

    func addMenuItems(to menu: NSMenu) {
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let preferences = NSMenu(title: "Updates")
        for item in [
            NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutomaticChecks), keyEquivalent: ""),
            NSMenuItem(title: "Automatically Download and Install", action: #selector(toggleAutomaticDownloads), keyEquivalent: "")
        ] {
            item.target = self
            preferences.addItem(item)
        }
        let item = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        item.submenu = preferences
        menu.addItem(item)
    }

    func start() {
        guard !started, Bundle.main.object(forInfoDictionaryKey: "ModRadioUpdatesEnabled") as? Bool == true else { return }
        started = true
        controller.startUpdater()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard started else { return false }
        switch menuItem.action {
        case #selector(checkForUpdates):
            return controller.updater.canCheckForUpdates
        case #selector(toggleAutomaticChecks):
            menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
            return true
        case #selector(toggleAutomaticDownloads):
            menuItem.state = controller.updater.automaticallyDownloadsUpdates ? .on : .off
            return controller.updater.allowsAutomaticUpdates
        default:
            return false
        }
    }

    @objc private func checkForUpdates() {
        guard started else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticChecks() {
        guard started else { return }
        controller.updater.automaticallyChecksForUpdates.toggle()
    }

    @objc private func toggleAutomaticDownloads() {
        guard started, controller.updater.allowsAutomaticUpdates else { return }
        controller.updater.automaticallyDownloadsUpdates.toggle()
    }
}
