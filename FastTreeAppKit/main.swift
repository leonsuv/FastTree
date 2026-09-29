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
    static let accent = NSColor.controlAccentColor
    // Related blue tones keep the map calm; colors stay stable as you navigate.
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.24, green: 0.48, blue: 0.76, alpha: 1),
        NSColor(srgbRed: 0.28, green: 0.60, blue: 0.67, alpha: 1),
        NSColor(srgbRed: 0.40, green: 0.43, blue: 0.69, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.56, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.47, green: 0.61, blue: 0.63, alpha: 1),
        NSColor(srgbRed: 0.52, green: 0.49, blue: 0.70, alpha: 1)
    ]
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
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    static func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
    static func divider() -> NSBox {
        let box = NSBox(); box.boxType = .separator
        return box
    }
}

private final class SidebarButton: NSButton {
    var selected = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if selected && isEnabled {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let tint: NSColor = isEnabled ? (selected ? .controlAccentColor : .secondaryLabelColor) : .tertiaryLabelColor
        if let image {
            let symbol = image.copy() as! NSImage
            symbol.isTemplate = true
            let icon = NSRect(x: 10, y: (bounds.height - 17) / 2, width: 17, height: 17)
            symbol.draw(in: icon)
            tint.setFill(); icon.fill(using: .sourceAtop)
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 37, y: (bounds.height - 17) / 2, width: bounds.width - 47, height: 19),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                             .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                             .paragraphStyle: paragraph])
    }
}

private final class ExplorerTable: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let doubleAction { NSApp.sendAction(doubleAction, to: target, from: self) }
        } else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if row < 0 { deselectAll(nil) }
        return super.menu(for: event)
    }
}

