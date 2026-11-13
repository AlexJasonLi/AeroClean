import Darwin
import Foundation

/// a file big enough to list on its own. smaller files only add to their folder's total.
public struct IndexedFile: Sendable, Hashable, Codable {
    public let folder: Int32
    public let name: String
    /// space on disk.
    public let allocated: Int64
    /// length of the contents, what duplicate matching compares.
    public let length: Int64
    public let modified: Double
    public let accessed: Double
}

/// sizes of every folder under the scanned roots, plus every file over `bigFileMinimum`.
/// one scan feeds the space map, large files, duplicate candidates and system data.
public struct DiskIndex: Sendable, Codable {
    public let roots: [Int32]
    public let rootPaths: [String]
    public let names: [String]
    public let parents: [Int32]
    /// bytes in the folder and everything below it.
    public let totals: [Int64]
    /// files in the folder and everything below it.
    public let fileCounts: [Int64]
    /// bytes and count of files directly inside that are under the big-file minimum.
    public let smallBytes: [Int64]
    public let smallCounts: [Int32]
    /// the folder could not be read, so its total is a lower bound.
    public let unreadable: [Bool]
    public let files: [IndexedFile]
    public let bigFileMinimum: Int64
    public let scannedAt: Date
    public let duration: Double

    // derived on load, not stored.
    public var childFolders: [[Int32]] { Self.children(parents) }

    static func children(_ parents: [Int32]) -> [[Int32]] {
        var result = Array(repeating: [Int32](), count: parents.count)
        for (index, parent) in parents.enumerated() where parent >= 0 {
            result[Int(parent)].append(Int32(index))
        }
        return result
    }

    public func path(of folder: Int32) -> String {
        var parts: [String] = []
        var current = folder
        while current >= 0 {
            if parents[Int(current)] < 0, let root = roots.firstIndex(of: current) {
                parts.append(rootPaths[root])
                break
            }
            parts.append(names[Int(current)])
            current = parents[Int(current)]
        }
        return parts.reversed().joined(separator: "/")
    }

    public func path(of file: IndexedFile) -> String { path(of: file.folder) + "/" + file.name }

    /// the folder node for an absolute path, if it was scanned.
    public func folder(at path: String, lookup: [String: Int32]? = nil) -> Int32? {
        if let lookup { return lookup[path] }
        for (index, rootPath) in rootPaths.enumerated() {
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            var node = roots[index]
            let rest = path.dropFirst(rootPath.count).split(separator: "/")
            let kids = childFolders
            for part in rest {
                guard let next = kids[Int(node)].first(where: { names[Int($0)] == part }) else { return nil }
                node = next
            }
            return node
        }
        return nil
    }

    public var totalBytes: Int64 { roots.reduce(0) { $0 + totals[Int($1)] } }
    public var totalFiles: Int64 { roots.reduce(0) { $0 + fileCounts[Int($1)] } }
}

/// walks folders with getattrlistbulk on many threads: one system call returns a whole
/// batch of entries with their sizes, instead of one stat per file. the same approach as
/// healeycodes/dumac, written here from the system call documentation.
public enum FastScanner {
    public struct Progress: Sendable {
        public let files: Int64
        public let bytes: Int64
        public let folders: Int
    }

