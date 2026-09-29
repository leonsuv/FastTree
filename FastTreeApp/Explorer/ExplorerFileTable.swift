import AppKit
import SwiftUI

/// NSTableView creates cells only for visible rows and remains responsive in huge folders.
struct ExplorerFileTable: NSViewRepresentable {
    @ObservedObject var model: FastTreeModel
    let directoryID: FTNodeID
    let generation: UInt64
    let category: String?
    @Binding var selectedNodeID: FTNodeID?
    let onOpen: (FTNodeID) -> Void
    let onQuickLook: (FTNodeID) -> Void
    let onReveal: (FTNodeID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ExplorerNativeTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 23
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelected)
        table.quickLook = { [weak coordinator = context.coordinator] in coordinator?.quickLookSelected() }
        table.open = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        table.reveal = { [weak coordinator = context.coordinator] in coordinator?.revealSelected() }

        let columns: [(String, String, CGFloat)] = [
            ("name", "Name", 300),
            ("kind", "Kind", 85),
            ("logical", "Logical Size", 110),
            ("allocated", "On Disk", 110),
            ("location", "Location", 230),
            ("modified", "Modified", 155)
        ]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = key == "name" ? 120 : 65
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.reloadIfNeeded(force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.reloadIfNeeded()
        context.coordinator.syncSelection()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var owner: ExplorerFileTable
        weak var table: NSTableView?
        private var rows: [FTNode] = []
        private var loadedDirectoryID: FTNodeID?
        private var loadedGeneration: UInt64?
        private var loadedCategory: String?
        private var filterTask: Task<Void, Never>?
        private var sortKey = "name"
        private var sortAscending = true
        private var isSyncingSelection = false

        init(_ owner: ExplorerFileTable) { self.owner = owner }

        func reloadIfNeeded(force: Bool = false) {
            guard force || loadedDirectoryID != owner.directoryID || loadedGeneration != owner.generation
                || loadedCategory != owner.category else { return }
            filterTask?.cancel()
            loadedDirectoryID = owner.directoryID
            loadedGeneration = owner.generation
            loadedCategory = owner.category
            rows = []
            if let category = owner.category {
                let directoryID = owner.directoryID
                let generation = owner.generation
                filterTask = Task { [weak self] in
                    await self?.loadCategory(category, directoryID: directoryID, generation: generation)
                }
            } else {
                rows = owner.model.children(of: owner.directoryID).compactMap { owner.model.node($0) }
                sortRows()
            }
            table?.reloadData()
            syncSelection()
        }

        private func loadCategory(_ category: String, directoryID: FTNodeID, generation: UInt64) async {
            var pending = [directoryID]
            var matches: [FTNode] = []
            var visited = 0
            while let current = pending.popLast() {
                if Task.isCancelled { return }
                for childID in owner.model.children(of: current) {
                    guard let node = owner.model.node(childID) else { continue }
                    let extensionName = (node.name as NSString).pathExtension.lowercased()
                    if node.isDirectory && extensionName == "app" {
                        if category == "Applications" { matches.append(node) }
                    } else if node.isDirectory {
                        pending.append(childID)
                    } else if node.kind == .file && FTFileCategory.name(for: node.name) == category {
                        matches.append(node)
                    }
                    visited += 1
                    if visited % 8_192 == 0 {
                        await Task.yield()
                        if Task.isCancelled { return }
                    }
                }
            }
            guard loadedDirectoryID == directoryID, loadedGeneration == generation,
                  loadedCategory == category, !Task.isCancelled else { return }
            rows = matches
            sortRows()
            table?.reloadData()
            syncSelection()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = tableColumn else { return nil }
            let key = column.identifier.rawValue
            let cellID = NSUserInterfaceItemIdentifier("FastTree.\(key)")
            let field = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            field.identifier = cellID
            field.lineBreakMode = .byTruncatingMiddle
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.alignment = (key == "logical" || key == "allocated") ? .right : .left
            let node = rows[row]
            switch key {
            case "name": field.stringValue = "\(node.isDirectory ? "📁" : "📄")  \(node.name)"
            case "kind": field.stringValue = kindLabel(node.kind)
            case "logical": field.stringValue = ByteCountFormatter.string(fromByteCount: Int64(clamping: node.logicalBytes), countStyle: .file)
            case "allocated": field.stringValue = ByteCountFormatter.string(fromByteCount: Int64(clamping: node.allocatedBytes), countStyle: .file)
            case "location": field.stringValue = owner.model.path(for: node.id)?.deletingLastPathComponent().path ?? ""
            case "modified": field.stringValue = node.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            default: field.stringValue = ""
            }
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table else { return }
            let row = table.selectedRow
            owner.selectedNodeID = rows.indices.contains(row) ? rows[row].id : nil
        }

        func syncSelection() {
            guard let table else { return }
            let target = owner.selectedNodeID.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? -1
            guard target != table.selectedRow else { return }
            isSyncingSelection = true
            if target >= 0 {
                table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
            isSyncingSelection = false
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            sortKey = key
            sortAscending = descriptor.ascending
            sortRows()
            tableView.reloadData()
            syncSelection()
        }

        private func sortRows() {
            let key = sortKey
            let ascending = sortAscending
            rows.sort { a, b in
                let order: ComparisonResult
                switch key {
                case "kind": order = kindLabel(a.kind).localizedStandardCompare(kindLabel(b.kind))
                case "logical": order = compare(a.logicalBytes, b.logicalBytes)
                case "allocated": order = compare(a.allocatedBytes, b.allocatedBytes)
                case "location": order = location(of: a).localizedStandardCompare(location(of: b))
                case "modified": order = compare(a.modifiedAt ?? .distantPast, b.modifiedAt ?? .distantPast)
                default: order = a.name.localizedStandardCompare(b.name)
                }
                let resolved = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
                return ascending ? resolved == .orderedAscending : resolved == .orderedDescending
            }
        }

        private func location(of node: FTNode) -> String {
            owner.model.path(for: node.id)?.deletingLastPathComponent().path ?? ""
        }

        private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }

        private func kindLabel(_ kind: FTNodeKind) -> String {
            switch kind {
            case .directory: return "Folder"
            case .file: return "File"
            case .hardlink: return "Hard link"
            case .other: return "Other"
            }
        }

        @objc func openSelected() {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            owner.onOpen(rows[table.selectedRow].id)
        }

        func quickLookSelected() {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            owner.onQuickLook(rows[table.selectedRow].id)
        }

        func revealSelected() {
            guard let table, rows.indices.contains(table.selectedRow) else { return }
            owner.onReveal(rows[table.selectedRow].id)
        }
    }
}

private final class ExplorerNativeTableView: NSTableView {
    var quickLook: (() -> Void)?
    var open: (() -> Void)?
    var reveal: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch (event.modifierFlags.intersection(.deviceIndependentFlagsMask), event.keyCode) {
        case ([], 49): quickLook?() // Space
        case ([.command], 125): open?() // Command-Down
        case ([.command], 15): reveal?() // Command-R
        default: super.keyDown(with: event)
        }
    }
}
