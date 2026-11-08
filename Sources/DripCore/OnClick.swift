#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// A command a click on the card runs, as `--on-click` gives it, with what the click passes it.
///
/// Only the Mac side sets the command: `--on-click` on `drip`, `drip run`, `drip hook` or
/// `drip follow`. An event from another machine never does: it gives only its machine's name and
/// the variables `DRIP_FORWARD_ENV` names there.
public struct OnClick: Equatable, Sendable, Codable {
    /// The shell command, as `/bin/sh -c` runs it.
    public var command: String
    /// The machine the card's agent runs on, for a card `drip follow` showed; nil for this Mac.
    public var machine: String?
    /// The variables `DRIP_FORWARD_ENV` named where the card came from, empty ones left out.
    public var environment: [String: String]

    public init(command: String, machine: String? = nil, environment: [String: String] = [:]) {
        self.command = command
        self.machine = machine
        self.environment = environment
    }

    /// How long the command may run before drip stops it, with what it started.
    public static let timeout = 10.0

    /// The most of the title the payload holds, so it always fits the pipe the command reads.
    public static let titleLimit = 500

    /// The payload's version: a new one comes only with a change that breaks a reader of the last.
    public static let version = 1

    /// What the command reads on stdin: one line of JSON, with `v`, the version, `kind`, `title`,
    /// and `id`, `app` (the bundle identifier the click brings forward), `machine` and `env` when
    /// the card has them. Never the rest of the card.
    public func payload(for card: Card) -> String {
        let payload = Payload(
            v: Self.version, id: card.id, kind: card.kind, title: String(card.title.prefix(Self.titleLimit)), app: card.activate,
            machine: machine, env: environment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data("{\"v\":\(Self.version)}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private struct Payload: Encodable {
        var v: Int
        var id: String?
        var kind: String
        var title: String
        var app: String?
        var machine: String?
        var env: [String: String]
    }
}

/// `DRIP_FORWARD_ENV`: the names, separated by spaces, of variables a click's command gets in its
/// payload, read where the card comes from: the shell that ran drip on this Mac, or the agent's
/// session on another machine, which `drip-remote-hook` reads them in.
public enum ForwardedEnvironment {
    /// The variable that names them.
    public static let variable = "DRIP_FORWARD_ENV"
    /// The most variables a card passes on: the rest are left out.
    public static let countLimit = 16
    /// The longest name passed on.
    public static let nameLimit = 64
    /// The longest value passed on.
    public static let valueLimit = 256

    /// Whether `name` can be a variable's name: a letter or `_`, then letters, digits and `_`.
    public static func isName(_ name: String) -> Bool {
        let letter = { (scalar: Unicode.Scalar) in
            scalar == "_" || ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
        }
        guard let first = name.unicodeScalars.first, letter(first), name.unicodeScalars.count <= nameLimit
        else { return false }
        return name.unicodeScalars.allSatisfy { letter($0) || ("0"..."9").contains($0) }
    }

    /// Whether `value` passes on: not empty, no longer than `valueLimit`, and with no control
    /// characters.
    public static func isValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= valueLimit
            && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// The variables of `environment` that its `DRIP_FORWARD_ENV` names, as a click's payload has
    /// them: names that are not names, empty values and values that do not pass are left out, and
    /// so is each name past the first `countLimit`.
    public static func read(_ environment: [String: String]) -> [String: String] {
        let names = (environment[variable] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var forwarded: [String: String] = [:]
        for name in names.filter(isName).prefix(countLimit) {
            if let value = environment[name], isValue(value) { forwarded[name] = value }
        }
        return forwarded
    }

    /// The variables an event from another machine passes on, from its `forward` object: the same
    /// rules, applied again on this Mac, since the queue can hold anything.
    static func read(members: [JSONMember]) -> [String: String] {
        var forwarded: [String: String] = [:]
        for member in members.filter({ isName($0.key) }).prefix(countLimit) {
            if let value = member.value.string, isValue(value) { forwarded[member.key] = value }
        }
        return forwarded
    }
}
