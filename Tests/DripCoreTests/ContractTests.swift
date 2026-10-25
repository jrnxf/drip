import DripCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// scripts/agent-contract/contract.json, which the live agent check holds each agent's payloads up
/// against, names the same events drip setup hooks.
struct ContractTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/agent-contract/contract.json")

    @Test(arguments: AgentHook.Agent.allCases)
    func contractNamesTheEventsSetupHooks(agent: AgentHook.Agent) throws {
        let text = try String(contentsOf: Self.file, encoding: .utf8)
        let contract = try #require(try JSONValue(parsing: text)["agents"]?[agent.rawValue])
        let events = Set(contract["events"]?.members?.map(\.key) ?? [])
        let hooked = Set(try JSONValue(parsing: AgentSetup.snippet(for: agent))["hooks"]?.members?.map(\.key) ?? [])
        #expect(events == hooked)
        // The session's own events are among them.
        let flow = contract["flow"]?.members?.filter { $0.key != "permissionType" }.compactMap(\.value.string) ?? []
        #expect(flow.count == 4)
        #expect(Set(flow).isSubset(of: hooked))
    }
}
