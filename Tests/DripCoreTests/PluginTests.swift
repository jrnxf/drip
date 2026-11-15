import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

#if !os(WASI) // Reads the repo folder, which the browser's sandbox has not.
/// The Claude Code plugins in the repo's marketplace are the recipes' Claude Code snippets, so a
/// plugin install and a paste give the same hooks.
struct PluginTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The plugins: one per notify recipe, and `drip-tell-me`, a skill with no hooks. Each name starts
    /// with `drip-`, so it says whose it is in a list of installed plugins.
    static let names = Recipes.names.map(plugin) + ["drip-tell-me"]

    /// The plugin of a recipe.
    static func plugin(_ recipe: String) -> String { "drip-\(recipe)" }

    static func json(_ path: String) throws -> JSONValue {
        try JSONValue(parsing: String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    /// The command a plugin runs for a recipe's command: silent on a machine without drip.
    static func guarded(_ command: String) -> String {
        "command -v drip >/dev/null && \(command) || true"
    }

    /// A recipe's hooks with every handler's command guarded.
    static func guarding(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(members):
            return .object(members.map { member in
                if member.key == "command", let command = member.value.string { return JSONMember("command", .string(guarded(command))) }
                return JSONMember(member.key, guarding(member.value))
            })
        case let .array(elements):
            return .array(elements.map(guarding))
        default:
            return value
        }
    }

    @Test func theMarketplaceListsEveryPluginFromItsFolder() throws {
        let marketplace = try Self.json(".claude-plugin/marketplace.json")
        #expect(marketplace["name"] == .string("drip"))
        #expect(marketplace["owner"]?["name"] == .string("jrnxf"))
        let entries = marketplace["plugins"]?.elements ?? []
        #expect(entries.compactMap { $0["name"]?.string } == Self.names)
        for entry in entries {
            let name = entry["name"]?.string ?? ""
            #expect(entry["source"] == .string("./plugins/\(name)"), "\(name)")
        }
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.root.appendingPathComponent("plugins").path)
            .filter { !$0.hasPrefix(".") }
        #expect(Set(folders) == Set(Self.names))
    }

    @Test(arguments: names)
    func everyPluginNamesItsAuthorAndLicense(name: String) throws {
        let manifest = try Self.json("plugins/\(name)/.claude-plugin/plugin.json")
        #expect(manifest["name"] == .string(name))
        let description = manifest["description"]?.string ?? ""
        #expect(description.isEmpty == false)
        #expect(manifest["author"]?["name"] == .string("jrnxf"))
        #expect(manifest["license"] == .string("MIT"))
        #expect(manifest["repository"] == .string("https://github.com/jrnxf/drip"))
        #expect(manifest["homepage"]?.string?.hasPrefix("https://github.com/jrnxf/drip/") == true)
        // No version: Claude Code takes the commit as the version, so an update brings the hooks on
        // main. A version string would pin users to it until someone changed it.
        #expect(manifest["version"] == nil)
        let entry = try Self.json(".claude-plugin/marketplace.json")["plugins"]?.elements?.first { $0["name"] == .string(name) }
        #expect(entry?["version"] == nil)
    }

    /// The plugin's hooks are the recipe's Claude Code snippet, event for event and group for group,
    /// with only the guard around each command.
    @Test(arguments: Recipes.names)
    func everyPluginHasTheHooksOfItsRecipe(name: String) throws {
        let hooks = try #require(try Self.json("plugins/\(Self.plugin(name))/hooks/hooks.json")["hooks"])
        let recipe = JSONValue.object(try Recipes.events(name, .claude))
        #expect(hooks == Self.guarding(recipe), "plugins/\(Self.plugin(name))/hooks/hooks.json differs from the recipe's Claude Code snippet")
    }

    @Test func theSkillPluginHasNoHooks() {
        let hooks = Self.root.appendingPathComponent("plugins/drip-tell-me/hooks").path
        #expect(!FileManager.default.fileExists(atPath: hooks))
    }
}
#endif
