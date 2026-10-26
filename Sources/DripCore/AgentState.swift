#if !os(WASI)
import Foundation

/// What drip keeps about agents' sessions between hooks, in `<state>/agents`: which card a session
/// waits on, so the hook that shows the agent moved on can take it away, and where each session
/// runs, so two sessions in folders of the same name read apart.
///
/// Each session has its own small files, named for a fingerprint of its id, and an entry older than
/// `Defaults.waitLimit` counts as gone, as its card would be.
public struct AgentState {
    public var directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// The agents' state in the state directory.
    public init(environment: [String: String]) {
        self.init(directory: (StateDirectory.path(environment: environment) as NSString).appendingPathComponent("agents"))
    }

    /// A card that waits for you, as its hook showed it.
    public struct Waiting: Codable, Equatable {
        public var id: String
        /// The tool call it waits on; nil when the hook named none.
        public var tool: String?
        /// When it was shown, in seconds since 1970.
        public var time: Double
    }

    /// Where a session runs, as its last hook said.
    struct Session: Codable, Equatable {
        var id: String
        var directory: String
        var time: Double
    }

    private func path(_ prefix: String, _ id: String) -> String {
        (directory as NSString).appendingPathComponent("\(prefix)-\(AgentHook.fingerprint(id)).json")
    }

    private func read<Value: Decodable>(_ type: Value.Type, at path: String) -> Value? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func write<Value: Encodable>(_ value: Value, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try StateFiles.write(String(decoding: try encoder.encode(value), as: UTF8.self) + "\n", toPath: path)
    }

    // MARK: Waiting cards

    /// Notes that the session `id` shows a card that waits for you on `tool`.
    public func noteWaiting(id: String, tool: String?, now: Date = Date()) throws {
        try write(Waiting(id: id, tool: tool, time: now.timeIntervalSince1970), to: path("waiting", id))
    }

    /// Notes that the session's card no longer waits: a card that counts down took its place.
    public func noteDone(id: String) {
        unlink(path("waiting", id))
    }

    /// The card the session `id` waits on; nil when none does, or it would have gone by `now`.
    public func waiting(id: String, now: Date = Date()) -> Waiting? {
        guard let waiting = read(Waiting.self, at: path("waiting", id)), waiting.id == id,
              now.timeIntervalSince1970 - waiting.time < Defaults.waitLimit
        else { return nil }
        return waiting
    }

    /// Whether `clear` takes the session's waiting card away: one waits, and it waits on the tool call
    /// `clear` names, or `clear` names none. Forgets the card when it does.
    public func takeWaiting(_ clear: AgentHook.Clear, now: Date = Date()) -> Bool {
        guard let waiting = waiting(id: clear.id, now: now) else { return false }
        if let tool = clear.tool, waiting.tool != tool, clear.alsoTool.map({ waiting.tool != $0 }) ?? true {
            return false
        }
        noteDone(id: clear.id)
        return true
    }

    // MARK: Sessions

    /// Notes that the session `id` runs in `directory`.
    public func noteSession(id: String, directory: String, now: Date = Date()) throws {
        try write(Session(id: id, directory: directory, time: now.timeIntervalSince1970), to: path("session", id))
    }

    /// The folders other sessions than `id` ran in lately, and forgets those gone quiet.
    public func otherDirectories(than id: String, now: Date = Date()) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("session-") && $0.hasSuffix(".json") }.compactMap { name in
            let file = (directory as NSString).appendingPathComponent(name)
            guard let session = read(Session.self, at: file) else { return nil }
            if now.timeIntervalSince1970 - session.time >= Defaults.waitLimit {
                unlink(file)
                return nil
            }
            return session.id == id ? nil : session.directory
        }
    }

    /// The project as a card's title names it: the folder's name, with as many of the folders above
    /// it as it takes to tell it from `others` of the same name, as `1/drip` and `2/drip`.
    public static func project(_ directory: String, among others: [String]) -> String {
        let parts = directory.split(separator: "/").map(String.init)
        guard let name = parts.last else { return directory }
        let rivals = others.map { $0.split(separator: "/").map(String.init) }
            .filter { $0.last == name && $0 != parts }
        guard !rivals.isEmpty else { return name }
        for count in 2...max(parts.count, 2) {
            let suffix = Array(parts.suffix(count))
            if !rivals.contains(where: { Array($0.suffix(count)) == suffix }) || count >= parts.count {
                return suffix.joined(separator: "/")
            }
        }
        return name
    }
}

/// Requests from `drip dismiss`, and from agents' hooks, to take cards away without bringing
/// anything forward, kept in `<state>/dismiss` for the drips showing cards to act on.
///
/// A request takes away the cards with its id, or every card, that were queued before it: a card
/// that comes later shows as usual. Each id has one file, holding the time of its newest request;
/// requests older than `Defaults.waitLimit` are forgotten, as any card they could take is gone.
public struct DismissRequests {
    public var directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public init(environment: [String: String]) {
        self.init(directory: (StateDirectory.path(environment: environment) as NSString).appendingPathComponent("dismiss"))
    }

    struct Request: Codable, Equatable {
        /// Nil for every card.
        var id: String?
        var time: Double
    }

    private func path(for id: String?) -> String {
        (directory as NSString).appendingPathComponent(id.map { "id-\(AgentHook.fingerprint($0)).json" } ?? "all.json")
    }

    /// Asks for the cards with `id`, or every card when nil, queued before `now` to go.
    public func request(id: String?, now: Date = Date()) throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Request(id: id, time: now.timeIntervalSince1970))
        try StateFiles.write(String(decoding: data, as: UTF8.self) + "\n", toPath: path(for: id))
    }

    /// The live requests, read at once, so the drips showing cards can ask about each of them.
    public func load(now: Date = Date()) -> Snapshot {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var snapshot = Snapshot()
        for name in names where name.hasSuffix(".json") {
            let file = (directory as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: file),
                  let request = try? JSONDecoder().decode(Request.self, from: data)
            else { continue }
            if now.timeIntervalSince1970 - request.time >= Defaults.waitLimit {
                unlink(file)
                continue
            }
            if let id = request.id {
                snapshot.byID[id] = max(snapshot.byID[id] ?? 0, request.time)
            } else {
                snapshot.all = max(snapshot.all ?? 0, request.time)
            }
        }
        return snapshot
    }

    /// The requests as they were read.
    public struct Snapshot: Equatable {
        var byID: [String: Double] = [:]
        var all: Double?

        public init() {}

        /// Whether a card with `id` that came at `time`, in seconds since 1970, is to go.
        public func dismisses(id: String?, since time: Double) -> Bool {
            if let all, all > time { return true }
            guard let id, let requested = byID[id] else { return false }
            return requested > time
        }

        public var isEmpty: Bool { byID.isEmpty && all == nil }
    }
}
#endif
