import AppKit
import SwiftUI

enum FTTreemapMetric: String, CaseIterable, Identifiable {
    case allocated = "Allocated"
    case logical = "Logical"
    var id: String { rawValue }

    func bytes(_ node: FTNode) -> UInt64 {
        self == .allocated ? node.allocatedBytes : node.logicalBytes
    }
}

/// The treemap reads the live FastTreeCore index through FastTreeModel. Only the
/// visible directory's immediate children become rectangles; tiny siblings are
/// combined so drawing cost stays bounded even for very wide directories.
struct FastTreeTreemapView: View {
    @ObservedObject var model: FastTreeModel
    @StateObject private var preferences = FTTreemapPreferences()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    guard let focus = model.focusedDirectoryID ?? model.rootID,
                          let parent = model.node(focus)?.parentID else { return }
                    model.focusedDirectoryID = parent
                    model.selectedNodeID = parent
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Zoom out to parent folder")
                .disabled((model.focusedDirectoryID ?? model.rootID) == model.rootID)

                if let focus = model.focusedDirectoryID ?? model.rootID,
                   let node = model.node(focus) {
                    Text(node.name.isEmpty ? "/" : node.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .help(model.path(for: focus)?.path ?? node.name)
                } else {
                    Text("Treemap").font(.system(size: 12, weight: .semibold))
                }
                Spacer(minLength: 8)
                Picker("Size", selection: $preferences.metric) {
                    ForEach(FTTreemapMetric.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 9)
            .frame(height: 34)

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)

            if model.rootID == nil {
                VStack(spacing: 7) {
                    Image(systemName: "square.grid.3x3").font(.title2)
                    Text("No scan yet").font(.headline)
                    Text("Select a volume or folder to scan.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FTTreemapCanvas(model: model, metric: preferences.metric)
                    .accessibilityLabel("Disk usage treemap")
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private final class FTTreemapPreferences: ObservableObject {
    @Published var metric: FTTreemapMetric = .allocated
}

private struct FTTreemapCanvas: NSViewRepresentable {
    @ObservedObject var model: FastTreeModel
    let metric: FTTreemapMetric

    func makeNSView(context: Context) -> FTTreemapNSView {
        let view = FTTreemapNSView()
        view.configure(model: model, metric: metric)
        return view
    }

    func updateNSView(_ nsView: FTTreemapNSView, context: Context) {
        nsView.configure(model: model, metric: metric)
    }
}

private struct FTTreemapEntry {
    let id: FTNodeID?
    let name: String
    let kind: FTNodeKind
    let bytes: UInt64
    let logical: UInt64
    let allocated: UInt64
    let files: UInt64
    let directories: UInt64
}

private struct FTTreemapTile {
    let entry: FTTreemapEntry
    let rect: CGRect
}

@MainActor private final class FTTreemapNSView: NSView {
    private let maxTiles = 1_500
    private var model: FastTreeModel?
    private var metric: FTTreemapMetric = .allocated
    private var focusID: FTNodeID?
    private var generation: UInt64 = .max
    private var laidOutSize: CGSize = .zero
    private var entries: [FTTreemapEntry] = []
    private var tiles: [FTTreemapTile] = []
    private var hoveredID: FTNodeID?
    private var hoveredTile: Int?
    private var scale: CGFloat = 1
    private var pan: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(model: FastTreeModel, metric: FTTreemapMetric) {
        self.model = model
        let nextFocus = model.focusedDirectoryID ?? model.rootID
        if nextFocus != focusID || metric != self.metric {
            focusID = nextFocus
            self.metric = metric
            scale = 1
            pan = .zero
            generation = .max
        }
        if generation != model.generation {
            generation = model.generation
            reloadEntries()
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            makeTiles()
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private func reloadEntries() {
        guard let model, let focusID else {
            entries = []
            tiles = []
            return
        }
        let children = model.children(of: focusID)
        var heap: [FTTreemapEntry] = []
        heap.reserveCapacity(min(children.count, maxTiles))
        var remainingBytes: UInt64 = 0
        var remainingLogical: UInt64 = 0
        var remainingAllocated: UInt64 = 0
        var remainingFiles: UInt64 = 0
        var remainingDirectories: UInt64 = 0

        func addToOther(_ entry: FTTreemapEntry) {
            remainingBytes = remainingBytes &+ entry.bytes
            remainingLogical = remainingLogical &+ entry.logical
            remainingAllocated = remainingAllocated &+ entry.allocated
            remainingFiles = remainingFiles &+ entry.files
            remainingDirectories = remainingDirectories &+ entry.directories
        }

        // A bounded min heap selects the largest entries without sorting millions
        // of child IDs or creating a rectangle for every file.
        for id in children {
            guard let node = model.node(id) else { continue }
            let value = metric.bytes(node)
            let entry = FTTreemapEntry(id: id, name: node.name, kind: node.kind,
                                       bytes: value, logical: node.logicalBytes,
                                       allocated: node.allocatedBytes,
                                       files: UInt64(node.fileCount),
                                       directories: UInt64(node.directoryCount))
            if heap.count < maxTiles {
                heap.append(entry)
                siftUp(&heap, heap.count - 1)
            } else if value > heap[0].bytes {
                addToOther(heap[0])
                heap[0] = entry
                siftDown(&heap, 0)
            } else {
                addToOther(entry)
            }
        }
        entries = heap.sorted { $0.bytes > $1.bytes }
        if remainingBytes > 0 {
            entries.append(FTTreemapEntry(id: nil, name: "Other", kind: .other,
                                          bytes: remainingBytes, logical: remainingLogical,
                                          allocated: remainingAllocated, files: remainingFiles,
                                          directories: remainingDirectories))
        }
        makeTiles()
    }

    private func siftUp(_ heap: inout [FTTreemapEntry], _ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if heap[parent].bytes <= heap[child].bytes { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private func siftDown(_ heap: inout [FTTreemapEntry], _ index: Int) {
        var parent = index
        while parent * 2 + 1 < heap.count {
            var child = parent * 2 + 1
            if child + 1 < heap.count && heap[child + 1].bytes < heap[child].bytes { child += 1 }
            if heap[parent].bytes <= heap[child].bytes { break }
            heap.swapAt(parent, child)
            parent = child
        }
    }

    private func makeTiles() {
        let available = bounds.insetBy(dx: 3, dy: 3)
        guard available.width > 0, available.height > 0 else { tiles = []; return }
        let total = entries.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { tiles = []; needsDisplay = true; return }
        let area = Double(available.width * available.height)
        let minimumArea = 9.0
        var visible: [(FTTreemapEntry, Double)] = []
        var other: FTTreemapEntry?
        var otherArea = 0.0
        for entry in entries {
            let entryArea = Double(entry.bytes) / total * area
            if entry.id == nil || entryArea < minimumArea {
                otherArea += entryArea
                if let old = other {
                    other = FTTreemapEntry(id: nil, name: "Other", kind: .other,
                                            bytes: old.bytes &+ entry.bytes,
                                            logical: old.logical &+ entry.logical,
                                            allocated: old.allocated &+ entry.allocated,
                                            files: old.files &+ entry.files,
                                            directories: old.directories &+ entry.directories)
                } else {
                    other = FTTreemapEntry(id: nil, name: "Other", kind: .other,
                                            bytes: entry.bytes, logical: entry.logical,
                                            allocated: entry.allocated, files: entry.files,
                                            directories: entry.directories)
                }
            } else {
                visible.append((entry, entryArea))
            }
        }
        if let other, otherArea > 0 { visible.append((other, otherArea)) }
        visible.sort { $0.1 > $1.1 }
        tiles = squarify(visible, in: available)
        needsDisplay = true
    }

    private func squarify(_ input: [(FTTreemapEntry, Double)], in area: CGRect) -> [FTTreemapTile] {
        var result: [FTTreemapTile] = []
        result.reserveCapacity(input.count)
        var remaining = area
        var row: [(FTTreemapEntry, Double)] = []
        var rowArea = 0.0

        func aspect(_ values: [(FTTreemapEntry, Double)], _ sum: Double, _ short: Double) -> Double {
            guard !values.isEmpty, sum > 0, short > 0 else { return .infinity }
            let maxArea = values.first!.1
            let minArea = values.last!.1
            guard minArea > 0 else { return .infinity }
            let square = sum * sum
            return max(short * short * maxArea / square, square / (short * short * minArea))
        }

        func flush() {
            guard !row.isEmpty, rowArea > 0 else { return }
            if remaining.width >= remaining.height {
                let stripWidth = CGFloat(rowArea) / max(remaining.height, 0.001)
                var y = remaining.minY
                for (entry, itemArea) in row {
                    let height = CGFloat(itemArea) / max(stripWidth, 0.001)
                    result.append(FTTreemapTile(entry: entry, rect: CGRect(x: remaining.minX, y: y, width: stripWidth, height: height)))
                    y += height
                }
                remaining.origin.x += stripWidth
                remaining.size.width = max(0, remaining.width - stripWidth)
            } else {
                let stripHeight = CGFloat(rowArea) / max(remaining.width, 0.001)
                var x = remaining.minX
                for (entry, itemArea) in row {
                    let width = CGFloat(itemArea) / max(stripHeight, 0.001)
                    result.append(FTTreemapTile(entry: entry, rect: CGRect(x: x, y: remaining.minY, width: width, height: stripHeight)))
                    x += width
                }
                remaining.origin.y += stripHeight
                remaining.size.height = max(0, remaining.height - stripHeight)
            }
            row.removeAll(keepingCapacity: true)
            rowArea = 0
        }

        for candidate in input {
            guard candidate.1 > 0 else { continue }
            let short = Double(min(remaining.width, remaining.height))
            let prior = aspect(row, rowArea, short)
            let proposed = aspect(row + [candidate], rowArea + candidate.1, short)
            if !row.isEmpty && proposed > prior {
                flush()
            }
            row.append(candidate)
            rowArea += candidate.1
        }
        flush()
        return result
    }

    private func transformed(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale + pan.x,
               y: rect.minY * scale + pan.y,
               width: rect.width * scale, height: rect.height * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        for (index, tile) in tiles.enumerated() {
            let rect = transformed(tile.rect).insetBy(dx: 0.8, dy: 0.8)
            guard rect.width > 0, rect.height > 0, rect.intersects(dirtyRect) else { continue }
            let selected = tile.entry.id != nil && tile.entry.id == model?.selectedNodeID
            let hovered = index == hoveredTile
            let color = FTTreemapColor.color(name: tile.entry.name, kind: tile.entry.kind)
            context.setFillColor(color.cgColor)
            context.fill(rect)
            if selected || hovered {
                context.setStrokeColor((selected ? NSColor.white : NSColor.labelColor).cgColor)
                context.setLineWidth(selected ? 2.5 : 1.5)
                context.stroke(rect.insetBy(dx: 1, dy: 1))
            }
            if rect.width > 60 && rect.height > 19 {
                let text = tile.entry.name as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                    .foregroundColor: NSColor.white,
                    .shadow: {
                        let shadow = NSShadow()
                        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
                        shadow.shadowBlurRadius = 2
                        return shadow
                    }()
                ]
                context.saveGState()
                context.clip(to: rect.insetBy(dx: 3, dy: 2))
                text.draw(at: CGPoint(x: rect.minX + 5, y: rect.minY + 3), withAttributes: attrs)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    private func tileIndex(at point: CGPoint) -> Int? {
        guard scale > 0 else { return nil }
        let original = CGPoint(x: (point.x - pan.x) / scale, y: (point.y - pan.y) / scale)
        return tiles.firstIndex { $0.rect.contains(original) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = tileIndex(at: point)
        if hoveredTile != next {
            hoveredTile = next
            hoveredID = next.flatMap { tiles[$0].entry.id }
            toolTip = next.map { tooltip(for: tiles[$0].entry) }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTile = nil
        hoveredID = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tileIndex(at: point), let id = tiles[index].entry.id else { return }
        model?.selectedNodeID = id
        if event.clickCount == 2, tiles[index].entry.kind == .directory {
            model?.focusedDirectoryID = id
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 53 { // Delete / Escape zooms out.
            guard let model, let focus = model.focusedDirectoryID ?? model.rootID,
                  let parent = model.node(focus)?.parentID else { return }
            model.focusedDirectoryID = parent
            return
        }
        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let next = min(8, max(1, scale * (1 + event.magnification)))
        let ratio = next / scale
        pan.x = anchor.x - (anchor.x - pan.x) * ratio
        pan.y = anchor.y - (anchor.y - pan.y) * ratio
        scale = next
        constrainPan()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard scale > 1 else { return }
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        constrainPan()
        needsDisplay = true
    }

    private func constrainPan() {
        pan.x = min(0, max(bounds.width * (1 - scale), pan.x))
        pan.y = min(0, max(bounds.height * (1 - scale), pan.y))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tileIndex(at: point), let id = tiles[index].entry.id else { return nil }
        model?.selectedNodeID = id
        let menu = NSMenu()
        if tiles[index].entry.kind == .directory {
            let open = NSMenuItem(title: "Zoom Into Folder", action: #selector(zoomToSelected), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelected), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copySelectedPath), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    @objc private func zoomToSelected() {
        guard let model, let id = model.selectedNodeID, model.node(id)?.isDirectory == true else { return }
        model.focusedDirectoryID = id
    }

    @objc private func revealSelected() {
        guard let model, let id = model.selectedNodeID, let url = model.path(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copySelectedPath() {
        guard let model, let id = model.selectedNodeID, let url = model.path(for: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func tooltip(for entry: FTTreemapEntry) -> String {
        var lines = [entry.name,
                     "Allocated: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.allocated), countStyle: .file))",
                     "Logical: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.logical), countStyle: .file))",
                     "Files: \(entry.files.formatted())"]
        if let id = entry.id, let path = model?.path(for: id)?.path { lines.append(path) }
        return lines.joined(separator: "\n")
    }
}

private enum FTTreemapColor {
    static func color(name: String, kind: FTNodeKind) -> NSColor {
        if kind == .directory { return NSColor(calibratedRed: 0.19, green: 0.40, blue: 0.68, alpha: 1) }
        if kind == .other { return NSColor(calibratedWhite: 0.42, alpha: 1) }
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "webm": return NSColor(calibratedRed: 0.65, green: 0.28, blue: 0.43, alpha: 1)
        case "jpg", "jpeg", "png", "heic", "tiff", "raw", "psd": return NSColor(calibratedRed: 0.35, green: 0.56, blue: 0.32, alpha: 1)
        case "zip", "7z", "rar", "tar", "gz", "xz": return NSColor(calibratedRed: 0.64, green: 0.47, blue: 0.24, alpha: 1)
        case "dmg", "iso", "sparseimage": return NSColor(calibratedRed: 0.44, green: 0.35, blue: 0.65, alpha: 1)
        case "pdf", "doc", "docx", "pages", "txt", "md": return NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.57, alpha: 1)
        case "mp3", "m4a", "flac", "wav", "aiff": return NSColor(calibratedRed: 0.58, green: 0.38, blue: 0.60, alpha: 1)
        case "swift", "c", "cpp", "h", "rs", "js", "ts", "py": return NSColor(calibratedRed: 0.66, green: 0.45, blue: 0.30, alpha: 1)
        default: return NSColor(calibratedRed: 0.34, green: 0.47, blue: 0.55, alpha: 1)
        }
    }
}
