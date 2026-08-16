import AppKit
import SwiftData
import SwiftUI

struct ExtensionsSettingsView: View {
    @Query(sort: \TabContainer.lastAccessedAt, order: .reverse) private var containers: [TabContainer]
    @StateObject private var manager = WebExtensionManager.shared
    @State private var storeInput = ""
    @State private var isInstalling = false
    @State private var operationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCard(header: "Install") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Install Chrome extensions through WebKit without adding a Chromium runtime.")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("Chrome Web Store URL or extension ID", text: $storeInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(installFromStore)

                            Button("Install") {
                                installFromStore()
                            }
                            .disabled(storeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInstalling)
                        }

                        Button("Load unpacked, ZIP, or CRX…") {
                            chooseLocalExtension()
                        }
                        .disabled(isInstalling)

                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let operationError {
                            Text(operationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }

                SettingsCard(header: "Installed Extensions") {
                    if manager.installedExtensions.isEmpty {
                        ContentUnavailableView(
                            "No Extensions Installed",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Install from the Chrome Web Store or choose a local extension package.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(manager.installedExtensions) { installedExtension in
                                extensionRow(installedExtension)
                                if installedExtension.id != manager.installedExtensions.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                Text("Extensions are currently disabled in Private windows. Site and optional permissions are never granted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private func extensionRow(_ installedExtension: InstalledWebExtension) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(installedExtension.name)
                        .font(.headline)
                    Text("Version \(installedExtension.version) · Manifest V\(formattedManifestVersion(installedExtension.manifestVersion))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(installedExtension.source == .chromeWebStore ? "Chrome Web Store" : "Local package")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Remove", role: .destructive) {
                    manager.removeExtension(installedExtension.id)
                }
            }

            if !containers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enabled in spaces")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(containers) { container in
                        Toggle(
                            "\(container.emoji) \(container.name)",
                            isOn: Binding(
                                get: { installedExtension.isEnabled(in: container.id) },
                                set: { enabled in
                                    Task {
                                        do {
                                            try await manager.setEnabled(
                                                enabled,
                                                extensionID: installedExtension.id,
                                                in: container.id
                                            )
                                        } catch {
                                            operationError = error.localizedDescription
                                        }
                                    }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }
                }
                .padding(.leading, 44)
            }

            if let loadError = manager.loadErrors[installedExtension.id] {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 44)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 12)
    }

    private func installFromStore() {
        let input = storeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        isInstalling = true
        operationError = nil
        Task {
            do {
                try await manager.installFromChromeWebStore(input)
                storeInput = ""
            } catch {
                operationError = error.localizedDescription
            }
            isInstalling = false
        }
    }

    private func chooseLocalExtension() {
        let panel = NSOpenPanel()
        panel.title = "Choose a WebExtension"
        panel.prompt = "Install"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isInstalling = true
        operationError = nil
        Task {
            do {
                try await manager.installLocalResource(at: url)
            } catch {
                operationError = error.localizedDescription
            }
            isInstalling = false
        }
    }

    private func formattedManifestVersion(_ version: Double) -> String {
        if version.rounded() == version {
            return String(Int(version))
        }
        return String(version)
    }
}
