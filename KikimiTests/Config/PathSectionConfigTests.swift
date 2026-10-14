import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 coverage for the small path/toggle sections of `config.yaml`: `defaults:`, `profiles:`,
/// `export:`. Each must tolerate an absent or partial section by filling from `.default`.
@Suite("DefaultsConfig / ProfilesConfig / ExportConfig")
struct PathSectionConfigTests {
    private func decodeConfig(_ yaml: String) throws -> KikimiConfigData {
        try YAMLDecoder().decode(KikimiConfigData.self, from: yaml)
    }

    @Test("absent defaults:/profiles:/export: sections use their documented defaults")
    func absentSectionsUseDefaults() throws {
        let config = try decodeConfig("diarization:\n  enabled: true\n")

        #expect(config.defaults == .default)
        #expect(config.defaults.contextFile == "~/.config/kikimi/context/common.md")
        #expect(config.defaults.summaryTemplateFile == "~/.config/kikimi/templates/summary.md")
        #expect(config.profiles == .default)
        #expect(config.profiles.dir == "~/.config/kikimi/profiles/")
        #expect(config.export == .default)
    }

    @Test("a partial defaults: section fills only the missing path")
    func partialDefaultsSection() throws {
        let config = try decodeConfig("""
        defaults:
          context_file: ~/notes/ctx.md
        """)

        #expect(config.defaults.contextFile == "~/notes/ctx.md")
        #expect(config.defaults.summaryTemplateFile == DefaultsConfig.default.summaryTemplateFile)
    }

    @Test("defaults: decodes both snake_case keys verbatim without tilde expansion")
    func fullDefaultsSection() throws {
        let config = try decodeConfig("""
        defaults:
          context_file: ~/a.md
          summary_template_file: /abs/b.md
        """)

        #expect(config.defaults == DefaultsConfig(contextFile: "~/a.md", summaryTemplateFile: "/abs/b.md"))
    }

    @Test("profiles.dir is read verbatim and an empty profiles: section falls back to the default")
    func profilesDir() throws {
        let custom = try decodeConfig("profiles:\n  dir: ~/meetings/profiles/\n")
        #expect(custom.profiles.dir == "~/meetings/profiles/")

        let empty = try decodeConfig("profiles: {}\n")
        #expect(empty.profiles == .default)
    }

    @Test("a partial export: section fills the missing field from the defaults")
    func partialExportSection() throws {
        let onlyDisabled = try decodeConfig("export:\n  enabled: false\n")
        #expect(onlyDisabled.export.enabled == false)
        #expect(onlyDisabled.export.targetDir == ExportConfig.default.targetDir)

        let onlyDir = try decodeConfig("export:\n  target_dir: /tmp/out/\n")
        #expect(onlyDir.export.enabled == true)
        #expect(onlyDir.export.targetDir == "/tmp/out/")
    }

    @Test("encoding uses snake_case keys and round-trips")
    func snakeCaseRoundTrip() throws {
        let original = KikimiConfigData(
            export: ExportConfig(enabled: false, targetDir: "~/e/"),
            defaults: DefaultsConfig(contextFile: "~/c.md", summaryTemplateFile: "~/s.md"),
            profiles: ProfilesConfig(dir: "~/p/")
        )
        let yaml = try YAMLEncoder().encode(original)

        #expect(yaml.contains("context_file:"))
        #expect(yaml.contains("summary_template_file:"))
        #expect(yaml.contains("target_dir:"))

        let decoded = try decodeConfig(yaml)
        #expect(decoded.defaults == original.defaults)
        #expect(decoded.profiles == original.profiles)
        #expect(decoded.export == original.export)
    }
}
