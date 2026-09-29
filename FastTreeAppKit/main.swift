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

private enum Style {
    static let accent = NSColor.systemIndigo
    static let palette: [NSColor] = [.systemIndigo, .systemBlue, .systemTeal, .systemPurple, .systemMint, .systemOrange]
    static func color(_ name: String) -> NSColor {
        let hash = name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff }
        return palette[hash % palette.count]
    }
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
}

private final class Surface: NSView {
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
    init(_ content: NSView, padding: CGFloat = 16) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class FastTreeMap: NSView {
    var index: OpaquePointer?
    var parent: UInt32 = 0
    var onOpen: ((UInt32) -> Void)?
    private var regions: [(UInt32, NSRect)] = []
    private var hovered: UInt32?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func draw(_ dirtyRect: NSRect) {
        regions.removeAll()
        guard let index else {
            let text = "Your storage, at a glance" as NSString
            text.draw(at: NSPoint(x: 24, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            let detail = "Scan a folder to discover what takes up space." as NSString
            detail.draw(at: NSPoint(x: 24, y: 58), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let entries = (0..<ft_index_child_count(index, parent)).map { ft_index_child_at(index, parent, $0) }
            .filter { (ft_index_node(index, $0)?.pointee.allocated_bytes ?? 0) > 0 }
            .sorted { ft_index_node(index, $0)!.pointee.allocated_bytes > ft_index_node(index, $1)!.pointee.allocated_bytes }
        // Bound painting cost while retaining every byte in the area calculation.
        let visible = Array(entries.prefix(119))
        var tiles: [(UInt32?, Double)] = visible.map { (Optional($0), Double(ft_index_node(index, $0)!.pointee.allocated_bytes)) }
        let remainder = entries.dropFirst(119).reduce(0.0) { $0 + Double(ft_index_node(index, $1)!.pointee.allocated_bytes) }
        if remainder > 0 { tiles.append((nil, remainder)) }
        if tiles.isEmpty {
            ("No allocated space in this folder" as NSString).draw(at: NSPoint(x: 24, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])
        }
        layout(tiles, in: bounds.insetBy(dx: 4, dy: 4), index: index)
    }
    private func layout(_ tiles: [(UInt32?, Double)], in rect: NSRect, index: OpaquePointer) {
        guard !tiles.isEmpty, rect.width > 0, rect.height > 0 else { return }
        if tiles.count == 1 {
            let (id, bytes) = tiles[0]
            let tile = rect.insetBy(dx: 3, dy: 3)
            guard tile.width > 0, tile.height > 0 else { return }
            let name = id.map { nodeName(index, $0) } ?? "Other items"
            let color = Style.color(name)
            color.withAlphaComponent(hovered == id && id != nil ? 0.95 : 0.72).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
            if hovered == id && id != nil {
                NSColor.labelColor.withAlphaComponent(0.5).setStroke()
                let outline = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
                outline.lineWidth = 2; outline.stroke()
            }
            if tile.width > 72 && tile.height > 44 {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (name as NSString).draw(in: NSRect(x: tile.minX + 12, y: tile.minY + 10, width: tile.width - 24, height: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
                (sizeText(UInt64(bytes)) as NSString).draw(in: NSRect(x: tile.minX + 12, y: tile.minY + 29, width: tile.width - 24, height: 18), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: paragraph])
            }
            if let id { regions.append((id, tile)) }
            return
        }
        let total = tiles.reduce(0.0) { $0 + $1.1 }
        var sum = 0.0; var cut = 1
        for i in 0..<(tiles.count - 1) {
            sum += tiles[i].1; cut = i + 1
            if sum >= total / 2 { break }
        }
        let ratio = CGFloat(sum / total)
        var first = rect; var second = rect
        if rect.width >= rect.height {
            first.size.width *= ratio; second.origin.x += first.width; second.size.width -= first.width
        } else {
            first.size.height *= ratio; second.origin.y += first.height; second.size.height -= first.height
        }
        layout(Array(tiles.prefix(cut)), in: first, index: index)
        layout(Array(tiles.dropFirst(cut)), in: second, index: index)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let id = regions.first(where: { $0.1.contains(point) })?.0
        if id != hovered {
            hovered = id; needsDisplay = true
            if let index, let id, let node = ft_index_node(index, id) {
                toolTip = "\(nodeName(index, id)) · \(sizeText(node.pointee.allocated_bytes))\nClick to open"
            } else { toolTip = nil }
        }
        if id != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; toolTip = nil; needsDisplay = true; NSCursor.arrow.set() }
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

    private let allocatedValue = Style.label("—", size: 28, weight: .semibold)
    private let filesValue = Style.label("—", size: 28, weight: .semibold)
    private let foldersValue = Style.label("—", size: 28, weight: .semibold)
    private let locationTitle = Style.label("Storage overview", size: 26, weight: .bold)
    private let itemCount = Style.label("Choose a location to get started", color: .secondaryLabelColor)
    private let selectionLabel = Style.label("Select an item to inspect", color: .secondaryLabelColor)
    private let progressIndicator = NSProgressIndicator()
    private var backButton: NSButton!
    private var rescanButton: NSButton!
    private var stopButton: NSButton!
    private var revealButton: NSButton!
    private var trashButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "FastTree"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center(); window.minSize = NSSize(width: 1020, height: 740)
        window.contentView!.wantsLayer = true

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .active
        let mark = NSImageView(image: NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "FastTree")!)
        mark.contentTintColor = Style.accent
        mark.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let brand = Style.stack([mark, Style.label("FastTree", size: 21, weight: .bold)], spacing: 10)
        let scan = symbolButton("Scan Folder…", "folder.badge.plus", #selector(chooseFolder))
        scan.bezelColor = Style.accent
        let volume = symbolButton("Data Volume", "internaldrive", #selector(scanDataVolume))
        let home = symbolButton("Scan Overview", "square.grid.2x2", #selector(goRoot))
        rescanButton = symbolButton("Rescan Location", "arrow.clockwise", #selector(rescan))
        stopButton = symbolButton("Stop Scan", "stop.circle", #selector(stopScan))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let sidebarContent = Style.stack([
            brand, Style.label("DISK SPACE ANALYZER", size: 9, weight: .semibold, color: .secondaryLabelColor),
            scan, Style.label("LOCATIONS", size: 10, weight: .semibold, color: .secondaryLabelColor),
            volume, home, Style.label("SCAN", size: 10, weight: .semibold, color: .secondaryLabelColor),
            rescanButton, stopButton, spacer,
            Style.label("On your Mac. Only.", size: 12, weight: .medium),
            Style.label("Local scanning · No telemetry", size: 10, color: .secondaryLabelColor)
        ], vertical: true, spacing: 18)
        pin(sidebarContent, to: sidebar, top: 48, inset: 20)
        sidebar.widthAnchor.constraint(equalToConstant: 210).isActive = true
        for control in [scan, volume, home, rescanButton!, stopButton!] {
            control.widthAnchor.constraint(equalTo: sidebarContent.widthAnchor).isActive = true
        }

        searchField.placeholderString = "Search all indexed files"
        searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.widthAnchor.constraint(equalToConstant: 270).isActive = true
        backButton = symbolButton("", "chevron.left", #selector(goBack))
        backButton.toolTip = "Go to parent folder"
        let titleStack = Style.stack([locationTitle, pathLabel], vertical: true, spacing: 5)
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.font = .systemFont(ofSize: 11); pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.stringValue = "Scan a folder or your data volume to explore storage."
        let header = Style.stack([backButton!, titleStack, searchField], spacing: 14)
        let metrics = Style.stack([
            metric("externaldrive", "ALLOCATED SPACE", allocatedValue),
            metric("doc.on.doc", "FILES INDEXED", filesValue),
            metric("folder", "FOLDERS INDEXED", foldersValue)
        ])
        metrics.distribution = .fillEqually
        metrics.heightAnchor.constraint(equalToConstant: 106).isActive = true

        for (key, title, width) in [("name", "Name", 310.0), ("allocated", "On disk", 110.0), ("logical", "Logical size", 110.0), ("files", "Files", 85.0), ("modified", "Modified", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = key == "name" ? 180 : 70
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView()
        table.delegate = self; table.dataSource = self
        table.style = .fullWidth; table.rowHeight = 36; table.intercellSpacing = NSSize(width: 12, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.target = self; table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        revealButton = symbolButton("Reveal", "arrow.up.forward.square", #selector(revealSelected))
        trashButton = symbolButton("Trash…", "trash", #selector(trashSelected))
        let tableHeading = Style.stack([Style.label("Explorer", size: 15, weight: .semibold), itemCount, NSView(), revealButton!, trashButton!], spacing: 10)
        let explorer = Style.stack([tableHeading, scroll], vertical: true, spacing: 12)
        scroll.widthAnchor.constraint(equalTo: explorer.widthAnchor).isActive = true
        tableHeading.widthAnchor.constraint(equalTo: explorer.widthAnchor).isActive = true
        map.onOpen = { [weak self] id in self?.open(id) }
        let mapHeading = Style.stack([Style.label("Space map", size: 15, weight: .semibold), NSView(), Style.label("Block area = allocated size · Click to open", size: 11, color: .secondaryLabelColor)])
        let mapStack = Style.stack([mapHeading, map], vertical: true, spacing: 12)
        map.widthAnchor.constraint(equalTo: mapStack.widthAnchor).isActive = true
        mapHeading.widthAnchor.constraint(equalTo: mapStack.widthAnchor).isActive = true
        let split = NSSplitView(); split.isVertical = false; split.dividerStyle = .thin
        let explorerCard = Surface(explorer); let mapCard = Surface(mapStack)
        split.addArrangedSubview(explorerCard); split.addArrangedSubview(mapCard)
        explorerCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 225).isActive = true
        mapCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 215).isActive = true
        progressIndicator.style = .spinning; progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = Style.stack([progressIndicator, status], spacing: 8)
        let main = Style.stack([header, metrics, split, selectionLabel, footer], vertical: true, spacing: 16)
        for view in [header, metrics, split, footer] { view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
        let mainContainer = NSView(); pin(main, to: mainContainer, top: 42, inset: 24)
        let root = Style.stack([sidebar, mainContainer], spacing: 0)
        root.alignment = .top
        pin(root, to: window.contentView!, top: 0, inset: 0)
        sidebar.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        mainContainer.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        mainContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateControls()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let last = UserDefaults.standard.string(forKey: "FastTree.lastRoot") {
            let url = URL(fileURLWithPath: last); rootURL = url; loadIndex(at: indexURL(for: url))
        }
    }
    private func pin(_ view: NSView, to container: NSView, top: CGFloat, inset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
        ])
    }
    private func symbolButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let result = button(title, action)
        result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        result.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        result.font = .systemFont(ofSize: 12, weight: .medium)
        return result
    }
    private func metric(_ symbol: String, _ title: String, _ value: NSTextField) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = Style.accent
        let heading = Style.stack([icon, Style.label(title, size: 10, weight: .semibold, color: .secondaryLabelColor)], spacing: 8)
        value.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        return Surface(Style.stack([heading, value], vertical: true, spacing: 12))
    }
    private func updateControls() {
        backButton.isEnabled = index != nil && parent != 0
        rescanButton.isEnabled = rootURL != nil && scanner == nil
        stopButton.isEnabled = scanner != nil
        revealButton.isEnabled = table.selectedRow >= 0
        trashButton.isEnabled = table.selectedRow >= 0 && scanner == nil
        if scanner != nil { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }
    @objc private func goRoot() { parent = 0; searchField.stringValue = ""; refreshRows() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
        let ids = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        guard let index, !ids.isEmpty else { selectionLabel.stringValue = "Select an item to inspect"; return }
        let bytes = ids.reduce(UInt64(0)) { $0 + (ft_index_node(index, $1)?.pointee.allocated_bytes ?? 0) }
        selectionLabel.stringValue = "\(ids.count == 1 ? nodeName(index, ids[0]) : "\(ids.count) items") · \(sizeText(bytes)) on disk"
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
                self?.updateControls()
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
            updateControls()
        } catch { status.stringValue = error.localizedDescription }
    }
    private func loadIndex(at url: URL) {
        guard let opened = url.path.withCString({ ft_index_open($0) }) else { return }
        if let index { ft_index_close(index) }
        index = opened; parent = 0; map.index = opened; map.parent = 0
        searchField.stringValue = ""
        refreshRows()
        let root = ft_index_node(opened, 0)!.pointee
        allocatedValue.stringValue = sizeText(root.allocated_bytes)
        filesValue.stringValue = root.files.formatted()
        foldersValue.stringValue = root.directories.formatted()
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
        locationTitle.stringValue = parent == 0 ? "Storage overview" : nodeName(index, parent)
        itemCount.stringValue = "\(rows.count.formatted()) items" + (query.isEmpty ? " · Largest first" : " · Search results")
        table.deselectAll(nil); table.reloadData(); map.parent = parent; map.needsDisplay = true
        selectionLabel.stringValue = "Select an item to inspect"
        updateControls()
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
        case "name": text.stringValue = nodeName(index, rows[row])
        case "allocated": text.stringValue = sizeText(record.pointee.allocated_bytes)
        case "logical": text.stringValue = sizeText(record.pointee.logical_bytes)
        case "files": text.stringValue = record.pointee.kind == 1 ? "\(record.pointee.files)" : ""
        case "modified": text.stringValue = record.pointee.modified_seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(record.pointee.modified_seconds)).formatted(date: .abbreviated, time: .omitted) : ""
        default: break
        }
        text.font = id == "name" ? .systemFont(ofSize: 12, weight: .medium) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        text.textColor = id == "name" || id == "allocated" ? .labelColor : .secondaryLabelColor
        if id == "allocated" || id == "logical" || id == "files" { text.alignment = .right }
        cell.addSubview(text)
        var leading: CGFloat = 8
        if id == "name" {
            let name = nodeName(index, rows[row])
            let icon = NSImageView(image: NSImage(systemSymbolName: record.pointee.kind == 1 ? "folder.fill" : "doc.fill", accessibilityDescription: record.pointee.kind == 1 ? "Folder" : "File")!)
            icon.contentTintColor = Style.color(name)
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
            leading = 36
        }
        cell.toolTip = text.stringValue
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}

let app = NSApplication.shared
let controller = FastTreeController()
app.delegate = controller
app.run()