private final class StorageBar: NSView {
    var entries: [(String, UInt64)] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let total = entries.reduce(0.0) { $0 + Double($1.1) }
        guard total > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        var x = rect.minX
        for (name, bytes) in entries {
            let width = rect.width * CGFloat(Double(bytes) / total)
            Style.color(name).setFill()
            NSRect(x: x, y: rect.minY, width: max(0, width - 1), height: rect.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class FastTreeMap: NSView {
    var index: OpaquePointer? { didSet { rebuild() } }
    var parent: UInt32 = 0 { didSet { rebuild() } }
    var displayedIDs: [UInt32]? { didSet { rebuild() } }
    var selected: Set<UInt32> = [] { didSet { needsDisplay = true } }
    var onOpen: ((UInt32) -> Void)?
    var onSelect: ((UInt32) -> Void)?
    var onHover: ((UInt32?) -> Void)?
    private var tiles: [(UInt32?, Double)] = []
    private var regions: [(UInt32, NSRect)] = []
    private var hovered: UInt32?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private func rebuild() {
        hovered = nil; toolTip = nil; tiles = []; regions = []
        if let index {
            let entries = (displayedIDs ?? (0..<ft_index_child_count(index, parent)).map { ft_index_child_at(index, parent, $0) })
                .filter { (ft_index_node(index, $0)?.pointee.allocated_bytes ?? 0) > 0 }
                .sorted { ft_index_node(index, $0)!.pointee.allocated_bytes > ft_index_node(index, $1)!.pointee.allocated_bytes }
            tiles = entries.prefix(159).map { (Optional($0), Double(ft_index_node(index, $0)!.pointee.allocated_bytes)) }
            let remainder = entries.dropFirst(159).reduce(0.0) { $0 + Double(ft_index_node(index, $1)!.pointee.allocated_bytes) }
            if remainder > 0 { tiles.append((nil, remainder)) }
        }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func draw(_ dirtyRect: NSRect) {
        regions.removeAll()
        guard let index, !tiles.isEmpty else {
            let title = index == nil ? "A clearer view of your storage" : "This folder has no allocated space"
            let detail = index == nil ? "Scan a location to see what takes up space." : "Choose another folder in the explorer."
            let icon = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!
            icon.draw(in: NSRect(x: bounds.midX - 20, y: bounds.midY - 60, width: 40, height: 40))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (title as NSString).draw(in: NSRect(x: 12, y: bounds.midY, width: bounds.width - 24, height: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            (detail as NSString).draw(in: NSRect(x: 12, y: bounds.midY + 30, width: bounds.width - 24, height: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            return
        }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let scale = Double(rect.width * rect.height) / tiles.reduce(0) { $0 + $1.1 }
        var remaining = rect
        var row: [(UInt32?, Double)] = []
        func worst(_ values: [(UInt32?, Double)], _ edge: CGFloat) -> Double {
            guard !values.isEmpty, edge > 0 else { return .infinity }
            let areas = values.map { $0.1 * scale }
            let sum = areas.reduce(0, +), side = Double(edge * edge)
            return max(side * areas.max()! / (sum * sum), sum * sum / (side * areas.min()!))
        }
        func paintRow(_ values: [(UInt32?, Double)]) {
            let area = values.reduce(0) { $0 + $1.1 * scale }
            let vertical = remaining.width >= remaining.height
            let edge = vertical ? remaining.height : remaining.width
            guard edge > 0 else { return }
            let thickness = CGFloat(area) / edge
            var offset: CGFloat = 0
            for entry in values {
                let length = CGFloat(entry.1 * scale) / thickness
                let tile = vertical
                    ? NSRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : NSRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                paint(entry, rect: tile, index: index)
                offset += length
            }
            if vertical { remaining.origin.x += thickness; remaining.size.width -= thickness }
            else { remaining.origin.y += thickness; remaining.size.height -= thickness }
        }
        for tile in tiles {
            let edge = min(remaining.width, remaining.height)
            if !row.isEmpty && worst(row + [tile], edge) > worst(row, edge) {
                paintRow(row); row = []
            }
            row.append(tile)
        }
        paintRow(row)
    }
    private func paint(_ entry: (UInt32?, Double), rect: NSRect, index: OpaquePointer) {
        let (id, bytes) = entry
        let tile = rect.insetBy(dx: 1.5, dy: 1.5)
        guard tile.width > 0, tile.height > 0 else { return }
        let name = id.map { nodeName(index, $0) } ?? "Other items"
        let color = id == nil ? NSColor.systemGray : Style.color(name)
        let active = id.map { selected.contains($0) || hovered == $0 } ?? false
        let path = NSBezierPath(roundedRect: tile, xRadius: min(5, tile.width / 4), yRadius: min(5, tile.height / 4))
        color.setFill(); path.fill()
        if active {
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let outline = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3)
            outline.lineWidth = 2; outline.stroke()
        }
        if tile.width > 70 && tile.height > 42 {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (name as NSString).draw(in: NSRect(x: tile.minX + 10, y: tile.minY + 10, width: tile.width - 20, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            (sizeText(UInt64(bytes)) as NSString).draw(in: NSRect(x: tile.minX + 10, y: tile.minY + 30, width: tile.width - 20, height: 18), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph])
        }
        if let id { regions.append((id, tile)) }
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let id = regions.first(where: { $0.1.contains(point) })?.0
        if id != hovered {
            hovered = id; needsDisplay = true; onHover?(id)
            if let index, let id, let node = ft_index_node(index, id) {
                toolTip = "\(nodeName(index, id)) · \(sizeText(node.pointee.allocated_bytes)) on disk"
            } else { toolTip = nil }
        }
        NSCursor.arrow.set()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = nil; toolTip = nil; needsDisplay = true; onHover?(nil)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = regions.first(where: { $0.1.contains(point) })?.0 {
            onSelect?(id)
            if event.clickCount == 2 { onOpen?(id) }
        }
    }
}

final class FastTreeController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSPathControlDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var table = ExplorerTable()
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

    private let allocatedValue = Style.label("—", size: 30, weight: .medium)
    private let filesValue = Style.label("—", size: 22, weight: .medium)
    private let foldersValue = Style.label("—", size: 22, weight: .medium)
    private let locationTitle = Style.label("Storage", size: 24, weight: .bold)
    private let itemCount = Style.label("Choose a location to get started", color: .secondaryLabelColor)
    private let selectionLabel = Style.label("Select an item to inspect", color: .secondaryLabelColor)
    private let progressIndicator = NSProgressIndicator()
    private var backButton: NSButton!
    private var rescanButton: NSButton!
    private var stopButton: NSButton!
    private var revealButton: NSButton!
    private var trashButton: NSButton!

    private let mapTitle = Style.label("Space Map", size: 13, weight: .semibold)
    private let mapScope = Style.label("On-disk size", size: 11, color: .secondaryLabelColor)
    private let pathControl = NSPathControl()
    private let storageBar = StorageBar()
    private let legend = NSStackView()
    private let detailPath = Style.label("Double-click a folder to explore it.", size: 11, color: .secondaryLabelColor)
    private let sidebarLocation = Style.label("No location scanned", size: 11, color: .secondaryLabelColor)
    private var overviewButton: SidebarButton!
    private var largestButton: SidebarButton!
    private var showingLargest = false
    private let splitController = NSSplitViewController()
    private let contentSplit = NSSplitView()
    private func argument(_ name: String) -> String? {
        guard let position = CommandLine.arguments.firstIndex(of: name), position + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[position + 1]
    }
    private var searchWork: DispatchWorkItem?
    private var largestCache: [UInt32]?
    private var sortKey = "allocated"
    private var sortAscending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        applyAppearance()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FastTree"
        window.subtitle = "Storage analyzer"
        window.titlebarSeparatorStyle = .line
        window.minSize = NSSize(width: 1080, height: 660)
        window.setFrameAutosaveName("FastTree.mainWindow.v2")
        window.center()

        searchField.placeholderString = "Search indexed files"
        searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        backButton = symbolButton("", "chevron.left", #selector(goBack))
        backButton.toolTip = "Enclosing Folder (⌘↑)"
        rescanButton = symbolButton("", "arrow.clockwise", #selector(rescan))
        rescanButton.toolTip = "Rescan Location (⌘R)"
        stopButton = symbolButton("", "stop.circle", #selector(stopScan))
        stopButton.toolTip = "Stop Scan"
        revealButton = symbolButton("", "arrow.up.forward.square", #selector(revealSelected))
        revealButton.toolTip = "Show in Finder (⇧⌘R)"
        trashButton = symbolButton("", "trash", #selector(trashSelected))
        trashButton.toolTip = "Move Selection to Trash…"
        let toolbar = NSToolbar(identifier: "FastTree.toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unified

        let sidebar = NSViewController()
        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar; sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.state = .followsWindowActiveState
        sidebar.view = sidebarBackground
        let sidebarTitle = Style.label("LIBRARY", size: 10, weight: .semibold, color: .secondaryLabelColor)
        overviewButton = sidebarButton("Overview", "internaldrive", #selector(goRoot)); overviewButton.selected = true
        largestButton = sidebarButton("Largest Files", "doc.text.magnifyingglass", #selector(showLargest))
        let volume = sidebarButton("Macintosh HD", "externaldrive", #selector(scanDataVolume))
        let folder = sidebarButton("Choose Folder…", "folder.badge.plus", #selector(chooseFolder))
        let sidebarContent = Style.stack([
            sidebarTitle, overviewButton!, largestButton!,
            Style.label("LOCATIONS", size: 10, weight: .semibold, color: .secondaryLabelColor), volume, folder
        ], vertical: true, spacing: 4)
        sidebarContent.setCustomSpacing(18, after: largestButton)
        pin(sidebarContent, to: sidebar.view, top: 24, inset: 12, bottom: nil)
        for control in [overviewButton!, largestButton!, volume, folder] {
            control.widthAnchor.constraint(equalTo: sidebarContent.widthAnchor).isActive = true
        }
        let sidebarFooter = Style.stack([
            Style.label("CURRENT INDEX", size: 9, weight: .semibold, color: .tertiaryLabelColor), sidebarLocation,
            Style.label("Stored on this Mac", size: 10, color: .tertiaryLabelColor)
        ], vertical: true, spacing: 6)
        sidebarFooter.translatesAutoresizingMaskIntoConstraints = false; sidebar.view.addSubview(sidebarFooter)
        NSLayoutConstraint.activate([
            sidebarFooter.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor, constant: 20),
            sidebarFooter.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: -16),
            sidebarFooter.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor, constant: -20)
        ])
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190; sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = true
        splitController.addSplitViewItem(sidebarItem)

        let main = NSViewController(); main.view = NSView()
        splitController.addSplitViewItem(NSSplitViewItem(viewController: main))
        window.contentViewController = splitController

        pathLabel.font = .systemFont(ofSize: 12); pathLabel.textColor = .secondaryLabelColor
        pathLabel.stringValue = "Understand what's taking up space on your Mac."
        let titleStack = Style.stack([locationTitle, pathLabel], vertical: true, spacing: 5)
        let metrics = Style.stack([
            metric("On disk", allocatedValue), metric("Files", filesValue), metric("Folders", foldersValue)
        ], spacing: 32)
        let summary = NSView()
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        metrics.translatesAutoresizingMaskIntoConstraints = false
        storageBar.translatesAutoresizingMaskIntoConstraints = false
        summary.addSubview(titleStack); summary.addSubview(metrics); summary.addSubview(storageBar)
        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: summary.leadingAnchor), titleStack.topAnchor.constraint(equalTo: summary.topAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: metrics.leadingAnchor, constant: -24),
            metrics.trailingAnchor.constraint(equalTo: summary.trailingAnchor), metrics.topAnchor.constraint(equalTo: summary.topAnchor),
            storageBar.leadingAnchor.constraint(equalTo: summary.leadingAnchor), storageBar.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            storageBar.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 22),
            storageBar.heightAnchor.constraint(equalToConstant: 9), storageBar.bottomAnchor.constraint(equalTo: summary.bottomAnchor)
        ])
        legend.orientation = .horizontal; legend.spacing = 18; legend.alignment = .centerY
        legend.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let heading = Style.stack([Style.label("Contents", size: 13, weight: .semibold), NSView(), itemCount], spacing: 12)
        pathControl.pathStyle = .standard; pathControl.isEditable = false
        pathControl.target = self; pathControl.action = #selector(pathClicked); pathControl.delegate = self
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.heightAnchor.constraint(equalToConstant: 26).isActive = true
        pathControl.setAccessibilityLabel("Current folder")
        for (key, title, width) in [("name", "Name", 200.0), ("allocated", "On Disk", 100.0), ("share", "%", 55.0), ("files", "Files", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = key == "name" ? 150 : 55
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "name")
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView(); table.delegate = self; table.dataSource = self
        table.style = .fullWidth; table.rowHeight = 34; table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = false; table.allowsMultipleSelection = true
        table.target = self; table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.sortDescriptors = [NSSortDescriptor(key: "allocated", ascending: false)]
        table.setAccessibilityLabel("Indexed files and folders")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealSelected), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash…", action: #selector(trashSelected), keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let explorer = NSView()
        let explorerHeader = Style.stack([heading, pathControl, Style.divider()], vertical: true, spacing: 10)
        pin(explorerHeader, to: explorer, top: 16, inset: 16, bottom: nil)
        for view in [heading, pathControl, explorerHeader.arrangedSubviews.last!] {
            view.widthAnchor.constraint(equalTo: explorerHeader.widthAnchor).isActive = true
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false; explorer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: explorerHeader.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: explorer.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: explorer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: explorer.bottomAnchor)
        ])
        map.onOpen = { [weak self] id in self?.open(id) }
        map.onSelect = { [weak self] id in self?.selectMapItem(id) }
        map.onHover = { [weak self] id in self?.showDetail(id) }
        map.setAccessibilityElement(true)
        map.setAccessibilityRole(.image)
        map.setAccessibilityLabel("Storage treemap. Block area represents space on disk. Select in the file list for keyboard access.")
        let mapHeading = Style.stack([mapTitle, NSView(), mapScope])
        let mapStack = Style.stack([mapHeading, map, Style.label("Select to inspect · Double-click to open", size: 11, color: .tertiaryLabelColor)], vertical: true, spacing: 16)
        for view in [mapHeading, map] { view.widthAnchor.constraint(equalTo: mapStack.widthAnchor).isActive = true }
        let mapContainer = NSView(); pin(mapStack, to: mapContainer, top: 16, inset: 16)
        contentSplit.isVertical = true; contentSplit.dividerStyle = .thin
        contentSplit.addArrangedSubview(explorer); contentSplit.addArrangedSubview(mapContainer)
        contentSplit.autosaveName = "FastTree.explorerMap.v2"
        explorer.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        mapContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        map.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let inspector = Style.stack([selectionLabel, detailPath], vertical: true, spacing: 5)
        selectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectionLabel.textColor = .labelColor
        detailPath.lineBreakMode = .byTruncatingMiddle
        let inspectorContainer = NSView(); pin(inspector, to: inspectorContainer, top: 12, inset: 20)
        inspectorContainer.heightAnchor.constraint(equalToConstant: 62).isActive = true
        progressIndicator.style = .spinning; progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = Style.stack([progressIndicator, status], spacing: 8)
        let summaryContainer = NSView()
        let summaryStack = Style.stack([summary, legend], vertical: true, spacing: 10)
        for view in [summary, legend] { view.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true }
        pin(summaryStack, to: summaryContainer, top: 24, inset: 24)
        let divider = Style.divider(), inspectorDivider = Style.divider(), footerDivider = Style.divider()
        for view in [summaryContainer, divider, contentSplit, inspectorDivider, inspectorContainer, footerDivider, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false; main.view.addSubview(view)
        }
        NSLayoutConstraint.activate([
            summaryContainer.topAnchor.constraint(equalTo: main.view.topAnchor), summaryContainer.leadingAnchor.constraint(equalTo: main.view.leadingAnchor), summaryContainer.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: summaryContainer.bottomAnchor), divider.leadingAnchor.constraint(equalTo: main.view.leadingAnchor), divider.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            contentSplit.topAnchor.constraint(equalTo: divider.bottomAnchor), contentSplit.leadingAnchor.constraint(equalTo: main.view.leadingAnchor), contentSplit.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            inspectorDivider.topAnchor.constraint(equalTo: contentSplit.bottomAnchor), inspectorDivider.leadingAnchor.constraint(equalTo: main.view.leadingAnchor), inspectorDivider.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            inspectorContainer.topAnchor.constraint(equalTo: inspectorDivider.bottomAnchor), inspectorContainer.leadingAnchor.constraint(equalTo: main.view.leadingAnchor), inspectorContainer.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            footerDivider.topAnchor.constraint(equalTo: inspectorContainer.bottomAnchor), footerDivider.leadingAnchor.constraint(equalTo: main.view.leadingAnchor), footerDivider.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            footer.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 9), footer.bottomAnchor.constraint(equalTo: main.view.bottomAnchor, constant: -9), footer.leadingAnchor.constraint(equalTo: main.view.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: main.view.trailingAnchor, constant: -20)
        ])
        updateControls()
        showDetail()
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        contentSplit.setPosition(contentSplit.bounds.width * 0.56, ofDividerAt: 0)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(table)
        if let destination = argument("--snapshot") {
            // Render the actual AppKit window for reproducible visual QA without changing the saved index.
            if let root = argument("--snapshot-root"), let indexPath = argument("--snapshot-index") {
                rootURL = URL(fileURLWithPath: root); loadIndex(at: URL(fileURLWithPath: indexPath))
            }
            if let appearance = argument("--snapshot-appearance") {
                window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            }
            let width = Double(argument("--snapshot-width") ?? "1360") ?? 1360
            let height = Double(argument("--snapshot-height") ?? "880") ?? 880
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            contentSplit.setPosition(contentSplit.bounds.width * 0.56, ofDividerAt: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                guard let frame = window.contentView?.superview,
                      let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { NSApp.terminate(nil); return }
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    do { try data.write(to: URL(fileURLWithPath: destination)) }
                    catch { fputs("Snapshot failed: \(error)\n", stderr) }
                }
                let widths = contentSplit.arrangedSubviews.map { Int($0.bounds.width) }
                print("Snapshot: \(Int(frame.bounds.width))×\(Int(frame.bounds.height)), panels \(widths), rows \(rows.count)")
                NSApp.terminate(nil)
            }
        } else if let last = UserDefaults.standard.string(forKey: "FastTree.lastRoot") {
            let url = URL(fileURLWithPath: last); rootURL = url; loadIndex(at: indexURL(for: url))
        }
    }
    private func pin(_ view: NSView, to container: NSView, top: CGFloat, inset: CGFloat, bottom: CGFloat? = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top)
        ])
        if let bottom { view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -(bottom == 0 ? inset : bottom)).isActive = true }
    }
    private func symbolButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let result = button(title, action)
        result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        result.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        result.font = .systemFont(ofSize: 12, weight: .medium)
        return result
    }
    private func sidebarButton(_ title: String, _ symbol: String, _ action: Selector) -> SidebarButton {
        let result = SidebarButton(title: title, target: self, action: action)
        result.isBordered = false
        result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        result.heightAnchor.constraint(equalToConstant: 32).isActive = true
        result.setAccessibilityLabel(title)
        return result
    }
    private func metric(_ title: String, _ value: NSTextField) -> NSView {
        value.font = .monospacedDigitSystemFont(ofSize: title == "On disk" ? 28 : 22, weight: .medium)
        let label = Style.label(title, size: 11, color: .secondaryLabelColor)
        return Style.stack([label, value], vertical: true, spacing: 5)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .init("back"), .init("scan"), .init("rescan"), .init("stop"), .flexibleSpace, .init("reveal"), .init("trash"), .init("search")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "back": item.view = backButton; item.label = "Enclosing Folder"
        case "scan": item.view = symbolButton("Scan Folder…", "folder.badge.plus", #selector(chooseFolder)); item.label = "Scan Folder"
        case "rescan": item.view = rescanButton; item.label = "Rescan"
        case "stop": item.view = stopButton; item.label = "Stop Scan"
        case "reveal": item.view = revealButton; item.label = "Show in Finder"
        case "trash": item.view = trashButton; item.label = "Move to Trash"
        case "search": item.view = searchField; item.label = "Search"
        default: return nil
        }
        return item
    }
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About FastTree", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FastTree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.addItem(fileItem)
        let file = NSMenu(title: "File"); fileItem.submenu = file
        for (title, action, key) in [("Scan Folder…", #selector(chooseFolder), "o"), ("Rescan Location", #selector(rescan), "r"), ("Stop Scan", #selector(stopScan), ".")] {
            let item = file.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: ""); main.addItem(viewItem)
        let view = NSMenu(title: "View"); viewItem.submenu = view
        let find = view.addItem(withTitle: "Search", action: #selector(focusSearch), keyEquivalent: "f"); find.target = self
        let up = view.addItem(withTitle: "Enclosing Folder", action: #selector(goBack), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)); up.target = self
        let reveal = view.addItem(withTitle: "Show in Finder", action: #selector(revealSelected), keyEquivalent: "r"); reveal.target = self; reveal.keyEquivalentModifierMask = [.command, .shift]
        let sidebar = view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s"); sidebar.target = splitController; sidebar.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearance = NSMenu(title: "Appearance"); appearanceItem.submenu = appearance; view.addItem(appearanceItem)
        for (title, value) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let item = appearance.addItem(withTitle: title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value
        }
        NSApp.mainMenu = main
    }
    @objc private func focusSearch() { window.makeFirstResponder(searchField) }
    @objc private func pathClicked() {
        guard let url = pathControl.clickedPathItem?.url, let rootURL, let index else { return }
        let rootPath = rootURL.standardizedFileURL.path
        let clicked = url.standardizedFileURL.path
        guard clicked == rootPath || clicked.hasPrefix(rootPath + "/") else { return }
        var cursor: UInt32 = 0
        for name in clicked.dropFirst(rootPath.count).split(separator: "/").map(String.init) {
            guard let child = (0..<ft_index_child_count(index, cursor)).map({ ft_index_child_at(index, cursor, $0) }).first(where: { nodeName(index, $0) == name }) else { return }
            cursor = child
        }
        showingLargest = false; parent = cursor; searchField.stringValue = ""; refreshRows()
    }
    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) { openPanel.canChooseDirectories = true }
    @objc private func showLargest() { showingLargest = true; searchField.stringValue = ""; parent = 0; refreshRows() }
    private func selectMapItem(_ id: UInt32) {
        if let row = rows.firstIndex(of: id) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else { showDetail(id) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openSelected), #selector(revealSelected): return table.selectedRow >= 0
        case #selector(trashSelected): return table.selectedRow >= 0 && scanner == nil
        case #selector(rescan): return rootURL != nil && scanner == nil
        case #selector(stopScan): return scanner != nil
        case #selector(goBack): return index != nil && parent != 0
        case #selector(focusSearch): return index != nil
        case #selector(changeAppearance(_:)):
            item.state = (UserDefaults.standard.string(forKey: "FastTree.appearance") ?? "system") == item.representedObject as? String ? .on : .off
            return true
        default: return true
        }
    }
    private func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "FastTree.appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    @objc private func changeAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "FastTree.appearance")
        applyAppearance()
    }
    private func showDetail(_ hovered: UInt32? = nil) {
        let ids = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        guard let index, let id = hovered ?? ids.first, let record = ft_index_node(index, id) else {
            selectionLabel.stringValue = index == nil ? "Ready when you are" : "Select a file or folder"
            detailPath.stringValue = "Double-click a folder to explore it."
            return
        }
        if hovered == nil && ids.count > 1 {
            let bytes = ids.reduce(UInt64(0)) { $0 + (ft_index_node(index, $1)?.pointee.allocated_bytes ?? 0) }
            selectionLabel.stringValue = "\(ids.count.formatted()) items selected · \(sizeText(bytes)) on disk"
            detailPath.stringValue = "Show in Finder or move the selected items to Trash."
        } else {
            let node = record.pointee
            selectionLabel.stringValue = "\(nodeName(index, id)) · \(sizeText(node.allocated_bytes)) on disk · \(sizeText(node.logical_bytes)) logical" + (node.kind == 1 ? " · \(node.files.formatted()) \(node.files == 1 ? "file" : "files")" : "")
            detailPath.stringValue = url(for: id)?.path ?? ""
        }
    }
    private func updateControls() {
        backButton.isEnabled = index != nil && parent != 0
        overviewButton?.isEnabled = index != nil
        largestButton?.isEnabled = index != nil
        searchField.isEnabled = index != nil
        rescanButton.isEnabled = rootURL != nil && scanner == nil
        stopButton.isEnabled = scanner != nil
        revealButton.isEnabled = table.selectedRow >= 0
        trashButton.isEnabled = table.selectedRow >= 0 && scanner == nil
        if scanner != nil { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }
    @objc private func goRoot() { showingLargest = false; parent = 0; searchField.stringValue = ""; refreshRows() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
        map.selected = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil })
        showDetail()
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
                DispatchQueue.main.async { if self?.scanner === task { self?.lastScanError = String(line) } }
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
                if code == 0 {
                    self?.rootURL = root
                    UserDefaults.standard.set(root.path, forKey: "FastTree.lastRoot")
                    self?.loadIndex(at: output)
                }
                else if code == SIGTERM { self?.status.stringValue = "Scan stopped." }
                else { self?.status.stringValue = self?.lastScanError ?? "Scan failed (exit \(code))." }
            }
        }
        do {
            try task.run(); scanner = task; startedAt = Date()
            lastScanError = nil
            status.stringValue = "Scanning \(root.path)…"
            updateControls()
        } catch { status.stringValue = error.localizedDescription }
    }
    private func loadIndex(at url: URL) {
        guard let opened = url.path.withCString({ ft_index_open($0) }) else { return }
        map.index = nil
        if let index { ft_index_close(index) }
        index = opened; parent = 0; largestCache = nil; showingLargest = false; map.displayedIDs = nil; map.index = opened; map.parent = 0
        searchField.stringValue = ""
        refreshRows()
        let root = ft_index_node(opened, 0)!.pointee
        allocatedValue.stringValue = sizeText(root.allocated_bytes)
        filesValue.stringValue = root.files.formatted()
        foldersValue.stringValue = root.directories.formatted()
        let duration = startedAt.map { String(format: " in %.1f s", Date().timeIntervalSince($0)) } ?? ""
        status.stringValue = "Index ready · \(root.files.formatted()) files · \(root.directories.formatted()) folders\(duration)"
    }
    private func refreshRows() {
        searchWork?.cancel()
        guard let index else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty && showingLargest {
            if largestCache == nil {
                var largest = [UInt32](repeating: 0, count: 3000)
                let count = ft_index_largest_files(index, &largest, UInt32(largest.count))
                largestCache = Array(largest.prefix(Int(count)))
            }
            rows = largestCache ?? []
        } else if query.isEmpty {
            let count = ft_index_child_count(index, parent)
            rows = (0..<count).map { ft_index_child_at(index, parent, $0) }
        } else {
            rows = [UInt32](repeating: 0, count: 3000)
            let count = query.withCString { ft_index_search(index, $0, &rows, UInt32(rows.count)) }
            rows = Array(rows.prefix(Int(count)))
        }
        sortRows()
        pathLabel.stringValue = (rootURL?.path ?? "") + (parent == 0 ? "" : "/" + pathComponents(for: parent).joined(separator: "/"))
        locationTitle.stringValue = !query.isEmpty ? "Search results" : showingLargest ? "Largest files" : parent == 0 ? (rootURL?.lastPathComponent == "Data" ? "Macintosh HD" : rootURL?.lastPathComponent ?? "Storage") : nodeName(index, parent)
        pathControl.url = url(for: parent)
        let rootPath = rootURL?.standardizedFileURL.path ?? ""
        let visibleItems = pathControl.pathItems.filter {
            guard let path = $0.url?.standardizedFileURL.path else { return false }
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        if let first = visibleItems.first {
            first.title = rootURL?.lastPathComponent == "Data" ? "Macintosh HD" : rootURL?.lastPathComponent ?? "Storage"
            first.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        }
        pathControl.pathItems = visibleItems
        sidebarLocation.stringValue = rootURL?.path ?? "No location scanned"
        sidebarLocation.toolTip = sidebarLocation.stringValue
        overviewButton.selected = !showingLargest
        largestButton.selected = showingLargest
        window.subtitle = locationTitle.stringValue
        let node = ft_index_node(index, parent)!.pointee
        allocatedValue.stringValue = sizeText(node.allocated_bytes)
        filesValue.stringValue = node.files.formatted()
        foldersValue.stringValue = (node.directories - (parent == 0 || node.directories == 0 ? 0 : 1)).formatted()
        let children = (0..<ft_index_child_count(index, parent)).map { ft_index_child_at(index, parent, $0) }
            .sorted { ft_index_node(index, $0)!.pointee.allocated_bytes > ft_index_node(index, $1)!.pointee.allocated_bytes }
        storageBar.entries = children.map { (nodeName(index, $0), ft_index_node(index, $0)!.pointee.allocated_bytes) }
        for view in legend.arrangedSubviews { legend.removeArrangedSubview(view); view.removeFromSuperview() }
        for id in children.prefix(4) {
            let name = nodeName(index, id)
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            dot.contentTintColor = Style.color(name); dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            let label = Style.label(name, size: 10, color: .secondaryLabelColor)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
            let entry = Style.stack([dot, label], spacing: 5)
            entry.setContentHuggingPriority(.required, for: .horizontal)
            legend.addArrangedSubview(entry)
        }
        legend.addArrangedSubview(NSView())
        mapTitle.stringValue = !query.isEmpty ? "Search Map" : showingLargest ? "Largest Files Map" : "Space Map"
        mapScope.stringValue = query.isEmpty && !showingLargest ? "On-disk size" : "Displayed items"
        itemCount.stringValue = rows.count == 3000 ? (showingLargest && query.isEmpty ? "Top 3,000 files" : "First 3,000 matches") : "\(rows.count.formatted()) items"
        table.deselectAll(nil); table.reloadData(); map.parent = parent; map.displayedIDs = !query.isEmpty || showingLargest ? rows : nil; map.needsDisplay = true
        showDetail()
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
        parent = node.pointee.parent; searchField.stringValue = ""; refreshRows()
    }
    @objc private func searchChanged() {
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshRows() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    @objc private func openSelected() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        open(rows[table.selectedRow])
    }
    private func open(_ id: UInt32) {
        guard let index, let node = ft_index_node(index, id) else { return }
        if node.pointee.kind == 1 { showingLargest = false; parent = id; searchField.stringValue = ""; refreshRows() }
        else if let url = url(for: id) { NSWorkspace.shared.open(url) }
    }
    @objc private func revealSelected() {
        let urls = table.selectedRowIndexes.compactMap { $0 < rows.count ? url(for: rows[$0]) : nil }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc private func trashSelected() {
        guard scanner == nil, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let urls = table.selectedRowIndexes.compactMap { $0 < rows.count ? url(for: rows[$0]) : nil }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to Trash?" : "Move \(urls.count) items to Trash?"
        alert.informativeText = "You can restore them from Trash. The location will be rescanned afterward."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var failures: [String] = []
            for url in urls {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty {
                let error = NSAlert(); error.messageText = "Some items could not be moved to Trash"
                error.informativeText = failures.joined(separator: "\n"); error.beginSheetModal(for: self.window)
            }
            self.rescan()
        }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = table.sortDescriptors.first else { return }
        sortKey = descriptor.key ?? "allocated"; sortAscending = descriptor.ascending
        let selected = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil })
        sortRows(); table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0]) }), byExtendingSelection: false)
    }
    private func sortRows() {
        guard let index else { return }
        rows.sort { a, b in
            let left = ft_index_node(index, a)!.pointee, right = ft_index_node(index, b)!.pointee
            let comparison: ComparisonResult
            if sortKey == "name" { comparison = nodeName(index, a).localizedStandardCompare(nodeName(index, b)) }
            else {
                let l = sortKey == "files" ? UInt64(left.files) : sortKey == "logical" ? left.logical_bytes : left.allocated_bytes
                let r = sortKey == "files" ? UInt64(right.files) : sortKey == "logical" ? right.logical_bytes : right.allocated_bytes
                comparison = l == r ? nodeName(index, a).localizedStandardCompare(nodeName(index, b)) : l < r ? .orderedAscending : .orderedDescending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
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
        case "share":
            let total = ft_index_node(index, parent)?.pointee.allocated_bytes ?? 0
            text.stringValue = total > 0 ? (Double(record.pointee.allocated_bytes) / Double(total) * 100).formatted(.number.precision(.fractionLength(1))) : "—"
        case "files": text.stringValue = record.pointee.kind == 1 ? record.pointee.files.formatted() : "—"
        case "modified": text.stringValue = record.pointee.modified_seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(record.pointee.modified_seconds)).formatted(date: .abbreviated, time: .omitted) : ""
        default: break
        }
        text.font = id == "name" ? .systemFont(ofSize: 12, weight: .medium) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        text.textColor = id == "name" || id == "allocated" ? .labelColor : .secondaryLabelColor
        if id == "allocated" || id == "logical" || id == "files" || id == "share" { text.alignment = .right }
        cell.addSubview(text); cell.textField = text
        var leading: CGFloat = 8
        if id == "name" {
            let icon = NSImageView(image: NSImage(systemSymbolName: record.pointee.kind == 1 ? "folder.fill" : "doc.fill", accessibilityDescription: record.pointee.kind == 1 ? "Folder" : "File")!)
            icon.contentTintColor = record.pointee.kind == 1 ? .systemBlue : .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
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
