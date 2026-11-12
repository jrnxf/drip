/// A list's runs of equal items in a row, so work on each item is done once a run: a card at rest
/// gives the same shape frame after frame.
public struct Runs: Equatable {
    /// Where each run starts.
    public let firsts: [Int]
    /// For each item, the run it is in.
    public let run: [Int]

    public init<Item: Equatable>(_ items: [Item]) {
        var firsts: [Int] = []
        var run: [Int] = []
        run.reserveCapacity(items.count)
        for index in items.indices {
            if index > 0, items[index] == items[index - 1] {
                run.append(run[index - 1])
            } else {
                run.append(firsts.count)
                firsts.append(index)
            }
        }
        self.firsts = firsts
        self.run = run
    }

    /// One value per item, from one value per run.
    public func expand<Value>(_ values: [Value]) -> [Value] {
        precondition(values.count == firsts.count, "one value per run")
        return run.map { values[$0] }
    }
}

/// The last key worked out and its value, so the same key given again is not worked out again.
public struct LastResult<Key: Equatable, Value> {
    public private(set) var last: (key: Key, value: Value)?

    public init() {}

    /// `key`'s value: the one kept when `key` is the last key, otherwise `make`'s, which is kept.
    public mutating func value(for key: Key, make: (Key) -> Value) -> Value {
        if let last, last.key == key { return last.value }
        let value = make(key)
        last = (key, value)
        return value
    }

    /// Keeps `value` as `key`'s, worked out elsewhere.
    public mutating func keep(_ value: Value, for key: Key) {
        last = (key, value)
    }
}
