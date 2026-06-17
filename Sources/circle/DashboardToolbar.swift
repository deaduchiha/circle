import AppKit
import CoreProxy
import SwiftUI

enum DashboardPanel: String, Identifiable {
  case settings
  case profiles
  case policies
  case rules
  case dns
  case mitm

  var id: String { rawValue }

  var title: String {
    switch self {
    case .settings: "Settings"
    case .profiles: "Profiles"
    case .policies: "Policy Groups"
    case .rules: "Rule Tester"
    case .dns: "DNS"
    case .mitm: "HTTPS Decryption"
    }
  }
}

struct DashboardToolbarItems: View {
  @Binding var activePanel: DashboardPanel?

  var body: some View {
    EmptyView()
  }
}

struct DashboardPanelSheet: View {
  @EnvironmentObject private var controller: ProxyController
  @Environment(\.dismiss) private var dismiss
  let panel: DashboardPanel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(panel.title)
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.escape, modifiers: [])
      }
      .padding()

      Divider()

      panelContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: panelSize.width, minHeight: panelSize.height)
    .onAppear {
      if panel == .mitm || panel == .settings {
        controller.refreshMITMStatus()
      }
    }
  }

  @ViewBuilder
  private var panelContent: some View {
    switch panel {
    case .settings:
      SettingsView()
        .environmentObject(controller)
    case .profiles:
      ScrollView {
        ProfileManagementView()
          .environmentObject(controller)
          .padding()
      }
    case .policies:
      ScrollView {
        PolicyGroupsSettingsView()
          .environmentObject(controller)
          .padding()
      }
    case .rules:
      ScrollView {
        RuleTesterView()
          .environmentObject(controller)
          .padding()
      }
    case .dns:
      ScrollView {
        DNSLookupView()
          .environmentObject(controller)
          .padding()
      }
    case .mitm:
      ScrollView {
        MITMSettingsPanel()
          .environmentObject(controller)
          .padding()
      }
    }
  }

  private var panelSize: CGSize {
    switch panel {
    case .settings: CGSize(width: 760, height: 680)
    case .profiles: CGSize(width: 780, height: 720)
    case .policies: CGSize(width: 520, height: 560)
    case .rules: CGSize(width: 560, height: 420)
    case .dns: CGSize(width: 620, height: 560)
    case .mitm: CGSize(width: 560, height: 480)
    }
  }
}

struct MITMSettingsPanel: View {
  @EnvironmentObject private var controller: ProxyController

  var body: some View {
    Form {
      Section("HTTPS Decryption") {
        Toggle("Enable HTTPS Decryption", isOn: Binding(
          get: { controller.profile.mitm.enabled },
          set: { controller.profile.mitm.enabled = $0 }
        ))

        if let status = controller.mitmCertificateStatus {
          LabeledContent("CA Name", value: status.commonName)
          LabeledContent("Trusted", value: status.isInstalledInKeychain ? "Yes" : "No")
        }

        HStack {
          Button("Generate CA") { controller.generateMITMCA() }
          Button("Install in Keychain") { controller.installMITMCA() }
            .disabled(controller.mitmCertificateStatus == nil)
        }
      }
    }
    .formStyle(.grouped)
  }
}

struct QuickStartCard: View {
  let onStart: () -> Void
  let onOpenRules: () -> Void
  let onOpenSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Get Started", systemImage: "sparkles")
        .font(.headline)

      Text("1. Click Start to enable the proxy on 127.0.0.1:8888")
      Text("2. Use Test Rule to check which policy matches a host")
      Text("3. Open Profiles to edit rules, proxies, and policy groups")
      Text("4. Enable HTTPS Decryption in the toolbar to inspect TLS traffic")

      HStack {
        Button("Start Proxy", action: onStart)
          .buttonStyle(.borderedProminent)
        Button("Test Rule", action: onOpenRules)
        Button("Settings", action: onOpenSettings)
      }
    }
    .font(.caption)
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

enum SettingsOpener {
  static func open() {
    if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }
}

extension Notification.Name {
  static let circleOpenPanel = Notification.Name("circleOpenPanel")
}
