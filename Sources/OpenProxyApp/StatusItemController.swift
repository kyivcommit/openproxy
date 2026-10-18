import AppKit
import SwiftUI
import OpenProxyAppModel

/// Owns the menu bar item. Left click toggles a transient popover with `MenuView`; right
/// click (or control-click) shows a native `NSMenu` with the app-management actions.
/// `MenuBarExtra` cannot see right clicks, so the item is built with AppKit.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel?
    private let startupError: String?

    init(model: AppModel?, startupError: String? = nil) {
        self.model = model
        self.startupError = startupError
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "OpenProxy")
            button.target = self
            button.action = #selector(handleClick)
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: menuContent)
    }

    /// `NSPopover` keeps its hosting view, so SwiftUI may not deliver `onDisappear` on close;
    /// stop the menu's refresh loop here. Safe to double up with `onDisappear`.
    func popoverDidClose(_ notification: Notification) {
        model?.menuVisibilityChanged(false)
    }

    @ViewBuilder private var menuContent: some View {
        if let model {
            MenuView(model: model)
        } else {
            startupErrorView
        }
    }

    /// Spec 9: the popover still appears with the reason when the graph could not be built.
    private var startupErrorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("openproxy could not start").font(.headline)
            Text(startupError ?? "Unknown error")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if rightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Built fresh on every right click so the checkmarks reflect the current state. Attaching
    /// it to the status item and clicking makes AppKit pop the native menu; detaching it again
    /// keeps left click on the popover.
    private func showContextMenu() {
        guard let model else { return }
        let menu = NSMenu()
        menu.addItem(menuItem(
            "Enabled", action: #selector(toggleEnabled),
            on: model.settings.enabled))
        menu.addItem(menuItem(
            "Start at login", action: #selector(toggleStartAtLogin),
            on: model.loginItemStatus == .enabled))
        menu.addItem(.separator())
        menu.addItem(menuItem("Uninstall OpenProxy...", action: #selector(uninstallOpenProxy)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit OpenProxy", action: #selector(quitOpenProxy)))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleEnabled() {
        model?.settings.enabled.toggle()
    }

    @objc private func toggleStartAtLogin() {
        guard let model else { return }
        let on = model.loginItemStatus != .enabled
        Task { await model.setStartAtLogin(on) }
    }

    @objc private func uninstallOpenProxy() {
        Task { await model?.uninstallOpenProxy() }
    }

    @objc private func quitOpenProxy() {
        Task { await model?.quit() }
    }
}
