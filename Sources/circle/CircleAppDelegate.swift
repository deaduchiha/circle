import AppKit

@MainActor
final class CircleAppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.activate(ignoringOtherApps: true)
    bringMainWindowToFront(retry: 0)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      bringMainWindowToFront(retry: 0)
    }
    return true
  }

  private func bringMainWindowToFront(retry: Int) {
    for window in NSApp.windows where window.canBecomeMain && !window.isMiniaturized {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    guard retry < 20 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.bringMainWindowToFront(retry: retry + 1)
    }
  }
}
