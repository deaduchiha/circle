import AppKit
import CoreProxy
import SwiftUI
import UniformTypeIdentifiers

struct RuleRowView: View {
  let rule: Rule

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: RuleFormatter.iconName(for: rule.type))
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 2) {
        Text(rule.type.rawValue)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(RuleFormatter.summary(rule))
          .font(.caption)
          .lineLimit(2)
          .help(RuleFormatter.summary(rule))
      }
    }
    .padding(.vertical, 2)
  }
}

struct RulesSidebarSection: View {
  let rules: [Rule]
  var onTest: (() -> Void)?

  var body: some View {
    Section {
      if rules.isEmpty {
        Text("No rules loaded")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(rules) { rule in
          RuleRowView(rule: rule)
        }
      }

      if let onTest {
        Button(action: onTest) {
          Label("Test Rule…", systemImage: "questionmark.circle")
        }
        .font(.caption)
      }
    } header: {
      HStack {
        Text("Rules")
        Spacer()
        Text("\(rules.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct RuleTesterView: View {
  @EnvironmentObject private var controller: ProxyController
  @State private var host = "api.example.com"
  @State private var path = "/"
  @State private var result: RuleTestResult?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Test which rule matches a host before sending traffic through the proxy.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("Host", text: $host)
          .textFieldStyle(.roundedBorder)
        TextField("Path", text: $path)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
        Button("Test") {
          result = controller.testRule(host: host, path: path)
        }
        .keyboardShortcut(.return, modifiers: [])
      }

      if let result {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Policy", value: result.policy)
            LabeledContent("Route", value: result.routeDescription)
            LabeledContent("Matched Rule") {
              Text(result.ruleSummary ?? "No rule matched (defaults to DIRECT)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      HStack {
        Button("Flush Rule Cache") {
          controller.flushRuleCache()
        }
        Spacer()
        Text("\(controller.profile.rules.count) rules loaded")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct RulesProfileView: View {
  let rules: [Rule]

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(rules) { rule in
          RuleRowView(rule: rule)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(.vertical, 4)
    }
    .frame(minHeight: 180, maxHeight: 260)
  }
}

struct PolicyBadge: View {
  let policy: String

  var body: some View {
    Text(policy)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(backgroundColor.opacity(0.15))
      .foregroundStyle(backgroundColor)
      .clipShape(Capsule())
  }

  private var backgroundColor: Color {
    switch policy.uppercased() {
    case "DIRECT":
      .green
    case "REJECT", "REJECT-TINYGIF":
      .red
    default:
      .blue
    }
  }
}

struct ProfileDocumentActions: View {
  @EnvironmentObject private var controller: ProxyController
  @State private var importError: String?

  var body: some View {
    HStack {
      Button("Import Profile…") {
        importProfile()
      }
      Button("Export Profile…") {
        exportProfile()
      }
      Spacer()
    }

    if let importError {
      Text(importError)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private func importProfile() {
    let panel = NSOpenPanel()
    panel.title = "Import Profile"
    panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      try controller.loadProfile(text: text)
      importError = nil
    } catch {
      importError = error.localizedDescription
    }
  }

  private func exportProfile() {
    let panel = NSSavePanel()
    panel.title = "Export Profile"
    panel.nameFieldStringValue = exportFilename()
    panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]

    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try controller.exportProfile().write(to: url, atomically: true, encoding: .utf8)
      importError = nil
    } catch {
      importError = error.localizedDescription
    }
  }

  private func exportFilename() -> String {
    if let activeID = controller.activeProfileID,
      let document = controller.profileDocuments.first(where: { $0.id == activeID })
    {
      return "\(document.name).conf"
    }
    return "profile.conf"
  }
}
