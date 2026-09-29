import AppKit
import FastTreeCore

private func nodeName(_ index: OpaquePointer, _ id: UInt32) -> String {
    var length: UInt16 = 0
    guard let pointer = ft_index_name(index, id, &length) else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
}

private func sizeText(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

final class FastTreeMap: NSView {
    var index: OpaquePointer?
    var parent: UInt32 = 0
    var onOpen: ((UInt32) -> Void)?
    private var regions: [(UInt32, NSRect)] = []
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        regions.removeAll()
        guard let index else { return }
        let count = ft_index_child_count(index, parent)
        let entries = (0..<count).map { ft_index_child_at(index, parent, $0) }
            .filter { (ft_index_node(index, $0)?.pointee.allocated_bytes ?? 0) > 0 }
            .sorted { (ft_index_node(index, $0)?.pointee.allocated_bytes ?? 0) > (ft_index_node(index, $1)?.pointee.allocated_bytes ?? 0) }
        let visible = Array(entries.prefix(120))
        let total = visible.reduce(0.0) { $0 + Double(ft_index_node(index, $1)!.pointee.allocated_bytes) }
        guard total > 0 else { return }
        var x: CGFloat = 0
        for (position, id) in visible.enumerated() {
            let record = ft_index_node(index, id)!.pointee
            let width = bounds.width * CGFloat(Double(record.allocated_bytes) / total)
            let rect = NSRect(x: x, y: 0, width: width, height: bounds.height).insetBy(dx: 1, dy: 2)
            NSColor(calibratedHue: CGFloat(position % 23) / 23, saturation: 0.42, brightness: 0.75, alpha: 1).setFill()
            rect.fill()
            if rect.width > 65 {
                let label = "\(nodeName(index, id))\n\(sizeText(record.allocated_bytes))" as NSString
                label.draw(in: rect.insetBy(dx: 6, dy: 6), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])
            }
            regions.append((id, rect)); x += width
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = regions.first(where: { $0.1.contains(point) })?.0 { onOpen?(id) }
    }
}

