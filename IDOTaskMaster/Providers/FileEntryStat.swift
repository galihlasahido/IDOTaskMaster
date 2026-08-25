import Darwin
import Foundation

/// One directory entry's `lstat(2)` result — shared by every provider that
/// needs to know a file's *actual* on-disk usage rather than its apparent
/// size. Reads the raw struct instead of going through `FileManager
/// .attributesOfItem`, which boxes every field into an `NSDictionary`/
/// `NSNumber` (a real cost across large trees) and, more importantly, only
/// exposes `st_size` — a file's *apparent* size, not how much disk it
/// actually occupies. Those two diverge hugely for sparse files: a VM/
/// container disk image can report a multi-hundred-gigabyte apparent size
/// while occupying a fraction of that physically, which is exactly how a
/// naive `st_size`-summing scan can report more bytes than the volume
/// itself holds — see `DiskSpaceScanner`'s own history with this. `st_blocks`
/// is always in 512-byte units regardless of the filesystem's own block
/// size — a POSIX convention, not an APFS-specific one — matching what `du`
/// itself reports.
struct FileEntryStat {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let realSizeBytes: UInt64
    let linkCount: Int
    let inode: UInt64
    let device: UInt64
}

func statEntry(atPath path: String) -> FileEntryStat? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    let fileType = info.st_mode & S_IFMT
    return FileEntryStat(
        isDirectory: fileType == S_IFDIR,
        isSymbolicLink: fileType == S_IFLNK,
        realSizeBytes: UInt64(info.st_blocks) * 512,
        linkCount: Int(info.st_nlink),
        inode: UInt64(info.st_ino),
        device: UInt64(info.st_dev)
    )
}

/// Sums `path`'s whole subtree's real on-disk usage (`st_blocks`-based, see
/// `FileEntryStat`'s own doc comment) in one single-threaded recursive walk
/// — for callers sizing a bounded number of individually-known directories
/// (e.g. `CleanupProvider`'s per-app cache folders) rather than an
/// open-ended arbitrary folder, where `DiskSpaceScanner`'s own cancellable,
/// parallelized, hard-link-aware scan is the right tool instead. Symbolic
/// links are never followed, matching `du`'s own default and avoiding
/// symlink cycles.
func recursiveRealSizeBytes(atPath path: String, fileManager: FileManager) -> UInt64 {
    guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return 0 }
    var total: UInt64 = 0
    for name in entries {
        let entryPath = "\(path)/\(name)"
        guard let entry = statEntry(atPath: entryPath) else { continue }
        if entry.isSymbolicLink { continue }
        if entry.isDirectory {
            total += recursiveRealSizeBytes(atPath: entryPath, fileManager: fileManager)
        } else {
            total += entry.realSizeBytes
        }
    }
    return total
}
