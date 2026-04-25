import AppKit
import MeetingAgentCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var supportsUserNotifications = false
    var viewModel: MeetingAgentViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        supportsUserNotifications = AppRuntimeCapabilities.supportsUserNotifications()
        if supportsUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        configureStatusItem()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Meeting"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Meeting Agent", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Idle", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func notifyMeetingDetected(_ target: AudioCaptureTarget) {
        guard supportsUserNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "\(target.displayName) meeting detected. Open Meeting Agent to start recording."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "meeting-detected-\(target.processID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
