import SwiftUI

private struct FTTypeTotal: Identifiable {
    let id: String
    var bytes: UInt64 = 0
    var files: UInt64 = 0
    var largest: [(name: String, bytes: UInt64)] = []

    mutating func include(_ node: FTNode, fileCount: UInt64 = 1) {
        bytes = bytes &+ node.allocatedBytes
        files = files &+ fileCount
        if largest.count < 3 || node.allocatedBytes > largest.last!.bytes {
            largest.append((node.name, node.allocatedBytes))
            largest.sort { $0.bytes > $1.bytes }
            if largest.count > 3 { largest.removeLast() }
        }
    }
}

enum FTFileCategory {
    static func name(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return "Videos"
        case "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "raw", "cr2", "nef", "psd": return "Images"
        case "app", "ipa", "pkg": return "Applications"
        case "zip", "7z", "rar", "tar", "gz", "xz", "bz2", "zst": return "Archives"
        case "pdf", "doc", "docx", "pages", "txt", "md", "rtf", "ppt", "pptx", "key", "xls", "xlsx", "numbers": return "Documents"
        case "mp3", "m4a", "flac", "wav", "aiff", "aac", "ogg": return "Audio"
        case "swift", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "py", "js", "ts", "jsx", "tsx", "java", "kt", "class", "o", "a", "dylib": return "Developer files"
        case "vmdk", "vdi", "qcow2", "pvm", "vbox": return "Virtual machines"
        case "dmg", "iso", "sparseimage", "sparsebundle": return "Disk images"
        case "db", "sqlite", "sqlite3", "log", "cache", "plist": return "System data"
        default: return "Other"
        }
    }
}

/// Computes a file-type breakdown from the current in-memory index. Traversal
/// yields between batches so a large directory does not monopolize the UI loop.
/// Selection hands a category key to the containing file table's filter control.
struct FastTreeFileTypesView: View {
    @ObservedObject var model: FastTreeModel
    var onSelectCategory: (String?) -> Void = { _ in }

    @StateObject private var viewState = FTTypesViewState()

    private var focusID: FTNodeID? { model.focusedDirectoryID ?? model.rootID }
    private var refreshKey: String { "\(focusID.map(String.init) ?? "none")-\(model.generation)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("File types").font(.headline)
                Spacer()
                if viewState.computing { ProgressView().controlSize(.small) }
                if viewState.selectedCategory != nil {
                    Button("Clear filter") {
                        viewState.selectedCategory = nil
                        onSelectCategory(nil)
                    }
                    .buttonStyle(.link)
                }
            }
            if viewState.categories.isEmpty && !viewState.computing {
                Text("No files in this folder")
                    .foregroundStyle(.secondary)
            } else {
                let total = viewState.categories.reduce(UInt64(0)) { $0 &+ $1.bytes }
                ForEach(viewState.categories) { category in
                    Button {
                        viewState.selectedCategory = category.id
                        onSelectCategory(category.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(category.id).frame(width: 120, alignment: .leading)
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(category.id == viewState.selectedCategory ? Color.accentColor : Color.accentColor.opacity(0.5))
                                    .frame(width: total > 0 ? max(2, geometry.size.width * CGFloat(Double(category.bytes) / Double(total))) : 0,
                                           height: 7)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 16)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: category.bytes), countStyle: .file))
                                .frame(width: 90, alignment: .trailing)
                            Text("\(category.files.formatted()) files")
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .trailing)
                        }
                        .font(.system(size: 11))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(category.largest.map { "\($0.name): \(ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.bytes), countStyle: .file))" }.joined(separator: "\n"))
                }
                if !viewState.extensions.isEmpty {
                    Divider()
                    Text("Largest extensions").font(.subheadline.weight(.semibold))
                    ForEach(viewState.extensions.prefix(12)) { item in
                        HStack {
                            Text(item.id).frame(width: 90, alignment: .leading)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.bytes), countStyle: .file))
                            Text("\(item.files.formatted()) files")
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .trailing)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(10)
        .task(id: refreshKey) { await rebuild() }
    }

    @MainActor private func rebuild() async {
        viewState.categories = []
        viewState.extensions = []
        guard let focusID else { return }
        viewState.computing = true
        var byCategory: [String: FTTypeTotal] = [:]
        var byExtension: [String: FTTypeTotal] = [:]
        var pending = [focusID]
        var visited = 0
        while let current = pending.popLast() {
            if Task.isCancelled { viewState.computing = false; return }
            for id in model.children(of: current) {
                guard let node = model.node(id) else { continue }
                let ext = (node.name as NSString).pathExtension.lowercased()
                if node.isDirectory && ext == "app" {
                    var applications = byCategory["Applications"] ?? FTTypeTotal(id: "Applications")
                    applications.include(node, fileCount: UInt64(node.fileCount))
                    byCategory["Applications"] = applications
                    var extensionTotal = byExtension[".app"] ?? FTTypeTotal(id: ".app")
                    extensionTotal.include(node, fileCount: UInt64(node.fileCount))
                    byExtension[".app"] = extensionTotal
                } else if node.isDirectory {
                    pending.append(id)
                } else if node.kind == .file {
                    let category = FTFileCategory.name(for: node.name)
                    var categoryTotal = byCategory[category] ?? FTTypeTotal(id: category)
                    categoryTotal.include(node)
                    byCategory[category] = categoryTotal
                    let key = ext.isEmpty ? "(none)" : ".\(ext)"
                    var extensionTotal = byExtension[key] ?? FTTypeTotal(id: key)
                    extensionTotal.include(node)
                    byExtension[key] = extensionTotal
                }
                visited += 1
                if visited % 8_192 == 0 { await Task.yield() }
            }
        }
        viewState.categories = byCategory.values.sorted { $0.bytes > $1.bytes }
        viewState.extensions = byExtension.values.sorted { $0.bytes > $1.bytes }
        viewState.computing = false
    }
}

private final class FTTypesViewState: ObservableObject {
    @Published var categories: [FTTypeTotal] = []
    @Published var extensions: [FTTypeTotal] = []
    @Published var selectedCategory: String?
    @Published var computing = false
}
