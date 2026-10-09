import Darwin
import Foundation

/// Moves the existing vault directory without rewriting ciphertext or changing its keys.
public enum AppStorageLocation {
    public static func prepare(in applicationSupport: URL) throws -> URL {
        guard applicationSupport.isFileURL else { throw StorageError.unsafeStorageLocation }
        let current = applicationSupport.appendingPathComponent("Spillcheck", isDirectory: true)
        let previous = applicationSupport.appendingPathComponent("Leakret", isDirectory: true)
        let currentExists = try ownedDirectoryExists(current)
        let previousExists = try ownedDirectoryExists(previous)
        // Two stores need explicit reconciliation. Never hide one by opening the other.
        guard !(currentExists && previousExists) else { throw StorageError.unsafeStorageLocation }
        if previousExists {
            do { try FileManager.default.moveItem(at: previous, to: current) }
            catch { throw StorageError.unsafeStorageLocation }
        }
        return current
    }

    private static func ownedDirectoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw StorageError.unsafeStorageLocation
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
            throw StorageError.unsafeStorageLocation
        }
        return true
    }
}
