import AppKit
import SwiftUI

enum FTProductSection: String, CaseIterable, Identifiable {
    case search = "Search"
    case largest = "Largest Files"
    case oldAndLarge = "Old & Large"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .largest: "arrow.down.to.line.compact"
        case .oldAndLarge: "clock.arrow.circlepath"
        }
    }
}

/// Scan and cleanup controls backed by FastTreeModel's retained filesystem index.
struct FastTreeProductView: View {
    @ObservedObject var model: FastTreeModel

    @AppStorage("FastTree.excludedPaths") private var savedExclusions = ""
    @AppStorage("FastTree.minimumSearchMiB") private var minimumSearchMiB = 0
    @AppStorage("FastTree.oldFileDays") private var oldFileDays = 180
    @AppStorage("FastTree.oldFileMinimumMiB") private var oldFileMinimumMiB = 512

    @State private var selectedVolume = URL(fileURLWithPath: "/", isDirectory: true)
    @State private var volumes: [URL] = []
    @State private var section: FTProductSection = .largest
    @State private var searchScope: SearchScope = .all
    @State private var resultIDs: [FTNodeID] = []
    @State private var selectedResultIDs: Set<FTNodeID> = []
    @State private var showSettings = false
    @State private var showTrashConfirmation = false
    @State private var operationError: String?

    private enum SearchScope: String, CaseIterable, Identifiable {
        case all = "All"
        case files = "Files"
        case folders = "Folders"
        var id: String { rawValue }
    }

