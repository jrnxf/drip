/// Which app a click on a card brings forward.
///
/// macOS sets `__CFBundleIdentifier` in the environment of everything an app starts, so a drip run
/// from a terminal, or from an agent's hook inside one, knows the terminal it came from.
public enum CardActivation {
    /// The `--activate` value that turns it off.
    public static let none = "none"

    /// The environment variable macOS sets to the bundle identifier of the app that started drip.
    public static let senderVariable = "__CFBundleIdentifier"

    /// `--activate` when given (`none` for no app), else the app drip was run from.
    public static func target(flag: String?, sender: String?) -> String? {
        if let flag {
            return flag == none ? nil : flag
        }
        return sender
    }

    /// The app that started drip, when the environment names one with a valid bundle identifier.
    public static func sender(in environment: [String: String]) -> String? {
        guard let sender = environment[senderVariable], isBundleIdentifier(sender) else { return nil }
        return sender
    }

    /// Whether `text` looks like a bundle identifier: letters, digits, hyphens and dots, such as
    /// `com.apple.Terminal`, without empty components.
    public static func isBundleIdentifier(_ text: String) -> Bool {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        return text.count <= 255 && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
