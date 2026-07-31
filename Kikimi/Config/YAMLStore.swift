import Foundation
import os
import Yams

/// Generic YAML persistence base class used by config/state stores (kikimi.md 12 章, `docs/design/06-ui-panels.md`
/// section 4/5.1). Ported nearly verbatim from Chirami's `Chirami/Config/YAMLStore.swift`
/// (`docs/references/chirami-map.md` 4 章), including the `watchForChanges` option and its supporting
/// `FileWatcher` helper (ported from `Chirami/Services/FileWatcher.swift`; cut out to
/// `Kikimi/Config/FileWatcher.swift` as `internal` so `PromptStore` can reuse it,
/// `docs/design/42-prompt-overrides.md` §5.1/§11). `AppState` (section 5.1) subclasses this; per the
/// Chirami-diff table in section 2, `AppState.shared` always constructs its store with
/// `watchForChanges: false` even though the parameter itself is preserved for parity with Chirami and
/// for any future store that does need external-edit reload.
///
/// Not `final` so it can be subclassed the same way Chirami's `AppConfig`/`AppState` subclass it.
class YAMLStore<T: Codable>: ObservableObject {
    private let fileURL: URL
    private let label: String
    private let logger: Logger
    @Published private(set) var data: T

    private var fileWatcher: FileWatcher?
    private var reloadWorkItem: DispatchWorkItem?
    private var isWriting = false

    /// True when the on-disk file exists but could not be decoded.
    /// While set, `save()` is refused so the (possibly user-edited) file
    /// is never silently overwritten with in-memory defaults.
    private(set) var loadFailed = false

    /// - Parameters:
    ///   - directory: Directory the YAML file lives in. Created (with intermediate directories) if missing.
    ///   - fileName: File name within `directory`, e.g. `"state.yaml"`.
    ///   - label: Human-readable label used in log messages (e.g. `"State"`).
    ///   - defaultValue: Value used when the file does not exist yet, and kept in memory while `loadFailed` is set.
    ///   - watchForChanges: When true, external edits to the file are picked up automatically (debounced reload).
    ///     Kept for parity with Chirami; `AppState.shared` always passes `false` (`docs/design/06-ui-panels.md`
    ///     section 2).
    init(directory: URL, fileName: String, label: String, defaultValue: T, watchForChanges: Bool = false) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.label = label
        self.logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "YAMLStore")
        self.data = defaultValue

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()

        if watchForChanges {
            fileWatcher = FileWatcher(url: fileURL) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, !self.isWriting else { return }
                    self.reloadWorkItem?.cancel()
                    let workItem = DispatchWorkItem { [weak self] in
                        self?.load()
                    }
                    self.reloadWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
                }
            }
        }
    }

    /// Reloads `data` from disk. A missing file is treated as a fresh start (not a failure) and leaves
    /// `data` at whatever it currently holds. A file that exists but cannot be read/decoded sets
    /// `loadFailed = true` and leaves `data` untouched, so in-memory state is never silently reset to defaults.
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Missing file is a fresh start, not a failure
            loadFailed = false
            return
        }
        guard let raw = try? Data(contentsOf: fileURL),
              let yaml = String(data: raw, encoding: .utf8) else {
            loadFailed = true
            logger.error("\(self.label, privacy: .public) load error: file could not be read as UTF-8 text: \(self.fileURL.path, privacy: .public)")
            return
        }
        do {
            data = try YAMLDecoder().decode(T.self, from: yaml)
            loadFailed = false
        } catch {
            loadFailed = true
            logger.error("\(self.label, privacy: .public) load error: \(error, privacy: .public)")
        }
    }

    /// Encodes `data` and writes it atomically to disk. Refused (no-op besides logging) if the last
    /// `load()` failed, so a corrupt on-disk file is never overwritten with in-memory defaults.
    func save() {
        guard !loadFailed else {
            logger.error("\(self.label, privacy: .public) save refused: last load failed, refusing to overwrite \(self.fileURL.path, privacy: .public) with in-memory defaults")
            return
        }
        isWriting = true
        do {
            let yaml = try YAMLEncoder().encode(data)
            try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("\(self.label, privacy: .public) save error: \(error, privacy: .public)")
            isWriting = false
            return
        }
        // Reset after a delay long enough to absorb the FileWatcher event from our own save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isWriting = false
        }
    }

    /// Mutates `data` in place and persists the result via `save()`.
    func update(_ block: (inout T) -> Void) {
        block(&data)
        save()
    }
}