    private var canScan: Bool { model.progress.state != .scanning }
    private var trashIDs: [FTNodeID] {
        let ids = selectedResultIDs.isEmpty
            ? model.selectedNodeID.map { [$0] } ?? []
            : Array(selectedResultIDs)
        return ids.filter { $0 != model.rootID && model.node($0) != nil }
    }
    private var trashConfirmationTitle: String {
        if trashIDs.count == 1, let name = model.node(trashIDs[0])?.name {
            return "Move \"\(name)\" to Trash?"
        }
        return "Move \(trashIDs.count) items to Trash?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scanControls
            progressView
            Divider()
            Picker("View", selection: $section) {
                ForEach(FTProductSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .search { searchControls }
            if section == .oldAndLarge { oldFileControls }

            resultsView
        }
        .padding(16)
        .frame(minWidth: 330, minHeight: 410)
        .task {
            refreshVolumes()
            model.excludedPaths = exclusionSet(from: savedExclusions)
            refreshResults()
        }
        .onChange(of: model.generation) { _ in refreshResults() }
        .onChange(of: model.rootID) { _ in refreshResults() }
        .task(id: model.searchQuery) {
            guard section == .search else { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, section == .search else { return }
            refreshResults()
        }
        .onChange(of: section) { _ in
            selectedResultIDs.removeAll()
            refreshResults()
        }
        .onChange(of: searchScope) { _ in refreshResults() }
        .onChange(of: minimumSearchMiB) { _ in refreshResults() }
        .onChange(of: oldFileDays) { _ in refreshResults() }
        .onChange(of: oldFileMinimumMiB) { _ in refreshResults() }
        .onChange(of: selectedResultIDs) { selection in
            if let id = selection.first {
                model.selectedNodeID = id
                if model.node(id)?.isDirectory == true { model.focusedDirectoryID = id }
            }
        }
        .onChange(of: model.selectedNodeID) { id in
            if let id, resultIDs.contains(id) {
                if !selectedResultIDs.contains(id) { selectedResultIDs = [id] }
            } else {
                selectedResultIDs.removeAll()
            }
        }
        .sheet(isPresented: $showSettings) {
            FastTreeSettingsView(
                exclusions: $savedExclusions,
                minimumSearchMiB: $minimumSearchMiB,
                oldFileDays: $oldFileDays,
                oldFileMinimumMiB: $oldFileMinimumMiB
            ) {
                model.excludedPaths = exclusionSet(from: savedExclusions)
            }
        }
        .confirmationDialog(
            trashConfirmationTitle,
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { moveSelectedToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected files or folders will be moved to the macOS Trash. You can restore them from there.")
        }
        .alert("FastTree", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan Location").font(.headline)
                Spacer()
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(",", modifiers: [.command])
                .help("Exclusions and filters")
            }
            HStack {
                Picker("Volume", selection: $selectedVolume) {
                    ForEach(volumes, id: \.self) { url in
                        Text(volumeLabel(url)).tag(url)
                    }
                }
                .labelsHidden()
                Button("Choose Folder…") { chooseFolder() }
            }
            HStack {
                Button {
                    model.excludedPaths = exclusionSet(from: savedExclusions)
                    resultIDs = []
                    selectedResultIDs.removeAll()
                    model.startScan(selectedVolume)
                } label: {
                    Label("Scan", systemImage: "play.fill")
                }
                .disabled(!canScan)

                Button {
                    model.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(canScan)

                Button {
                    model.excludedPaths = exclusionSet(from: savedExclusions)
                    model.rescan()
                } label: {
                    Label("Rescan Changes", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!canScan || model.rootID == nil)
                .help("Update the current index from filesystem changes")
                Spacer()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var progressView: some View {
        switch model.progress.state {
        case .idle:
            Text("Choose a volume or folder to scan.").foregroundStyle(.secondary)
        case .scanning:
            VStack(alignment: .leading, spacing: 5) {
                ProgressView().progressViewStyle(.linear)
                Text("\(model.progress.files.formatted()) files · \(model.progress.directories.formatted()) folders · \(size(model.progress.allocatedBytes)) allocated")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Indexed \(model.progress.files.formatted()) files and \(model.progress.directories.formatted()) folders in \(model.progress.elapsed.formatted(.number.precision(.fractionLength(1)))) s", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .cancelled:
            Label("Scan cancelled", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }

        if model.progress.skipped > 0 {
            HStack(alignment: .top) {
                Image(systemName: "lock.shield")
                Text("\(model.progress.skipped.formatted()) items were skipped. Full Disk Access may be needed for protected locations.")
                    .font(.caption)
                Button("Open Settings") { openFullDiskAccess() }
                    .font(.caption)
            }
            .foregroundStyle(.orange)
        }
        if let error = model.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search indexed file and folder names", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Type", selection: $searchScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .frame(maxWidth: 180)
                Spacer()
                Text("Min \(minimumSearchMiB) MiB")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var oldFileControls: some View {
        HStack {
            Image(systemName: "clock")
            Text("Older than \(oldFileDays) days · at least \(oldFileMinimumMiB) MiB")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(resultIDs.count.formatted()) results")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showTrashConfirmation = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(trashIDs.isEmpty || model.progress.state == .scanning)
                .help("Move selected indexed items to Trash")
            }
            .padding(.bottom, 6)

            List(selection: $selectedResultIDs) {
                ForEach(resultIDs, id: \.self) { id in
                    if let node = model.node(id) {
                        resultRow(node)
                            .tag(id)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if resultIDs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: section.symbol).font(.title).foregroundStyle(.secondary)
                        Text(section == .search && model.searchQuery.isEmpty ? "Enter a Search" : "No Results")
                            .font(.headline)
                        Text(model.rootID == nil ? "Scan a location to build the index." : "Try a different search or filter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func resultRow(_ node: FTNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.isDirectory ? Color.blue : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).lineLimit(1)
                if let path = model.path(for: node.id) {
                    Text(path.deletingLastPathComponent().path)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(size(node.allocatedBytes)).monospacedDigit()
                if let date = node.modifiedAt {
                    Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") {
                if let path = model.path(for: node.id) {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }
            }
            Button("Move to Trash…", role: .destructive) {
                selectedResultIDs = [node.id]
                showTrashConfirmation = true
            }
            .disabled(node.id == model.rootID)
        }
    }

    private func refreshResults() {
        guard model.rootID != nil else { resultIDs = []; return }
        switch section {
        case .search:
            let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { resultIDs = []; return }
            let minimum = UInt64(max(0, minimumSearchMiB)) * 1_048_576
            resultIDs = model.search(query, limit: 1_000).filter { id in
                guard let node = model.node(id), node.allocatedBytes >= minimum else { return false }
                switch searchScope {
                case .all: return true
                case .files: return !node.isDirectory
                case .folders: return node.isDirectory
                }
            }
        case .largest:
            resultIDs = model.largestFiles(limit: 500)
        case .oldAndLarge:
            let cutoff = Date().addingTimeInterval(-Double(max(1, oldFileDays)) * 86_400)
            let minimum = UInt64(max(0, oldFileMinimumMiB)) * 1_048_576
            resultIDs = model.oldAndLarge(minBytes: minimum, olderThan: cutoff, limit: 500)
        }
        selectedResultIDs = selectedResultIDs.intersection(resultIDs)
    }

    private func refreshVolumes() {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: []
        ) ?? []
        let roots = [URL(fileURLWithPath: "/", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser]
        volumes = Array(Set(roots + mounted + [selectedVolume]))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func volumeLabel(_ url: URL) -> String {
        if url.path == "/" { return "Startup Disk (/)" }
        if url == FileManager.default.homeDirectoryForCurrentUser { return "Home (\(url.lastPathComponent))" }
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        return "\(name ?? url.lastPathComponent) — \(url.path)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Scan Location"
        if panel.runModal() == .OK, let url = panel.url {
            selectedVolume = url
            refreshVolumes()
        }
    }

    private func openFullDiskAccess() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private func moveSelectedToTrash() {
        let ids = trashIDs
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await model.moveToTrash(ids)
                selectedResultIDs.removeAll()
                model.rescan()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func exclusionSet(from text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && $0 != "/" })
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
