import Foundation
import Testing
import os

@testable import Kikimi

/// Layer 1 coverage for `FileWatcher` (`Kikimi/Config/FileWatcher.swift`) itself, independent of its
/// two production consumers (`YAMLStore`, `PromptStore`) which each exercise it only indirectly through
/// their own reload semantics. Covers the class's three watch-trigger paths directly: an in-place
/// write, an atomic write (delete+rename, e.g. what most editors and `atomically: true` writes do), and
/// the "file doesn't exist yet" retry loop picking up a file created after the watcher starts.
@Suite("FileWatcher")
struct FileWatcherTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - In-place write

    @Test("onChange fires when the watched file is overwritten in place (truncate+write, no rename)")
    func firesOnInPlaceWrite() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watched.txt")
        try "initial".write(to: url, atomically: false, encoding: .utf8)

        let changeCount = OSAllocatedUnfairLock(initialState: 0)
        let watcher = FileWatcher(url: url) {
            changeCount.withLock { $0 += 1 }
        }

        try Data("updated".utf8).write(to: url, options: [])

        try await waitUntil("the in-place write to be observed") {
            changeCount.withLock { $0 } > 0
        }
        withExtendedLifetime(watcher) {}
    }

    // MARK: - Atomic write (delete+rename)

    @Test("onChange fires after an atomic write (write-to-temp + rename over the watched path)")
    func firesOnAtomicWrite() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watched.txt")
        try "initial".write(to: url, atomically: false, encoding: .utf8)

        let changeCount = OSAllocatedUnfairLock(initialState: 0)
        let watcher = FileWatcher(url: url) {
            changeCount.withLock { $0 += 1 }
        }

        // `atomically: true` is exactly the delete+rename pattern FileWatcher's doc comment calls out:
        // it writes to a temp file, then renames it over `url`, invalidating the original fd.
        try "replaced".write(to: url, atomically: true, encoding: .utf8)

        try await waitUntil(timeout: .seconds(10), "the atomic-write replacement to be observed") {
            changeCount.withLock { $0 } > 0
        }
        withExtendedLifetime(watcher) {}
    }

    @Test("the watcher keeps working after an atomic-write replacement: a second edit still fires onChange")
    func continuesWatchingAfterAtomicReplacement() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watched.txt")
        try "initial".write(to: url, atomically: false, encoding: .utf8)

        let changeCount = OSAllocatedUnfairLock(initialState: 0)
        let watcher = FileWatcher(url: url) {
            changeCount.withLock { $0 += 1 }
        }

        try "first replacement".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil(timeout: .seconds(10), "the first atomic-write replacement to be observed") {
            changeCount.withLock { $0 } > 0
        }

        try "second replacement".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil(timeout: .seconds(10), "the second atomic-write replacement to also be observed") {
            changeCount.withLock { $0 } > 1
        }
        withExtendedLifetime(watcher) {}
    }

    // MARK: - File created after the watcher starts

    @Test("a watcher started before the file exists notices once the file is created (retryStart loop)")
    func firesOnceTheWatchedFileIsCreatedLater() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("not-yet-created.txt")

        let changeCount = OSAllocatedUnfairLock(initialState: 0)
        let watcher = FileWatcher(url: url) {
            changeCount.withLock { $0 += 1 }
        }

        // retryStart() polls every 0.5s (`Kikimi/Config/FileWatcher.swift`), so give it room to notice.
        try "now it exists".write(to: url, atomically: true, encoding: .utf8)

        try await waitUntil(timeout: .seconds(10), "the newly-created file to be observed") {
            changeCount.withLock { $0 } > 0
        }
        withExtendedLifetime(watcher) {}
    }

    // MARK: - deinit

    @Test("deallocating the watcher stops delivering onChange for subsequent writes, without crashing")
    func deallocatingStopsFurtherNotifications() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watched.txt")
        try "initial".write(to: url, atomically: false, encoding: .utf8)

        let changeCount = OSAllocatedUnfairLock(initialState: 0)
        var watcher: FileWatcher? = FileWatcher(url: url) {
            changeCount.withLock { $0 += 1 }
        }
        withExtendedLifetime(watcher) {}
        watcher = nil

        try Data("after dealloc".utf8).write(to: url, options: [])

        // Negative claim (per `waitUntil`'s doc comment): there is no state to poll for "onChange was
        // never called again", so a short fixed sleep is the correct tool here, not a poll.
        try await Task.sleep(for: .milliseconds(300))
        #expect(changeCount.withLock { $0 } == 0)
    }
}
