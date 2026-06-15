import CoreProxy
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CircleApp: App {
    @StateObject private var controller = ProxyController()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(controller)
                .frame(minWidth: 1120, minHeight: 720)
                .background(StatusBarInstaller(controller: controller))
        }
        .windowStyle(.titleBar)

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
            RequestDetailView(request: selectedRequest)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var controller: ProxyController

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
            }

            Section("Policies") {
                ForEach(controller.profile.proxyGroups) { group in
                    Label(group.name, systemImage: "point.3.connected.trianglepath.dotted")
                }
                Label("DIRECT", systemImage: "arrow.right")
                Label("REJECT", systemImage: "xmark.octagon")
            }

            Section("Rules") {
                ForEach(controller.profile.rules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.type.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(rule.type == .final ? rule.policy : "\(rule.value) -> \(rule.policy)")
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
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
            }
            .padding()
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
            TableColumn("Policy", value: \.policy)
                .width(92)
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
                        Text(request.policy)
                            .font(.headline)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        DetailCell("Status", request.statusCode.map(String.init) ?? "-")
                        DetailCell("Rule", request.matchedRule ?? "-")
                        DetailCell("Bytes In", "\(request.bytesIn)")
                        DetailCell("Bytes Out", "\(request.bytesOut)")
                        DetailCell("Latency", request.latencyMilliseconds.map { "\($0) ms" } ?? "-")
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
                    VStack(spacing: 8) {
                        Image(systemName: "network")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("No Requests")
                            .font(.headline)
                        Text("Start the proxy to capture traffic.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
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
        Form {
            Section("General") {
                LabeledContent("HTTP Port", value: "\(controller.profile.general.httpPort)")
                LabeledContent("Dashboard Port", value: "\(controller.profile.general.dashboardPort)")
            }

            Section("MITM") {
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
        .padding()
        .frame(width: 520)
        .onAppear {
            controller.refreshMITMStatus()
        }
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
