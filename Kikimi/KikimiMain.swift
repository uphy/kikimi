import Foundation

// MARK: - KikimiMain

/// The process's real entry point (`docs/design/42-prompt-overrides.md` §6.1). `@main` lives here,
/// not on `KikimiApp` (`Kikimi/KikimiApp.swift`) any more, so a headless prompt-CLI invocation
/// (`--eject-prompt` / `--validate-prompts` / `--render-prompt` / `--list-prompts`) can run and exit
/// *before* `KikimiApp.main()` would otherwise stand up `AppKit`/`MenuBarExtra`/TCC prompts.
///
/// `PromptCLI.runIfRequested(arguments:)` only claims a run when it recognizes one of the four
/// prompt-subcommand flags in `arguments`; any other invocation (a normal double-click launch, or a
/// launch carrying only macOS-injected flags such as `-NSDocumentRevisionsDebugMode YES`) returns
/// `nil` and falls straight through to the ordinary GUI launch below, unchanged from before this
/// split (§6.1: "自分の知らないフラグには反応せず nil を返す -> GUI 起動にフォールスルー").
@main
enum KikimiMain {
    static func main() {
        if let code = PromptCLI.runIfRequested(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        KikimiApp.main()
    }
}
