import AppKit
import SwiftUI

struct FastTreeSettingsView: View {
    @Binding var exclusions: String
    @Binding var minimumSearchMiB: Int
    @Binding var oldFileDays: Int
    @Binding var oldFileMinimumMiB: Int
    var onSave: () -> Void

    @AppStorage("FastTree.appearance") private var appearance = "system"
    @Environment(\.dismiss) private var dismiss

    @State private var editedExclusions = ""
    @State private var editedAppearance = "system"
    @State private var editedSearchMiB = 0
    @State private var editedOldDays = 180
    @State private var editedOldMinimumMiB = 512
    @State private var didSave = false

    private var hasInvalidExclusions: Bool {
        editedExclusions.split(whereSeparator: \.isNewline).contains {
            let path = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !path.hasPrefix("/") || path == "/"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FastTree Settings").font(.title2.bold())

            Form {
                Picker("Appearance", selection: $editedAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }

                Section("Search and Cleanup") {
                    Stepper("Search minimum: \(editedSearchMiB) MiB", value: $editedSearchMiB, in: 0...1_000_000)
                    Stepper("Old files: \(editedOldDays) days", value: $editedOldDays, in: 1...3_650)
                    Stepper("Large files: \(editedOldMinimumMiB) MiB", value: $editedOldMinimumMiB, in: 0...1_000_000)
                }

                Section("Excluded Paths") {
                    Text("Enter one absolute folder path per line. Exclusions apply to the next scan or rescan.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editedExclusions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
                    if hasInvalidExclusions {
                        Text("Use absolute paths beginning with /. The startup root itself cannot be excluded.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Add Folder…") { addExcludedFolder() }
                }

                Section("Protected Locations") {
                    Text("Grant Full Disk Access in System Settings to include protected locations. macOS may ask you to restart FastTree after changing access.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Full Disk Access Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    applyAppearance(appearance)
                    dismiss()
                }
                Button("Save") {
                    exclusions = editedExclusions
                    minimumSearchMiB = editedSearchMiB
                    oldFileDays = editedOldDays
                    oldFileMinimumMiB = editedOldMinimumMiB
                    appearance = editedAppearance
                    didSave = true
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasInvalidExclusions)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            editedExclusions = exclusions
            editedAppearance = appearance
            editedSearchMiB = minimumSearchMiB
            editedOldDays = oldFileDays
            editedOldMinimumMiB = oldFileMinimumMiB
            didSave = false
            applyAppearance(appearance)
        }
        .onDisappear {
            if !didSave { applyAppearance(appearance) }
        }
        .onChange(of: editedAppearance) { newValue in
            applyAppearance(newValue)
        }
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        let existing = editedExclusions.trimmingCharacters(in: .whitespacesAndNewlines)
        editedExclusions = ([existing].filter { !$0.isEmpty } + panel.urls.map(\.path)).joined(separator: "\n")
    }

    private func applyAppearance(_ setting: String) {
        switch setting {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
