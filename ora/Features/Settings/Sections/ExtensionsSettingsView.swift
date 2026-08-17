import AppKit
import SwiftUI

struct ExtensionsSettingsView: View {
    @StateObject private var manager = ExtensionManager.shared
    @State private var isInstalling = false
    @State private var operationError: String?

    private var nativeCount: Int {
        MozillaExtensionAPICatalog.namespaces.count { $0.support == .nativeWebKit }
    }

    private var compatibilityCount: Int {
        MozillaExtensionAPICatalog.namespaces.count {
            $0.support == .compatibilityLayer || $0.support == .partial
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCard(
                    header: "WebExtensions",
                    description: "Ora runs WebExtensions on WebKit and adds a Mozilla compatibility layer."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Load unpacked, ZIP, or Firefox XPI…") {
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

                SettingsCard(
                    header: "Mozilla API Compatibility",
                    description: "Unsupported Firefox-only APIs stay undefined so extensions can feature-detect them safely."
                ) {
                    HStack(spacing: 24) {
                        compatibilityMetric(
                            title: "Mozilla namespaces audited",
                            value: MozillaExtensionAPICatalog.namespaces.count
                        )
                        compatibilityMetric(title: "Native WebKit", value: nativeCount)
                        compatibilityMetric(title: "Compatibility / partial", value: compatibilityCount)
                    }
                }

                SettingsCard(header: "Installed Extensions") {
                    if manager.installedExtensions.isEmpty {
                        ContentUnavailableView(
                            "No Extensions Installed",
                            systemImage: "puzzlepiece.extension",
                            description: Text(
                                "Choose a Firefox XPI, ZIP archive, or unpacked WebExtension folder."
                            )
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

                Text(
                    "Extension permissions are user-approved. Private Ora windows are not exposed to extensions by default."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func compatibilityMetric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value))
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func extensionRow(_ installedExtension: InstalledWebExtension) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title2)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(installedExtension.name)
                    .font(.headline)
                Text(
                    "Version \(installedExtension.version) · Manifest V\(formattedManifestVersion(installedExtension.manifestVersion))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let loadError = manager.loadErrors[installedExtension.id] {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { installedExtension.isEnabled },
                    set: { enabled in
                        Task {
                            do {
                                try await manager.setEnabled(enabled, extensionID: installedExtension.id)
                            } catch {
                                operationError = error.localizedDescription
                            }
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)

            Button("Remove", role: .destructive) {
                manager.removeExtension(installedExtension.id)
            }
        }
        .padding(.vertical, 12)
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
