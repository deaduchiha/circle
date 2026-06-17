import AppKit
import CoreProxy
import SwiftUI

enum ProfileSyntaxHighlighter {
  private static let ruleTypes = Set(RuleType.allCases.map(\.rawValue))

  static func apply(to textStorage: NSTextStorage, in range: NSRange) {
    let text = textStorage.string as NSString
    let paragraphRange = text.paragraphRange(for: range)

    textStorage.removeAttribute(.foregroundColor, range: paragraphRange)
    textStorage.addAttribute(
      .foregroundColor,
      value: NSColor.labelColor,
      range: paragraphRange
    )
    textStorage.addAttribute(
      .font,
      value: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
      range: paragraphRange
    )

    text.enumerateSubstrings(in: paragraphRange, options: [.byLines, .substringNotRequired]) {
      substring,
      substringRange,
      _,
      _ in
      guard let line = substring else { return }
      highlight(line: line, range: substringRange, in: textStorage)
    }
  }

  private static func highlight(line: String, range: NSRange, in textStorage: NSTextStorage) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
      textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
      return
    }

    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
      textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
      textStorage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: range)
      return
    }

    if trimmed.hasPrefix("#!include") {
      textStorage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
      return
    }

    if trimmed.contains("=") && !trimmed.contains(",") {
      highlightKeyValue(line: line, range: range, in: textStorage)
      return
    }

    highlightRuleLine(line: line, range: range, in: textStorage)
  }

  private static func highlightKeyValue(line: String, range: NSRange, in textStorage: NSTextStorage) {
    let nsLine = line as NSString
    let equalsRange = nsLine.range(of: "=")
    guard equalsRange.location != NSNotFound else { return }

    let keyRange = NSRange(location: range.location, length: equalsRange.location)
    textStorage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: keyRange)
  }

  private static func highlightRuleLine(line: String, range: NSRange, in textStorage: NSTextStorage) {
    let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first else { return }

    let token = first.trimmingCharacters(in: .whitespaces)
    if ruleTypes.contains(token.uppercased()) {
      let tokenStart = (line as NSString).range(of: token)
      let absolute = NSRange(location: range.location + tokenStart.location, length: tokenStart.length)
      textStorage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: absolute)
    }
  }
}

struct ProfileSyntaxTextEditor: NSViewRepresentable {
  @Binding var text: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else {
      return scrollView
    }

    textView.isRichText = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.delegate = context.coordinator
    textView.string = text
    context.coordinator.textView = textView
    ProfileSyntaxHighlighter.apply(to: textView.textStorage!, in: NSRange(location: 0, length: text.utf16.count))

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    if textView.string != text {
      textView.string = text
      ProfileSyntaxHighlighter.apply(
        to: textView.textStorage!,
        in: NSRange(location: 0, length: text.utf16.count)
      )
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    weak var textView: NSTextView?

    init(text: Binding<String>) {
      _text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
      ProfileSyntaxHighlighter.apply(
        to: textView.textStorage!,
        in: NSRange(location: 0, length: textView.string.utf16.count)
      )
    }
  }
}

struct ProfileModuleTogglesView: View {
  @EnvironmentObject private var controller: ProxyController

  private var modules: ProfileModuleSettings {
    controller.profileDocuments.first { $0.id == controller.activeProfileID }?.modules ?? .allEnabled
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      moduleToggle("Proxies", keyPath: \.proxies)
      moduleToggle("Policy Groups", keyPath: \.proxyGroups)
      moduleToggle("Rules", keyPath: \.rules)
      moduleToggle("Hosts", keyPath: \.hosts)
      moduleToggle("DNS", keyPath: \.dns)
      moduleToggle("MITM", keyPath: \.mitm)
      moduleToggle("Scripts", keyPath: \.scripts)
    }
  }

  private func moduleToggle(_ title: String, keyPath: WritableKeyPath<ProfileModuleSettings, Bool>) -> some View {
    Toggle(title, isOn: Binding(
      get: { modules[keyPath: keyPath] },
      set: { newValue in
        var updated = modules
        updated[keyPath: keyPath] = newValue
        try? controller.updateProfileModules(updated)
      }
    ))
  }
}

struct ProfileManagementView: View {
  @EnvironmentObject private var controller: ProxyController
  @State private var selectedProfileID: UUID?
  @State private var renameDraft = ""
  @State private var importURL = ""
  @State private var importName = ""
  @State private var actionError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker("Profile", selection: Binding(
          get: { selectedProfileID ?? controller.activeProfileID },
          set: { newID in
            selectedProfileID = newID
            if let newID {
              try? controller.selectProfile(id: newID)
            }
          }
        )) {
          ForEach(controller.profileDocuments) { document in
            Text(document.name).tag(Optional(document.id))
          }
        }

        Button("New") { createProfile() }
        Button("Duplicate") { duplicateProfile() }
          .disabled(selectedProfileID == nil && controller.activeProfileID == nil)
        Button("Delete") { deleteProfile() }
          .disabled(controller.profileDocuments.count <= 1)
      }

      HStack {
        TextField("Rename profile", text: $renameDraft)
          .textFieldStyle(.roundedBorder)
        Button("Rename") { renameProfile() }
          .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      HStack {
        TextField("Import URL", text: $importURL)
          .textFieldStyle(.roundedBorder)
        TextField("Name", text: $importName)
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
        Button("Import URL") { importRemoteProfile() }
          .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      ProfileDocumentActions()

      Toggle("Sync profiles with iCloud", isOn: Binding(
        get: { controller.iCloudSyncEnabled },
        set: { controller.setiCloudSyncEnabled($0) }
      ))

      ProfileModuleTogglesView()

      HStack {
        Text("Profile Editor").font(.headline)
        Spacer()
        Button("Save") { saveEditor() }
          .keyboardShortcut("s", modifiers: .command)
      }

      ProfileSyntaxTextEditor(text: $controller.profileEditorText)
        .frame(minHeight: 220)
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.25))
        }

      if let actionError {
        Text(actionError).font(.caption).foregroundStyle(.red)
      }
    }
    .onAppear {
      selectedProfileID = controller.activeProfileID
      renameDraft = currentDocument?.name ?? ""
    }
    .onChange(of: controller.activeProfileID) { newID in
      selectedProfileID = newID
      renameDraft = currentDocument?.name ?? ""
    }
  }

  private var currentDocument: ProfileDocument? {
    let id = selectedProfileID ?? controller.activeProfileID
    return controller.profileDocuments.first { $0.id == id }
  }

  private func createProfile() {
    do {
      try controller.createProfile(name: "New Profile")
      selectedProfileID = controller.activeProfileID
      renameDraft = currentDocument?.name ?? ""
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func duplicateProfile() {
    guard let id = selectedProfileID ?? controller.activeProfileID else { return }
    do {
      try controller.duplicateProfile(id: id)
      selectedProfileID = controller.activeProfileID
      renameDraft = currentDocument?.name ?? ""
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func renameProfile() {
    guard let id = selectedProfileID ?? controller.activeProfileID else { return }
    do {
      try controller.renameProfile(id: id, name: renameDraft)
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func deleteProfile() {
    guard let id = selectedProfileID ?? controller.activeProfileID else { return }
    do {
      try controller.deleteProfile(id: id)
      selectedProfileID = controller.activeProfileID
      renameDraft = currentDocument?.name ?? ""
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func importRemoteProfile() {
    controller.importProfileFromURL(
      importURL,
      name: importName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    )
    importURL = ""
    importName = ""
  }

  private func saveEditor() {
    do {
      try controller.saveProfileEditor()
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
