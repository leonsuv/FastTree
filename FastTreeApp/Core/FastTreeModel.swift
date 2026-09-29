import Foundation
import Combine
import FastTreeCore

typealias FTNodeID = UInt32

enum FTNodeKind: UInt8, Codable { case file = 0, directory = 1, hardlink = 2, other = 3 }

struct FTNode: Identifiable, Hashable {
    let id: FTNodeID
    let parentID: FTNodeID?
    let name: String
    let kind: FTNodeKind
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let fileCount: UInt32
    let directoryCount: UInt32
    let modifiedAt: Date?
    var isDirectory: Bool { kind == .directory }
}

struct FTScanProgress: Equatable {
    enum State: Equatable { case idle, scanning, ready, cancelled, failed(String) }
    var state: State = .idle
    var files: UInt64 = 0
    var directories: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var skipped: UInt64 = 0
    var elapsed: TimeInterval = 0
}

@MainActor final class FastTreeModel: ObservableObject {
    @Published private(set) var progress = FTScanProgress()
    @Published private(set) var rootID: FTNodeID?
    @Published private(set) var generation: UInt64 = 0
    @Published var selectedNodeID: FTNodeID?
    @Published var focusedDirectoryID: FTNodeID?
    @Published var searchQuery = ""
    @Published var selectedFileCategory: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var scanRootURL: URL?
    @Published var excludedPaths: Set<String> = []

    private var index: OpaquePointer?
    private var scanner: Process?
    private var indexURL: URL?

    init() {
        if let previous = UserDefaults.standard.string(forKey: "FastTree.lastRoot") {
            let url = URL(fileURLWithPath: previous)
            scanRootURL = url
            let saved = persistentURL(for: url)
            if FileManager.default.fileExists(atPath: saved.path) { loadIndex(at: saved) }
        }
    }

    deinit { if let index { ft_index_close(index) } }

