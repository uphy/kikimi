import CoreTransferable
import UniformTypeIdentifiers

// MARK: - GlossaryEntryTransfer

/// Drag payload for moving a 用語集 entry (`docs/design/28-glossary.md` §4.3): dragging the entry row's
/// handle onto the category sidebar (to re-categorize) or onto a reorder separator in the entry list (to
/// reorder within the current bucket).
///
/// Carries an `index` into `AppConfig.shared.data.glossary` *and* a revalidation token (`term`, the
/// entry's term at drag-start time), because the array can change out from under an in-flight drag --
/// `AppConfig`'s file watcher can reload `config.yaml` mid-drag, or the user can edit/delete the row
/// being dragged before releasing it. Every drop handler must re-check that `index` is still in bounds
/// *and* that `glossary[index].term == term` before mutating; if either check fails, the drop is
/// silently ignored rather than mutating whatever entry now happens to sit at `index`. This mirrors the
/// bounds-checking already required of `GlossaryEntryRow`'s bindings (see that file's doc comment).
///
/// Uses a custom `UTType` rather than a generic one (`.data`/`.json`) so a drop destination only ever
/// accepts this app's own glossary rows -- a JSON file dragged in from Finder can't reach a handler.
///
/// The identifier is declared in `Info.plist`'s `UTExportedTypeDeclarations` (see `project.yml`, which
/// generates it). `UTType(exportedAs:)` expects that declaration to exist: without it the runtime logs
/// "type ... was expected to be declared and exported" and delivery of the dragged item is not
/// guaranteed. The payload never leaves this process, so the declaration carries no tag specification
/// (no file extension, no MIME type) -- it exists purely to make the identifier legitimate.
struct GlossaryEntryTransfer: Codable, Transferable {
    /// Index into `AppConfig.shared.data.glossary` at the moment the drag started.
    let index: Int
    /// The entry's `term` at drag-start time -- the revalidation token described above.
    let term: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .glossaryEntry)
    }
}

extension UTType {
    /// Synthesized at runtime (no `Info.plist` declaration needed) -- see `GlossaryEntryTransfer`'s doc
    /// comment for why that is sufficient here.
    static var glossaryEntry: UTType {
        UTType(exportedAs: "io.github.uphy.Kikimi.glossary-entry", conformingTo: .data)
    }
}
