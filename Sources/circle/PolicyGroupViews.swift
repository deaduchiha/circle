import CoreProxy
import SwiftUI

struct PolicyGroupMemberRow: View {
  let member: PolicyGroupMemberStatus
  let isActive: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text(member.name)
        .font(.caption)
      Spacer()
      if let latency = member.latencyMilliseconds {
        LatencyBadge(milliseconds: latency)
      } else if member.lastCheckedAt != nil {
        Text("timeout")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if !member.isAvailable {
        Text("down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.red)
      }
      if isActive {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }
    }
  }
}

struct LatencyBadge: View {
  let milliseconds: Int

  var body: some View {
    Text("\(milliseconds) ms")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(Capsule())
  }

  private var color: Color {
    switch milliseconds {
    case ..<100:
      .green
    case ..<300:
      .orange
    default:
      .red
    }
  }
}

struct PolicyGroupCardView: View {
  @EnvironmentObject private var controller: ProxyController
  let state: PolicyGroupRuntimeState

  private var group: PolicyGroup? {
    controller.profile.proxyGroups.first { $0.name == state.groupName }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(state.groupName)
            .font(.headline)
          Text(state.type.rawValue)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("Active: \(state.activePolicy)")
          .font(.caption.weight(.semibold))
      }

      if state.type == .select, let group {
        Picker("Selection", selection: Binding(
          get: { controller.policyGroupSelection(for: group.name) ?? state.activePolicy },
          set: { controller.selectPolicyGroupMember(groupName: group.name, policy: $0) }
        )) {
          ForEach(group.policies, id: \.self) { policy in
            Text(policy).tag(policy)
          }
        }
        .labelsHidden()
      }

      ForEach(state.members) { member in
        PolicyGroupMemberRow(member: member, isActive: member.name == state.activePolicy)
      }

      if state.type == .urlTest {
        HStack {
          if let updatedAt = state.lastUpdatedAt {
            Text("Last test \(updatedAt.formatted(date: .omitted, time: .shortened))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Test Now") {
            controller.runPolicyGroupTests(force: true)
          }
          .font(.caption)
        }
      }
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

struct PolicyGroupsSettingsView: View {
  @EnvironmentObject private var controller: ProxyController

  var body: some View {
    if controller.policyGroupStates.isEmpty {
      Text("No policy groups in the active profile.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(controller.policyGroupStates) { state in
            PolicyGroupCardView(state: state)
          }
        }
        .padding(.vertical, 4)
      }
      .frame(minHeight: 220, maxHeight: 320)
    }
  }
}

struct PolicyGroupsSidebarSection: View {
  @EnvironmentObject private var controller: ProxyController
  var onManage: (() -> Void)?

  var body: some View {
    Section("Policy Groups") {
      if controller.policyGroupStates.isEmpty {
        Text("No policy groups loaded")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(controller.policyGroupStates) { state in
          PolicyGroupSidebarRow(state: state)
        }
      }

      if let onManage {
        Button(action: onManage) {
          Label("Manage Policy Groups…", systemImage: "slider.horizontal.3")
        }
        .font(.caption)
      }
    }
  }
}

struct PolicyGroupSidebarRow: View {
  @EnvironmentObject private var controller: ProxyController
  let state: PolicyGroupRuntimeState

  private var group: PolicyGroup? {
    controller.profile.proxyGroups.first { $0.name == state.groupName }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(state.groupName)
          .font(.caption.weight(.semibold))
        Spacer()
        Text(state.type.rawValue)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if state.type == .select, let group {
        Picker("Policy", selection: Binding(
          get: { controller.policyGroupSelection(for: group.name) ?? state.activePolicy },
          set: { controller.selectPolicyGroupMember(groupName: group.name, policy: $0) }
        )) {
          ForEach(group.policies, id: \.self) { policy in
            Text(policy).tag(policy)
          }
        }
        .labelsHidden()
      } else {
        Text(state.activePolicy)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      HStack {
        if let activeMember = state.members.first(where: { $0.name == state.activePolicy }),
          let latency = activeMember.latencyMilliseconds
        {
          LatencyBadge(milliseconds: latency)
        }

        if state.type == .urlTest {
          Spacer()
          Button("Test") {
            controller.runPolicyGroupTests(force: true)
          }
          .font(.caption2)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
