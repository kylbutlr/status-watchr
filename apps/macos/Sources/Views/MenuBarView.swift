import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: ConnectorController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status Watchr")
                        .font(.headline)
                    Text(controller.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MonitoringToggleButton(isRunning: controller.isRunning) {
                    if !controller.isRunning { controller.start() }
                    else { controller.stop() }
                }
            }

            if let status = controller.workSwitchStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .help("Off pauses local observation, cloud sync, and phone alerts. Pending means permission is not confirmed.")
            }

            if controller.state == .needsYou {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.attentionConversations, id: \.id) { conversation in
                        Text(conversation.title).font(.caption).bold()
                            .lineLimit(2)
                        Text("Approval requested in Codex").font(.caption).foregroundStyle(.secondary)
                    }
                    if controller.attentionConversations.isEmpty {
                        Text("Codex reported an attention request; conversation details are unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Discovery (local run checks every 5s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Polling interval", selection: $controller.intervalSeconds) {
                        ForEach(controller.intervalOptions, id: \.self) { seconds in
                            Text(intervalLabel(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()

                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.state == .stopped || controller.state == .starting)
                    .help("Refresh Codex status now")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Status Watchr URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http://127.0.0.1:4288", text: $controller.siteURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Ingest token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Stored in Keychain", text: $controller.token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.saveToken() }
                Button("Save token") { controller.saveToken() }
                    .buttonStyle(.link)
            }

            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))

            Toggle("Connect Codex hooks", isOn: Binding(
                get: { controller.hooksEnabled },
                set: { controller.setHooksEnabled($0) }
            ))
            .help("Installation is not trust. Review these exact hooks in Codex before they can run.")

            Text("Last successful scan: \(controller.lastScanLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let degraded = controller.sourceDegradedLabel {
                Text(degraded)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(18)
        .frame(width: 330)
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds >= 60 ? "Every \(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")" : "Every \(Int(seconds)) seconds"
    }

    private var statusColor: Color {
        switch controller.state {
        case .stopped, .paused: .secondary
        case .starting: .orange
        case .connected: .green
        case .needsYou: .yellow
        case .failed: .red
        }
    }

}

struct MonitoringToggleButton: View {
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isRunning ? "Stop" : "Start")
                .foregroundStyle(.primary)
                .frame(minWidth: 44)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(isRunning ? "Stop monitoring" : "Start monitoring")
        .help(isRunning ? "Stop observing local runs" : "Start observing local runs")
    }
}
