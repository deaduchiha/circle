import CoreProxy
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CircleApp: App {
    @NSApplicationDelegateAdaptor(CircleAppDelegate.self) private var appDelegate
    @StateObject private var controller = ProxyController()

    var body: some Scene {
        WindowGroup("circle") {
            DashboardView()
                .environmentObject(controller)
                .frame(minWidth: 1120, minHeight: 720)
                .background(StatusBarInstaller(controller: controller))
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Test Rule…") {
                    NotificationCenter.default.post(
                        name: .circleOpenPanel,
                        object: nil,
                        userInfo: ["panel": DashboardPanel.rules.rawValue]
                    )
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Edit Profiles…") {
                    NotificationCenter.default.post(
                        name: .circleOpenPanel,
                        object: nil,
                        userInfo: ["panel": DashboardPanel.profiles.rawValue]
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}


struct DashboardView: View {
    @EnvironmentObject private var controller: ProxyController
    @State private var selection: TrafficRequest.ID?
    @State private var query = ""
    @State private var policyFilter = "All"
    @State private var statusFilter = "All"
    @State private var activePanel: DashboardPanel?

    private var policyOptions: [String] {
        var options = Set(controller.requests.map(\.policy))
        options.formUnion(controller.profile.proxyGroups.map(\.name))
        options.insert("DIRECT")
        options.insert("REJECT")
        return ["All"] + options.sorted()
    }

    private var filteredRequests: [TrafficRequest] {
        controller.requests.filter { request in
            let matchesQuery = query.isEmpty
                || request.host.localizedCaseInsensitiveContains(query)
                || request.path.localizedCaseInsensitiveContains(query)
                || request.policy.localizedCaseInsensitiveContains(query)

            let matchesPolicy = policyFilter == "All" || request.policy == policyFilter

            let matchesStatus: Bool
            switch statusFilter {
            case "2xx":
                matchesStatus = (200...299).contains(request.statusCode ?? -1)
            case "3xx":
                matchesStatus = (300...399).contains(request.statusCode ?? -1)
            case "4xx":
                matchesStatus = (400...499).contains(request.statusCode ?? -1)
            case "5xx":
                matchesStatus = (500...599).contains(request.statusCode ?? -1)
            case "Errors":
                matchesStatus = request.statusCode == nil || (request.statusCode ?? 0) >= 400
            default:
                matchesStatus = true
            }

            return matchesQuery && matchesPolicy && matchesStatus
        }
    }

    private var selectedRequest: TrafficRequest? {
        filteredRequests.first { $0.id == selection } ?? filteredRequests.first
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            VStack(spacing: 0) {
                ToolbarView(
                    query: $query,
                    policyFilter: $policyFilter,
                    statusFilter: $statusFilter,
                    policyOptions: policyOptions
                )
                BandwidthGraphView(samples: controller.bandwidthSamples)
                    .padding(.vertical, 8)
                RequestTableView(requests: filteredRequests, selection: $selection)
            }
        } detail: {
            RequestDetailView(
                request: selectedRequest,
                onStart: { controller.start() },
                onOpenRules: { activePanel = .rules },
                onOpenSettings: { activePanel = .settings }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if let profile = controller.profileDocuments.first(where: { $0.id == controller.activeProfileID }) {
                    Text(profile.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    controller.state == .running ? controller.stop() : controller.start()
                } label: {
                    Label(
                        controller.state == .running ? "Stop" : "Start",
                        systemImage: controller.state == .running ? "pause.fill" : "play.fill"
                    )
                }
                .help(controller.state == .running ? "Stop proxy" : "Start proxy on 127.0.0.1:8888")

                Button { activePanel = .rules } label: {
                    Label("Test Rule", systemImage: "questionmark.circle")
                }
                .help("Test which rule matches a host")

                Button { activePanel = .dns } label: {
                    Label("DNS", systemImage: "globe")
                }
                .help("DNS lookup and cache inspector")

                Button { activePanel = .policies } label: {
                    Label("Policies", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Manage policy groups and latency tests")

                Button { activePanel = .profiles } label: {
                    Label("Profiles", systemImage: "doc.text")
                }
                .help("Edit profiles, rules, and proxies")

                Button { activePanel = .mitm } label: {
                    Label("HTTPS", systemImage: "lock.shield")
                }
                .help("HTTPS decryption (MITM)")

                Button { activePanel = .settings } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("GeoIP, import/export, and more")
            }
        }
        .sheet(item: $activePanel) { panel in
            DashboardPanelSheet(panel: panel)
                .environmentObject(controller)
        }
        .onReceive(NotificationCenter.default.publisher(for: .circleOpenPanel)) { notification in
            if let raw = notification.userInfo?["panel"] as? String,
               let panel = DashboardPanel(rawValue: raw) {
                activePanel = panel
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var controller: ProxyController
    @State private var activePanel: DashboardPanel?

    var body: some View {
        List {
            Section("Proxy") {
                StatusRow(title: "State", value: controller.state.rawValue.capitalized)
                if let error = controller.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                StatusRow(title: "HTTP", value: "127.0.0.1:\(controller.profile.general.httpPort)")
                StatusRow(title: "Dashboard", value: "127.0.0.1:\(controller.profile.general.dashboardPort)")
                if let profile = controller.profileDocuments.first(where: { $0.id == controller.activeProfileID }) {
                    HStack {
                        Text("Profile")
                        Spacer()
                        Text(profile.name)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if controller.state != .running {
                Section {
                    QuickStartCard(
                        onStart: { controller.start() },
                        onOpenRules: { activePanel = .rules },
                        onOpenSettings: { activePanel = .profiles }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }

            Section("Quick Actions") {
                Button {
                    activePanel = .rules
                } label: {
                    Label("Test Rule", systemImage: "questionmark.circle")
                }
                Button {
                    activePanel = .dns
                } label: {
                    Label("DNS Lookup", systemImage: "globe")
                }
                Button {
                    activePanel = .policies
                } label: {
                    Label("Policy Groups", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button {
                    activePanel = .profiles
                } label: {
                    Label("Edit Profile", systemImage: "doc.text")
                }
                Button {
                    activePanel = .mitm
                } label: {
                    Label("HTTPS Decryption", systemImage: "lock.shield")
                }
                Button {
                    activePanel = .settings
                } label: {
                    Label("Settings & GeoIP", systemImage: "gearshape")
                }
            }

            Section("Policies") {
                PolicyGroupsSidebarSection(onManage: { activePanel = .policies })
                Label("DIRECT", systemImage: "arrow.right")
                Label("REJECT", systemImage: "xmark.octagon")
            }

            RulesSidebarSection(rules: controller.profile.rules, onTest: { activePanel = .rules })
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    controller.state == .running ? controller.stop() : controller.start()
                } label: {
                    Label(controller.state == .running ? "Stop" : "Start", systemImage: controller.state == .running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    activePanel = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .padding()
        }
        .sheet(item: $activePanel) { panel in
            DashboardPanelSheet(panel: panel)
                .environmentObject(controller)
        }
    }
}

struct ToolbarView: View {
    @EnvironmentObject private var controller: ProxyController
    @Binding var query: String
    @Binding var policyFilter: String
    @Binding var statusFilter: String
    let policyOptions: [String]

    private let statusOptions = ["All", "2xx", "3xx", "4xx", "5xx", "Errors"]

    var body: some View {
        HStack(spacing: 12) {
            TextField("Filter host, path, or policy", text: $query)
                .textFieldStyle(.roundedBorder)

            Picker("Policy", selection: $policyFilter) {
                ForEach(policyOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .frame(width: 140)

            Picker("Status", selection: $statusFilter) {
                ForEach(statusOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .frame(width: 100)

            Button {
                controller.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
        .padding()
        .background(.bar)
    }
}

struct RequestTableView: View {
    let requests: [TrafficRequest]
    @Binding var selection: TrafficRequest.ID?

    var body: some View {
        Table(requests, selection: $selection) {
            TableColumn("Time") { request in
                Text(request.timestamp, format: .dateTime.hour().minute().second())
            }
            .width(88)
            TableColumn("Method", value: \.method)
                .width(72)
            TableColumn("Host", value: \.host)
            TableColumn("Path", value: \.path)
            TableColumn("Status") { request in
                Text(request.statusCode.map(String.init) ?? "-")
            }
            .width(64)
            TableColumn("Size") { request in
                Text(formatBytes(request.bytesIn + request.bytesOut))
            }
            .width(72)
            TableColumn("Policy") { request in
                PolicyBadge(policy: request.policy)
            }
            .width(100)
            TableColumn("Rule") { request in
                Text(request.matchedRule ?? "-")
                    .lineLimit(1)
                    .help(request.matchedRule ?? "")
            }
            .width(min: 120, ideal: 180)
            TableColumn("Latency") { request in
                Text(request.latencyMilliseconds.map { "\($0) ms" } ?? "-")
            }
            .width(80)
        }
    }

    private func formatBytes(_ value: Int) -> String {
        if value < 1024 { return "\(value) B" }
        return String(format: "%.1f KB", Double(value) / 1024.0)
    }
}

struct RequestDetailView: View {
    let request: TrafficRequest?
    var onStart: (() -> Void)?
    var onOpenRules: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let request {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.host)
                                .font(.title2.weight(.semibold))
                            Text("\(request.method) \(request.path)")
                                .foregroundStyle(.secondary)
                            Text(request.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PolicyBadge(policy: request.policy)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        DetailCell("Status", request.statusCode.map(String.init) ?? "-")
                        DetailCell("Route", request.policy)
                        DetailCell("Bytes In", "\(request.bytesIn)")
                        DetailCell("Bytes Out", "\(request.bytesOut)")
                        DetailCell("Latency", request.latencyMilliseconds.map { "\($0) ms" } ?? "-")
                    }

                    if let matchedRule = request.matchedRule {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Matched Rule")
                                .font(.headline)
                            Text(matchedRule)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let timing = request.detail?.timing {
                        Divider()
                        Text("Timing")
                            .font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            DetailCell("TCP Connect", timing.tcpConnectMilliseconds.map { "\($0) ms" } ?? "-")
                            DetailCell("TLS", timing.tlsMilliseconds.map { "\($0) ms" } ?? "-")
                            DetailCell("TTFB", timing.ttfbMilliseconds.map { "\($0) ms" } ?? "-")
                            DetailCell("Total", timing.totalMilliseconds.map { "\($0) ms" } ?? "-")
                        }
                    }

                    if let detail = request.detail {
                        Divider()
                        HeaderSection(title: "Request Headers", headers: detail.requestHeaders)
                        BodySection(title: "Request Body", bodyText: detail.requestBody)
                        HeaderSection(title: "Response Headers", headers: detail.responseHeaders)
                        BodySection(title: "Response Body", bodyText: detail.responseBody)
                    } else {
                        Divider()
                        Text("Inspector")
                            .font(.headline)
                        Text("Full headers and bodies appear for decrypted HTTPS requests.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "network")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("No Requests")
                            .font(.headline)
                        Text("Start the proxy to capture traffic from apps using the system proxy.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if let onStart, let onOpenRules, let onOpenSettings {
                            QuickStartCard(
                                onStart: onStart,
                                onOpenRules: onOpenRules,
                                onOpenSettings: onOpenSettings
                            )
                            .frame(maxWidth: 420)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .padding()
                }
            }
            .padding(24)
        }
    }
}

struct HeaderSection: View {
    let title: String
    let headers: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if headers.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(headers.keys.sorted(), id: \.self) { key in
                    Text("\(key): \(headers[key] ?? "")")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct BodySection: View {
    let title: String
    let bodyText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if let bodyText, !bodyText.isEmpty {
                Text(bodyText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Empty")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DetailCell: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: ProxyController

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            profilesTab
                .tabItem { Label("Profiles", systemImage: "doc.text") }
            policyGroupsTab
                .tabItem { Label("Policies", systemImage: "point.3.connected.trianglepath.dotted") }
            rulesTab
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            dnsTab
                .tabItem { Label("DNS", systemImage: "globe") }
            mitmTab
                .tabItem { Label("MITM", systemImage: "lock.shield") }
        }
        .padding()
        .frame(width: 760, height: 680)
        .onAppear {
            controller.refreshMITMStatus()
        }
    }

    private var generalTab: some View {
        Form {
            Section("Proxy") {
                LabeledContent("HTTP Port", value: "\(controller.profile.general.httpPort)")
                LabeledContent("Dashboard Port", value: "\(controller.profile.general.dashboardPort)")
                LabeledContent("Log Level", value: controller.profile.general.logLevel)
                LabeledContent("State", value: controller.state.rawValue.capitalized)
            }

            Section("GeoIP") {
                LabeledContent("Database Loaded", value: controller.geoIPStatus.isLoaded ? "Yes" : "No")
                if let path = controller.geoIPStatus.databasePath {
                    LabeledContent("Database Path") {
                        Text((path as NSString).lastPathComponent)
                            .font(.caption)
                            .textSelection(.enabled)
                            .help(path)
                    }
                }
                if let modifiedAt = controller.geoIPStatus.modifiedAt {
                    LabeledContent("Last Updated", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Needs Refresh", value: controller.geoIPStatus.isStale ? "Yes" : "No")

                SecureField("MaxMind License Key", text: Binding(
                    get: { controller.profile.general.geolite2LicenseKey ?? "" },
                    set: { controller.setGeoLite2LicenseKey($0.isEmpty ? nil : $0) }
                ))

                HStack {
                    Button("Update GeoIP Database") {
                        controller.updateGeoIPDatabase()
                    }

                    Button("Refresh Status") {
                        controller.refreshGeoIPStatus()
                    }
                }

                if let error = controller.geoIPStatus.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Place GeoLite2-Country.mmdb in Resources/ or set a MaxMind license key. The database auto-refreshes when older than 30 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Profile") {
                if let active = controller.profileDocuments.first(where: { $0.id == controller.activeProfileID }) {
                    LabeledContent("Active Profile", value: active.name)
                }
                ProfileDocumentActions()
            }
        }
        .formStyle(.grouped)
    }

    private var profilesTab: some View {
        Form {
            Section("Profile Library") {
                ProfileManagementView()
            }
        }
        .formStyle(.grouped)
    }

    private var policyGroupsTab: some View {
        Form {
            Section("Policy Groups") {
                PolicyGroupsSettingsView()
            }
        }
        .formStyle(.grouped)
    }

    private var rulesTab: some View {
        Form {
            Section("Rule Tester") {
                RuleTesterView()
            }

            Section("Active Rules") {
                RulesProfileView(rules: controller.profile.rules)
            }
        }
        .formStyle(.grouped)
    }

    private var dnsTab: some View {
        Form {
            Section("DNS Configuration") {
                DNSSettingsSummaryView()
            }
            Section("Lookup & Cache") {
                DNSLookupView()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            controller.syncDNSCache()
        }
    }

    private var mitmTab: some View {
        Form {
            Section("HTTPS Decryption") {
                Toggle("Enable HTTPS Decryption", isOn: Binding(
                    get: { controller.profile.mitm.enabled },
                    set: { controller.profile.mitm.enabled = $0 }
                ))

                if let status = controller.mitmCertificateStatus {
                    LabeledContent("CA Name", value: status.commonName)
                    LabeledContent("Expires", value: status.notValidAfter.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Fingerprint", value: String(status.fingerprintSHA256.prefix(32)) + "…")
                    LabeledContent("Trusted", value: status.isInstalledInKeychain ? "Yes" : "No")

                    Button("Copy Full Fingerprint") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(status.fingerprintSHA256, forType: .string)
                    }
                } else {
                    Text("Generate a local CA before enabling HTTPS decryption.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Generate CA Certificate") {
                        controller.generateMITMCA()
                    }

                    Button("Install in Keychain") {
                        controller.installMITMCA()
                    }
                    .disabled(controller.mitmCertificateStatus == nil)

                    Button("Export…") {
                        exportCertificate()
                    }
                    .disabled(controller.mitmCertificateStatus == nil)
                }

                Text("Install the CA in your keychain and enable decryption to inspect HTTPS traffic. Hostname filters in the profile MITM section limit which sites are decrypted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportCertificate() {
        let panel = NSSavePanel()
        panel.title = "Export MITM CA Certificate"
        panel.nameFieldStringValue = "circle-mitm-ca.pem"
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.exportMITMCATo(url: url)
    }
}