    public static func scan(
        roots: [URL],
        bigFileMinimum: Int64 = 1_000_000,
        threads: Int = 16,
        progress: (@Sendable (Progress) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> DiskIndex {
        let started = Date()
        let state = ScanState(bigFileMinimum: bigFileMinimum)
        let rootPaths = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        var rootIndices: [Int32] = []
        for path in rootPaths {
            rootIndices.append(state.addRoot(path))
        }

        let group = DispatchGroup()
        for _ in 0..<max(threads, 1) {
            group.enter()
            let thread = Thread {
                state.work(isCancelled: isCancelled, progress: progress)
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        return state.finish(roots: rootIndices, rootPaths: rootPaths, started: started)
    }
}

/// shared state of one scan. every array is touched only under `lock`; the system calls
/// and parsing happen outside it.
private final class ScanState: @unchecked Sendable {
    private let lock = NSCondition()
    private var queue: [(Int32, String)] = []
    private var active = 0
    private var names: [String] = []
    private var parents: [Int32] = []
    private var direct: [Int64] = []
    private var directCounts: [Int64] = []
    private var smallBytes: [Int64] = []
    private var smallCounts: [Int32] = []
    private var unreadable: [Bool] = []
    private var files: [IndexedFile] = []
    private var seenLinks: Set<UInt64> = []
    private var totalFiles: Int64 = 0
    private var totalBytes: Int64 = 0
    private var lastReport = Date.distantPast
    let bigFileMinimum: Int64

    init(bigFileMinimum: Int64) {
        self.bigFileMinimum = bigFileMinimum
    }

    func addRoot(_ path: String) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let index = appendFolder(name: path, parent: -1)
        queue.append((index, path))
        return index
    }

    private func appendFolder(name: String, parent: Int32) -> Int32 {
        names.append(name)
        parents.append(parent)
        direct.append(0)
        directCounts.append(0)
        smallBytes.append(0)
        smallCounts.append(0)
        unreadable.append(false)
        return Int32(names.count - 1)
    }

    func work(isCancelled: @Sendable () -> Bool, progress: (@Sendable (FastScanner.Progress) -> Void)?) {
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            lock.lock()
            while queue.isEmpty, active > 0 { lock.wait() }
            if queue.isEmpty || isCancelled() {
                queue.removeAll()
                lock.broadcast()
                lock.unlock()
                return
            }
            let (folder, path) = queue.removeLast()
            active += 1
            lock.unlock()

            let listing = Self.list(path, buffer: buffer, capacity: capacity, bigFileMinimum: bigFileMinimum)

            lock.lock()
            var report: FastScanner.Progress?
            if let listing {
                var bytes = listing.smallBytes
                var count = Int64(listing.smallCount)
                smallBytes[Int(folder)] += listing.smallBytes
                smallCounts[Int(folder)] += Int32(listing.smallCount)
                for entry in listing.linked where seenLinks.insert(entry.fileID).inserted {
                    bytes += entry.allocated
                    count += 1
                    if entry.name.isEmpty {
                        smallBytes[Int(folder)] += entry.allocated
                        smallCounts[Int(folder)] += 1
                    } else {
                        files.append(IndexedFile(folder: folder, name: entry.name, allocated: entry.allocated,
                                                 length: entry.length, modified: entry.modified, accessed: entry.accessed))
                    }
                }
                for entry in listing.big {
                    bytes += entry.allocated
                    count += 1
                    files.append(IndexedFile(folder: folder, name: entry.name, allocated: entry.allocated,
                                             length: entry.length, modified: entry.modified, accessed: entry.accessed))
                }
                direct[Int(folder)] += bytes
                directCounts[Int(folder)] += count
                totalBytes += bytes
                totalFiles += count
                for name in listing.folders {
                    let child = appendFolder(name: name, parent: folder)
                    queue.append((child, path == "/" ? "/" + name : path + "/" + name))
                }
            } else {
                unreadable[Int(folder)] = true
            }
            active -= 1
            if progress != nil, Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                report = .init(files: totalFiles, bytes: totalBytes, folders: names.count)
            }
            lock.broadcast()
            lock.unlock()
            if let report { progress?(report) }
        }
    }

    struct Entry {
        let name: String
        let allocated: Int64
        let length: Int64
        let modified: Double
        let accessed: Double
        let fileID: UInt64
        let links: UInt32
    }

    struct Listing {
        /// files under the big-file minimum with one link, already summed.
        var smallBytes: Int64 = 0
        var smallCount = 0
        /// files at or over the minimum, named.
        var big: [Entry] = []
        /// hard-linked files, counted once per scan; named only when big.
        var linked: [Entry] = []
        var folders: [String] = []
    }

    /// one folder's entries via getattrlistbulk. nil when the folder cannot be opened.
    static func list(_ path: String, buffer: UnsafeMutableRawPointer, capacity: Int, bigFileMinimum: Int64) -> Listing? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE)
                | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_ACCTIME) | UInt32(ATTR_CMN_FILEID)
        )
        request.dirattr = attrgroup_t(UInt32(ATTR_DIR_MOUNTSTATUS))
        request.fileattr = attrgroup_t(UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH))

        var listing = Listing()
        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var namePointer: UnsafePointer<CChar>?
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let offset = field.loadUnaligned(as: Int32.self)
                    namePointer = (field + Int(offset)).assumingMemoryBound(to: CChar.self)
                    field += MemoryLayout<attrreference_t>.size
                }
                func name() -> String { namePointer.map { String(cString: $0) } ?? "" }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified = 0.0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = Double(field.loadUnaligned(as: Int.self))
                    field += MemoryLayout<timespec>.size
                }
                var accessed = 0.0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
                    accessed = Double(field.loadUnaligned(as: Int.self))
                    field += MemoryLayout<timespec>.size
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var mountPoint = false
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    mountPoint = field.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
                    field += 4
                }
                var links: UInt32 = 1
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                var dataLength: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    dataLength = field.loadUnaligned(as: Int64.self)
                    field += 8
                }

                switch type {
                case 2: // VDIR
                    if !mountPoint { listing.folders.append(name()) }
                case 1: // VREG
                    let big = allocated >= bigFileMinimum || dataLength >= bigFileMinimum
                    if links > 1 {
                        listing.linked.append(Entry(name: big ? name() : "", allocated: allocated, length: dataLength,
                                                    modified: modified, accessed: accessed, fileID: fileID, links: links))
                    } else if big {
                        listing.big.append(Entry(name: name(), allocated: allocated, length: dataLength,
                                                 modified: modified, accessed: accessed, fileID: fileID, links: links))
                    } else {
                        listing.smallBytes += allocated
                        listing.smallCount += 1
                    }
                default:
                    break
                }
                entry += length
            }
        }
        return listing
    }

    func finish(roots: [Int32], rootPaths: [String], started: Date) -> DiskIndex {
        lock.lock()
        defer { lock.unlock() }
        var totals = direct
        var counts = directCounts
        // children are always created after their parent, so one backward pass adds them up.
        for index in stride(from: parents.count - 1, through: 0, by: -1) {
            let parent = Int(parents[index])
            guard parent >= 0 else { continue }
            totals[parent] += totals[index]
            counts[parent] += counts[index]
        }
        return DiskIndex(
            roots: roots, rootPaths: rootPaths, names: names, parents: parents, totals: totals, fileCounts: counts,
            smallBytes: smallBytes, smallCounts: smallCounts, unreadable: unreadable, files: files,
            bigFileMinimum: bigFileMinimum, scannedAt: Date(), duration: Date().timeIntervalSince(started)
        )
    }
}
