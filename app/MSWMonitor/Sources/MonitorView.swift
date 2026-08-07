import SwiftUI

struct MonitorView: View {
    static let title = "MSW Monitor"

    @Bindable var model: AppModel
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title)
                .font(.headline)
                .accessibilityIdentifier("monitor.title")

            VStack(spacing: 8) {
                ForEach(model.workspaces) { workspace in
                    HStack {
                        Text(workspace.id.rawValue)
                            .accessibilityIdentifier("workspace.\(workspace.id.rawValue).name")
                        Spacer()
                        Text(workspace.state.rawValue)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("workspace.\(workspace.id.rawValue).state")
                    }
                }
            }

            Divider()

            Text(model.observationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("observation.value")

            HStack {
                Button("Refresh") {
                    model.refresh()
                }
                .keyboardShortcut("r")
                .accessibilityIdentifier("refresh.button")

                Spacer()

                Button("Quit", action: quit)
                    .keyboardShortcut("q")
                    .accessibilityIdentifier("quit.button")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