final class FastTreeController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var table = NSTableView()
    private var map = FastTreeMap()
    private var status = NSTextField(labelWithString: "Choose a folder or volume to scan.")
    private var pathLabel = NSTextField(labelWithString: "FastTree")
    private var searchField = NSSearchField()
    private var index: OpaquePointer?
    private var rows: [UInt32] = []
    private var parent: UInt32 = 0
    private var rootURL: URL?
    private var scanner: Process?
    private var startedAt: Date?
    private var lastScanError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FastTree"
        window.center()
        window.minSize = NSSize(width: 780, height: 520)

        let scan = button("Scan Folder…", #selector(chooseFolder))
        let volume = button("Scan Data Volume", #selector(scanDataVolume))
        let back = button("Back", #selector(goBack))
        let rescan = button("Rescan", #selector(rescan))
        let stop = button("Stop", #selector(stopScan))
        let reveal = button("Reveal", #selector(revealSelected))
        let trash = button("Move to Trash…", #selector(trashSelected))
        searchField.placeholderString = "Search indexed names"
        searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        let toolbar = NSStackView(views: [scan, volume, back, rescan, stop, reveal, trash, searchField])
        toolbar.orientation = .horizontal; toolbar.spacing = 7
        toolbar.alignment = .centerY
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        for (key, title, width) in [("name", "Name", 480.0), ("allocated", "Allocated", 140.0), ("logical", "Logical", 140.0), ("files", "Files", 100.0), ("modified", "Modified", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView()
        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        map.onOpen = { [weak self] id in self?.open(id) }
        let split = NSSplitView()
        split.isVertical = false; split.dividerStyle = .thin
        split.addArrangedSubview(scroll); split.addArrangedSubview(map)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        map.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let root = NSStackView(views: [toolbar, pathLabel, split, status])
        root.orientation = .vertical; root.spacing = 7
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            pathLabel.heightAnchor.constraint(equalToConstant: 20),
            status.heightAnchor.constraint(equalToConstant: 20)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let last = UserDefaults.standard.string(forKey: "FastTree.lastRoot") {
            let url = URL(fileURLWithPath: last)
            rootURL = url
            loadIndex(at: indexURL(for: url))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }
    private func indexURL(for url: URL) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastTree/Indices", isDirectory: true)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(format: "%016llx.ftidx", hash))
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }
    @objc private func scanDataVolume() { scan(URL(fileURLWithPath: "/System/Volumes/Data")) }
    @objc private func rescan() { if let rootURL { scan(rootURL) } }
    @objc private func stopScan() { scanner?.terminate() }
    private func scan(_ url: URL) {
        scanner?.terminate()
        let root = url.standardizedFileURL
        let output = indexURL(for: root)
        do { try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { status.stringValue = error.localizedDescription; return }
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("fasttree-scan") else { return }
        let task = Process(); task.executableURL = executable
        task.arguments = [root.path, "--threads", "6", "--benchmark", "--index", output.path, "--progress"]
        task.standardOutput = Pipe()
        let errors = Pipe(); task.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("FTERROR ") {
                DispatchQueue.main.async { self?.lastScanError = String(line) }
            } else if line.hasPrefix("FTPROGRESS "),
               let json = line.dropFirst(11).data(using: .utf8),
               let progress = try? JSONSerialization.jsonObject(with: json) as? [String: NSNumber] {
                DispatchQueue.main.async {
                    guard self?.scanner === task else { return }
                    self?.status.stringValue = "Scanning: \(progress["files"]?.uint64Value ?? 0) files, \(progress["dirs"]?.uint64Value ?? 0) folders, \(sizeText(progress["allocated_bytes"]?.uint64Value ?? 0)) allocated"
                }
            }
            }
        }
        task.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                errors.fileHandleForReading.readabilityHandler = nil
                guard self?.scanner === finished else { return }
                self?.scanner = nil
                if code == 0 { self?.loadIndex(at: output) }
                else if code == SIGTERM { self?.status.stringValue = "Scan stopped." }
                else { self?.status.stringValue = self?.lastScanError ?? "Scan failed (exit \(code))." }
            }
        }
        do {
            try task.run(); scanner = task; rootURL = root; startedAt = Date()
            lastScanError = nil
            UserDefaults.standard.set(root.path, forKey: "FastTree.lastRoot")
            status.stringValue = "Scanning \(root.path)…"
        } catch { status.stringValue = error.localizedDescription }
    }
    private func loadIndex(at url: URL) {
        guard let opened = url.path.withCString({ ft_index_open($0) }) else { return }
        if let index { ft_index_close(index) }
        index = opened; parent = 0; map.index = opened; map.parent = 0
        searchField.stringValue = ""
        refreshRows()
        let root = ft_index_node(opened, 0)!.pointee
        let duration = startedAt.map { String(format: " in %.1f s", Date().timeIntervalSince($0)) } ?? ""
        status.stringValue = "Indexed \(root.files) files, \(root.directories) folders, \(sizeText(root.allocated_bytes)) allocated\(duration)."
    }
    private func refreshRows() {
        guard let index else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            let count = ft_index_child_count(index, parent)
            rows = (0..<count).map { ft_index_child_at(index, parent, $0) }
        } else {
            rows = [UInt32](repeating: 0, count: 3000)
            let count = query.withCString { ft_index_search(index, $0, &rows, UInt32(rows.count)) }
            rows = Array(rows.prefix(Int(count)))
        }
        rows.sort { (ft_index_node(index, $0)?.pointee.allocated_bytes ?? 0) > (ft_index_node(index, $1)?.pointee.allocated_bytes ?? 0) }
        pathLabel.stringValue = (rootURL?.path ?? "") + (parent == 0 ? "" : "/" + pathComponents(for: parent).joined(separator: "/"))
        table.reloadData(); map.parent = parent; map.needsDisplay = true
    }
    private func pathComponents(for id: UInt32) -> [String] {
        guard let index else { return [] }
        var parts: [String] = []; var cursor = id
        while cursor != 0, let node = ft_index_node(index, cursor) {
            parts.append(nodeName(index, cursor)); cursor = node.pointee.parent
            if parts.count > 1024 { return [] }
        }
        return parts.reversed()
    }
    private func url(for id: UInt32) -> URL? {
        guard let rootURL else { return nil }
        return pathComponents(for: id).reduce(rootURL) { $0.appendingPathComponent($1) }
    }
    @objc private func goBack() {
        guard let index, parent != 0, let node = ft_index_node(index, parent) else { return }
        parent = node.pointee.parent; refreshRows()
    }
    @objc private func searchChanged() { refreshRows() }
    @objc private func openSelected() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        open(rows[table.selectedRow])
    }
    private func open(_ id: UInt32) {
        guard let index, let node = ft_index_node(index, id) else { return }
        if node.pointee.kind == 1 { parent = id; searchField.stringValue = ""; refreshRows() }
        else if let url = url(for: id) { NSWorkspace.shared.open(url) }
    }
    @objc private func revealSelected() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count,
              let url = url(for: rows[table.selectedRow]) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func trashSelected() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let ids = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        let alert = NSAlert(); alert.messageText = "Move \(ids.count) item(s) to Trash?"
        alert.informativeText = "You can restore them from Trash."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for id in ids { if let url = url(for: id) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) } }
        rescan()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let index, row < rows.count, let record = ft_index_node(index, rows[row]) else { return nil }
        let id = column?.identifier.rawValue ?? "name"
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        switch id {
        case "name": text.stringValue = (record.pointee.kind == 1 ? "📁 " : "") + nodeName(index, rows[row])
        case "allocated": text.stringValue = sizeText(record.pointee.allocated_bytes)
        case "logical": text.stringValue = sizeText(record.pointee.logical_bytes)
        case "files": text.stringValue = record.pointee.kind == 1 ? "\(record.pointee.files)" : ""
        case "modified": text.stringValue = record.pointee.modified_seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(record.pointee.modified_seconds)).formatted(date: .abbreviated, time: .omitted) : ""
        default: break
        }
        cell.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}

let app = NSApplication.shared
let controller = FastTreeController()
app.delegate = controller
app.run()
