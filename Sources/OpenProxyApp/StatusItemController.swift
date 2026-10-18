import AppKit
import OpenProxyAppModel
import OpenProxyCore

/// Owns the menu bar item. Left click shows a native `NSMenu` with the policy, stats and
/// status rows; right click (or control-click) shows the app-management menu. Both are built
/// fresh on every click so the checkmarks and values reflect the current state.
/// `MenuBarExtra` cannot see right clicks, so the item is built with AppKit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
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
    }

    /// The 5 s refresh loop runs only while the left-click menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        model?.menuVisibilityChanged(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        model?.menuVisibilityChanged(false)
    }

    @objc private func handleClick() {
        guard let model else {
            popUp(startupErrorMenu())
            return
        }
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        popUp(rightClick ? controlMenu(model) : mainMenu(model))
    }

    /// Attaching the menu and clicking makes AppKit pop it natively; detaching it again keeps
    /// the next left click on the left-click menu.
    private func popUp(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Left click

    private func mainMenu(_ model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(submenu("Sort") { sub in
            for mode in SortMode.allCases {
                let item = self.menuItem(
                    mode.displayName, action: #selector(self.selectSort(_:)),
                    on: model.settings.sort == mode)
                item.representedObject = mode
                sub.addItem(item)
            }
        })

        menu.addItem(submenu("Tier") { sub in
            for mode in TierMode.allCases {
                let item = self.menuItem(
                    mode.rawValue.capitalized, action: #selector(self.selectTier(_:)),
                    on: model.settings.tier == mode)
                item.representedObject = mode
                sub.addItem(item)
            }
            if model.settings.tier == .flex {
                self.addFlexItems(to: sub, flex: model.settings.flex)
            }
        })

        let minutes = model.settings.pollMinutes
        menu.addItem(submenu("Refresh every \(minutes) min") { sub in
            for choice in MenuContent.minuteChoices(current: minutes) {
                let item = self.menuItem(
                    "\(choice) min", action: #selector(self.selectPollMinutes(_:)),
                    on: choice == minutes)
                item.representedObject = choice
                sub.addItem(item)
            }
        })

        menu.addItem(.separator())
        menu.addItem(submenu("Stats (24h)") { sub in
            for line in MenuContent.statsLines(model.summary) {
                sub.addItem(self.row(line))
            }
        })
        menu.addItem(submenu("Status") { sub in
            for line in MenuContent.statusLines(
                model.status,
                loginItem: model.loginItemStatus,
                helper: model.helperStatus,
                routingLabel: model.routingLabel) {
                sub.addItem(self.row(line))
            }
        })
        for line in MenuContent.warningLines(
            unreachable: model.unreachableWarning,
            untrustedCA: model.untrustedCAWarning,
            warnings: model.warnings) {
            menu.addItem(row(line))
        }

        if model.canRetrySetup {
            menu.addItem(.separator())
            menu.addItem(menuItem("Retry setup", action: #selector(retrySetup)))
        }
        return menu
    }

    /// The flex policy rows, appended to the Tier submenu after the tier choices.
    private func addFlexItems(to sub: NSMenu, flex: FlexPolicy) {
        sub.addItem(.separator())
        sub.addItem(menuItem(
            "Fallback without flex", action: #selector(toggleFlexFallback), on: flex.fallback))
        sub.addItem(submenu("Attempts: \(flex.attempts)") { attempts in
            for count in 1...5 {
                let item = self.menuItem(
                    "\(count)", action: #selector(self.selectAttempts(_:)),
                    on: count == flex.attempts)
                item.representedObject = count
                attempts.addItem(item)
            }
        })
        sub.addItem(timeoutMenu(
            "First byte (s)", current: flex.firstByteTimeout,
            action: #selector(selectFirstByteTimeout(_:))))
        sub.addItem(timeoutMenu(
            "Non-streaming (s)", current: flex.nonStreamingTimeout,
            action: #selector(selectNonStreamingTimeout(_:))))
    }

    private func timeoutMenu(_ title: String, current: Double, action: Selector) -> NSMenuItem {
        submenu(title) { sub in
            for seconds in MenuContent.timeoutChoices(current: current) {
                let item = self.menuItem(
                    Self.secondsTitle(seconds), action: action, on: seconds == current)
                item.representedObject = seconds
                sub.addItem(item)
            }
        }
    }

    private static func secondsTitle(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds))" : "\(seconds)"
    }

    // MARK: - Right click

    private func controlMenu(_ model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(
            "Enabled", action: #selector(toggleEnabled), on: model.settings.enabled))
        menu.addItem(menuItem(
            "Start at login", action: #selector(toggleStartAtLogin),
            on: model.loginItemStatus == .enabled))
        menu.addItem(.separator())
        menu.addItem(menuItem("Uninstall OpenProxy...", action: #selector(uninstallOpenProxy)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit OpenProxy", action: #selector(quitOpenProxy)))
        return menu
    }

    // MARK: - Startup error

    private func startupErrorMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(header("openproxy could not start"))
        for part in MenuContent.wrapped(startupError ?? "Unknown error") {
            menu.addItem(viewItem(part, color: .systemOrange))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", action: #selector(terminateApp)))
        return menu
    }

    // MARK: - Item builders

    private func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false
        build(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func menuItem(_ title: String, action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private static let rowMaxWidth: CGFloat = 300
    private static let rowInset: CGFloat = 14
    private static let rowVerticalPadding: CGFloat = 3

    private func header(_ title: String) -> NSMenuItem {
        viewItem(title, bold: true, color: .labelColor)
    }

    private func row(_ line: MenuLine) -> NSMenuItem {
        let prefix: String
        switch line.marker {
        case .check: prefix = "✓ "
        case .cross: prefix = "✗ "
        case .alert: prefix = "⚠︎ "
        case .bullet, .none: prefix = ""
        }
        return viewItem(prefix + line.text, color: line.warning ? .systemOrange : .labelColor)
    }

    /// A non-actionable informational row. A view is never highlighted nor dimmed, unlike an
    /// item title, so the label always reads at full contrast.
    private func viewItem(_ text: String, bold: Bool = false, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = rowView(text, bold: bold, color: color)
        return item
    }

    private func rowView(_ text: String, bold: Bool, color: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.menuFont(ofSize: 0)
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.rowMaxWidth - Self.rowInset * 2
        let textSize = label.fittingSize
        let textWidth = min(textSize.width, Self.rowMaxWidth - Self.rowInset * 2)

        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: min(textWidth + Self.rowInset * 2, Self.rowMaxWidth),
            height: textSize.height + Self.rowVerticalPadding * 2))
        label.frame = NSRect(
            x: Self.rowInset, y: Self.rowVerticalPadding, width: textWidth, height: textSize.height)
        container.addSubview(label)
        return container
    }

    // MARK: - Actions

    @objc private func selectSort(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? SortMode else { return }
        model?.settings.sort = mode
    }

    @objc private func selectTier(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? TierMode else { return }
        model?.settings.tier = mode
    }

    @objc private func selectPollMinutes(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        model?.settings.pollMinutes = minutes
    }

    @objc private func toggleFlexFallback() {
        model?.settings.flex.fallback.toggle()
    }

    @objc private func selectAttempts(_ sender: NSMenuItem) {
        guard let count = sender.representedObject as? Int else { return }
        model?.settings.flex.attempts = count
    }

    @objc private func selectFirstByteTimeout(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        model?.settings.flex.firstByteTimeout = seconds
    }

    @objc private func selectNonStreamingTimeout(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        model?.settings.flex.nonStreamingTimeout = seconds
    }

    @objc private func retrySetup() {
        Task { await model?.retrySetup() }
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

    /// The startup-error menu has no model, so its Quit terminates directly.
    @objc private func terminateApp() {
        NSApplication.shared.terminate(nil)
    }
}
