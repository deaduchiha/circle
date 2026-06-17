import AppKit
import CoreProxy
import SwiftUI

@MainActor
final class StatusBarController {
  private let statusItem: NSStatusItem
  private weak var controller: ProxyController?

  init(controller: ProxyController) {
    self.controller = controller
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    configure()
  }

  func update() {
    guard let controller else { return }
    statusItem.button?.image = NSImage(
      systemSymbolName: controller.state == .running ? "network" : "network.slash",
      accessibilityDescription: "circle"
    )
    statusItem.menu = makeMenu()
  }

  private func configure() {
    statusItem.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "circle")
    statusItem.menu = makeMenu()
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()

    let toggleTitle: String
    if let controller {
      toggleTitle = controller.state == .running ? "Stop Proxy" : "Start Proxy"
    } else {
      toggleTitle = "Start Proxy"
    }

    menu.addItem(
      withTitle: toggleTitle,
      action: #selector(toggleProxy),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Open Dashboard",
      action: #selector(openDashboard),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Test Rule…",
      action: #selector(openRuleTester),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Edit Profiles…",
      action: #selector(openProfiles),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Settings…",
      action: #selector(openSettings),
      keyEquivalent: ","
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit",
      action: #selector(quit),
      keyEquivalent: "q"
    )

    for item in menu.items {
      item.target = self
    }

    return menu
  }

  @objc private func openRuleTester() {
    postPanel(.rules)
  }

  @objc private func openProfiles() {
    postPanel(.profiles)
  }

  @objc private func openSettings() {
    postPanel(.settings)
  }

  private func postPanel(_ panel: DashboardPanel) {
    NotificationCenter.default.post(
      name: .circleOpenPanel,
      object: nil,
      userInfo: ["panel": panel.rawValue]
    )
    openDashboard()
  }

  @objc private func toggleProxy() {
    guard let controller else { return }
    if controller.state == .running {
      controller.stop()
    } else {
      controller.start()
    }
    update()
  }

  @objc private func openDashboard() {
    NSApp.activate(ignoringOtherApps: true)
    for window in NSApp.windows where window.canBecomeMain {
      window.makeKeyAndOrderFront(nil)
      return
    }
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

private enum StatusBarHolder {
  @MainActor static var controller: StatusBarController?
}

struct StatusBarInstaller: NSViewRepresentable {
  let controller: ProxyController

  func makeNSView(context: Context) -> NSView {
    if StatusBarHolder.controller == nil {
      StatusBarHolder.controller = StatusBarController(controller: controller)
    }
    StatusBarHolder.controller?.update()
    return NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    StatusBarHolder.controller?.update()
  }
}
