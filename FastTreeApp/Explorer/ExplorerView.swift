import AppKit
import QuickLook
import SwiftUI

/// The directory browser. It reads only the index exposed by FastTreeModel.
struct ExplorerView: View {
    @ObservedObject var model: FastTreeModel

    @State private var expandedDirectories: Set<FTNodeID> = []
    @State private var history: [FTNodeID] = []
    @State private var historyPosition = -1
    @State private var previewURL: URL?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 245)
            directoryContents
                .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .disabled(historyPosition <= 0)
                .keyboardShortcut("[", modifiers: .command)

                Button(action: goForward) {
                    Image(systemName: "chevron.right")
                }
                .help("Forward")
                .disabled(historyPosition < 0 || historyPosition >= history.count - 1)
                .keyboardShortcut("]", modifiers: .command)

                Button(action: goToParent) {
                    Image(systemName: "arrow.up")
                }
                .help("Parent folder")
                .disabled(parentOfFocus == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: quickLookSelected) {
                    Image(systemName: "eye")
                }
                .help("Quick Look")
                .disabled(model.selectedNodeID == nil)
                .keyboardShortcut(" ", modifiers: [])

                Button(action: revealSelected) {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                .disabled(model.selectedNodeID == nil)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .quickLookPreview($previewURL)
        .onAppear(perform: adoptRoot)
        .onChange(of: model.rootID) { _ in adoptRoot() }
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleDirectories) { item in
                    HStack(spacing: 3) {
                        Button {
                            if expandedDirectories.contains(item.id) {
                                expandedDirectories.remove(item.id)
                            } else {
                                expandedDirectories.insert(item.id)
                            }
                        } label: {
                            Image(systemName: expandedDirectories.contains(item.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 16, height: 20)
                        }
                        .buttonStyle(.plain)

                        Button {
                            navigate(to: item.id)
                        } label: {
                            Label(item.node.name, systemImage: "folder")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16 + 6)
                    .padding(.vertical, 3)
                    .background(model.focusedDirectoryID == item.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contextMenu {
                        Button("Reveal in Finder") { reveal(item.id) }
                    }
                }
            }
            .padding(6)
        }
        .accessibilityLabel("Directory tree")
    }

    private var directoryContents: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(breadcrumbs, id: \.id) { node in
                            if node.id != breadcrumbs.first?.id {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button(node.name) { navigate(to: node.id) }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                        }
                    }
                }
                if let category = model.selectedFileCategory {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        model.selectedFileCategory = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear file-type filter")
                }
                if case .scanning = model.progress.state {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(model.progress.files.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            Divider()

            if let directoryID = model.focusedDirectoryID {
                ExplorerFileTable(
                    model: model,
                    directoryID: directoryID,
                    generation: model.generation,
                    category: model.selectedFileCategory,
                    selectedNodeID: $model.selectedNodeID,
                    onOpen: open,
                    onQuickLook: preview,
                    onReveal: reveal
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .font(.largeTitle)
                    Text("Choose a volume to scan")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct DirectoryItem: Identifiable {
        let node: FTNode
        let depth: Int
        var id: FTNodeID { node.id }
    }

    /// Only expanded branches are visited, so unopened subtrees cost no UI work.
    private var visibleDirectories: [DirectoryItem] {
        guard let rootID = model.rootID else { return [] }
        var result: [DirectoryItem] = []
        func append(_ id: FTNodeID, depth: Int) {
            guard let node = model.node(id), node.isDirectory else { return }
            result.append(DirectoryItem(node: node, depth: depth))
            guard expandedDirectories.contains(id) else { return }
            for childID in model.children(of: id) {
                if model.node(childID)?.isDirectory == true {
                    append(childID, depth: depth + 1)
                }
            }
        }
        append(rootID, depth: 0)
        return result
    }

    private var breadcrumbs: [FTNode] {
        guard var id = model.focusedDirectoryID else { return [] }
        var result: [FTNode] = []
        while let node = model.node(id) {
            result.append(node)
            guard let parentID = node.parentID else { break }
            id = parentID
        }
        return result.reversed()
    }

    private var parentOfFocus: FTNodeID? {
        guard let id = model.focusedDirectoryID else { return nil }
        return model.node(id)?.parentID
    }

    private func adoptRoot() {
        guard let id = model.rootID else {
            history = []
            historyPosition = -1
            return
        }
        expandedDirectories.insert(id)
        if model.focusedDirectoryID == nil || model.node(model.focusedDirectoryID!) == nil {
            navigate(to: id)
        }
    }

    private func navigate(to id: FTNodeID) {
        guard model.node(id)?.isDirectory == true else { return }
        if historyPosition < 0 || history[historyPosition] != id {
            history = Array(history.prefix(historyPosition + 1))
            history.append(id)
            historyPosition = history.count - 1
        }
        model.focusedDirectoryID = id
        model.selectedNodeID = nil
        expandedDirectories.insert(id)
    }

    private func goBack() {
        guard historyPosition > 0 else { return }
        historyPosition -= 1
        model.focusedDirectoryID = history[historyPosition]
        model.selectedNodeID = nil
    }

    private func goForward() {
        guard historyPosition + 1 < history.count else { return }
        historyPosition += 1
        model.focusedDirectoryID = history[historyPosition]
        model.selectedNodeID = nil
    }

    private func goToParent() {
        if let id = parentOfFocus { navigate(to: id) }
    }

    private func open(_ id: FTNodeID) {
        if model.node(id)?.isDirectory == true { navigate(to: id) }
        else { preview(id) }
    }

    private func preview(_ id: FTNodeID) {
        previewURL = model.path(for: id)
    }

    private func quickLookSelected() {
        if let id = model.selectedNodeID { preview(id) }
    }

    private func reveal(_ id: FTNodeID) {
        guard let url = model.path(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealSelected() {
        if let id = model.selectedNodeID { reveal(id) }
    }
}
