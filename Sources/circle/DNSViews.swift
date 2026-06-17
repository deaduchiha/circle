import CoreProxy
import SwiftUI

struct DNSLookupView: View {
  @EnvironmentObject private var controller: ProxyController
  @State private var hostname = "apple.com"
  @State private var recordType: DNSRecordType = .a

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Resolve a hostname through your configured DNS servers (UDP, DoH, and DoT).")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("Hostname", text: $hostname)
          .textFieldStyle(.roundedBorder)
        Picker("Type", selection: $recordType) {
          ForEach(DNSRecordType.allCases, id: \.self) { type in
            Text(type.name).tag(type)
          }
        }
        .frame(width: 90)
        Button("Lookup") {
          controller.lookupDNS(hostname: hostname, type: recordType)
        }
        .keyboardShortcut(.return, modifiers: [])
      }

      if let result = controller.dnsLookupResult {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Source", value: result.source)
            LabeledContent("Latency", value: "\(result.latencyMilliseconds) ms")
            LabeledContent("From Cache", value: result.fromCache ? "Yes" : "No")
            LabeledContent("Records") {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(result.records.indices, id: \.self) { index in
                  let record = result.records[index]
                  Text("\(record.type.name)  \(record.value)  (TTL \(record.ttl)s)")
                    .font(.system(.caption, design: .monospaced))
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      DNSCacheInspectorView()
    }
  }
}

struct DNSCacheInspectorView: View {
  @EnvironmentObject private var controller: ProxyController

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("DNS Cache")
          .font(.headline)
        Spacer()
        Text("\(controller.dnsCacheCount) entries")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Flush Cache") {
          controller.flushDNSCache()
        }
        .font(.caption)
      }

      if controller.dnsCacheEntries.isEmpty {
        Text("No cached DNS entries yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(controller.dnsCacheEntries.prefix(50)) { entry in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text("\(entry.hostname) (\(entry.recordType.name))")
                    .font(.caption.weight(.semibold))
                  Text(entry.records.map(\.value).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.expiresAt, format: .dateTime.hour().minute().second())
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              .padding(6)
              .background(Color(nsColor: .controlBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 6))
            }
          }
        }
        .frame(maxHeight: 180)
      }
    }
  }
}

struct DNSSettingsSummaryView: View {
  @EnvironmentObject private var controller: ProxyController

  var body: some View {
    let dns = controller.profile.dnsConfig
    return VStack(alignment: .leading, spacing: 8) {
      LabeledContent("UDP Servers", value: dns.servers.joined(separator: ", "))
      if !dns.dohServers.isEmpty {
        LabeledContent("DoH Servers", value: dns.dohServers.joined(separator: ", "))
      }
      if !dns.dotServers.isEmpty {
        LabeledContent("DoT Servers", value: dns.dotServers.joined(separator: ", "))
      }
      LabeledContent("Fake-IP", value: dns.fakeIPEnabled ? "Enabled" : "Disabled")
      LabeledContent("Hijack DNS", value: dns.hijackDNS ? "Yes" : "No")
    }
    .font(.caption)
  }
}