    private func persistentURL(for root: URL) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastTree/Indices", isDirectory: true)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in root.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(format: "%016llx.ftidx", hash))
    }

    private func scannerURL() -> URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("fasttree-scan")
        if let bundled, fm.isExecutableFile(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("scanners/agent-2-5-hybrid/fasttree-scan")
        return fm.isExecutableFile(atPath: development.path) ? development : nil
    }

    func startScan(_ url: URL) {
        cancelScan()
        let root = url.standardizedFileURL
        guard let executable = scannerURL() else {
            errorMessage = "FastTree scanner executable was not found."
            progress.state = .failed(errorMessage!)
            return
        }
        let destination = persistentURL(for: root)
        do { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { errorMessage = error.localizedDescription; progress.state = .failed(error.localizedDescription); return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [root.path, "--threads", "6", "--benchmark", "--index", destination.path, "--progress"]
            + excludedPaths.sorted().flatMap { ["--exclude", $0] }
        process.standardOutput = Pipe()
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            for line in lines where line.hasPrefix("FTPROGRESS ") {
                guard let payload = line.dropFirst(11).data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: payload) as? [String: NSNumber] else { continue }
                let files = value["files"]?.uint64Value ?? 0
                let dirs = value["dirs"]?.uint64Value ?? 0
                let logical = value["logical_bytes"]?.uint64Value ?? 0
                let allocated = value["allocated_bytes"]?.uint64Value ?? 0
                let skipped = value["skipped"]?.uint64Value ?? 0
                Task { @MainActor [weak self] in
                    guard let self, self.scanner === process else { return }
                    self.progress.files = files; self.progress.directories = dirs
                    self.progress.logicalBytes = logical; self.progress.allocatedBytes = allocated
                    self.progress.skipped = skipped
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.scanner === finished else { return }
                errors.fileHandleForReading.readabilityHandler = nil
                self.scanner = nil
                if status == 0 { self.loadIndex(at: destination) }
                else if status == SIGTERM { self.progress.state = .cancelled }
                else { self.errorMessage = "Scan failed (exit \(status))."; self.progress.state = .failed(self.errorMessage!) }
            }
        }
        do {
            try process.run()
            scanner = process
            scanRootURL = root
            indexURL = destination
            UserDefaults.standard.set(root.path, forKey: "FastTree.lastRoot")
            errorMessage = nil
            progress = FTScanProgress(state: .scanning)
        } catch { errorMessage = error.localizedDescription; progress.state = .failed(error.localizedDescription) }
    }

    func cancelScan() { if let scanner, scanner.isRunning { scanner.terminate() } }

    func rescan() { if let scanRootURL { startScan(scanRootURL) } }

    private func loadIndex(at url: URL) {
        guard let opened = url.path.withCString({ ft_index_open($0) }) else {
            errorMessage = "The saved FastTree index could not be opened."
            progress.state = .failed(errorMessage!)
            return
        }
        if let index { ft_index_close(index) }
        index = opened
        indexURL = url
        rootID = 0
        focusedDirectoryID = 0
        selectedNodeID = nil
        if let root = node(0) {
            progress = FTScanProgress(state: .ready, files: UInt64(root.fileCount),
                directories: UInt64(root.directoryCount), logicalBytes: root.logicalBytes,
                allocatedBytes: root.allocatedBytes)
        }
        generation &+= 1
    }

    func node(_ id: FTNodeID) -> FTNode? {
        guard let index, let record = ft_index_node(index, id),
              let ptr = ft_index_name(index, id, nil) else { return nil }
        let length = Int(record.pointee.name_length)
        let name = String(decoding: UnsafeRawBufferPointer(start: ptr, count: length), as: UTF8.self)
        let raw = record.pointee
        return FTNode(id: id, parentID: id == 0 ? nil : raw.parent, name: name,
            kind: FTNodeKind(rawValue: raw.kind) ?? .other,
            logicalBytes: raw.logical_bytes, allocatedBytes: raw.allocated_bytes,
            fileCount: raw.files, directoryCount: raw.directories,
            modifiedAt: raw.modified_seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(raw.modified_seconds)) : nil)
    }

    func children(of id: FTNodeID) -> [FTNodeID] {
        guard let index else { return [] }
        let count = ft_index_child_count(index, id)
        return (0..<count).map { ft_index_child_at(index, id, $0) }
    }

    func path(for id: FTNodeID) -> URL? {
        guard let scanRootURL, let index, id < ft_index_count(index) else { return nil }
        var names: [String] = []
        var cursor = id
        var depth = 0
        while cursor != 0 && depth < 1024 {
            guard let item = node(cursor) else { return nil }
            names.append(item.name)
            cursor = item.parentID ?? 0
            depth += 1
        }
        guard cursor == 0 else { return nil }
        return names.reversed().reduce(scanRootURL) { $0.appendingPathComponent($1) }
    }

    func search(_ query: String, limit: Int = 500) -> [FTNodeID] {
        guard let index, limit > 0 else { return [] }
        var ids = [FTNodeID](repeating: 0, count: limit)
        let count = query.withCString { ft_index_search(index, $0, &ids, UInt32(limit)) }
        return Array(ids.prefix(Int(count)))
    }

    func largestFiles(limit: Int) -> [FTNodeID] {
        guard let index, limit > 0 else { return [] }
        var ids = [FTNodeID](repeating: 0, count: limit)
        let count = ft_index_largest_files(index, &ids, UInt32(limit))
        return Array(ids.prefix(Int(count)))
    }

    func oldAndLarge(minBytes: UInt64, olderThan: Date, limit: Int) -> [FTNodeID] {
        guard let index, limit > 0 else { return [] }
        var ids = [FTNodeID](repeating: 0, count: limit)
        let count = ft_index_old_large(index, minBytes, Int64(olderThan.timeIntervalSince1970), &ids, UInt32(limit))
        return Array(ids.prefix(Int(count)))
    }

    func moveToTrash(_ ids: [FTNodeID]) async throws {
        for id in Set(ids) where id != rootID {
            guard let url = path(for: id) else { continue }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
