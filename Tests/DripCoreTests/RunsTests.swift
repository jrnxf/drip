import DripCore
import Testing

/// The contrast edge merges each run of equal shapes once, and keeps the last shape's outline so a
/// card at rest, given the same shape again, is not merged again.
struct RunsTests {
    @Test func eachRunOfEqualItemsInARowIsOneRun() {
        let runs = Runs(["a", "a", "b", "b", "b", "a", "c"])
        #expect(runs.firsts == [0, 2, 5, 6])
        #expect(runs.run == [0, 0, 1, 1, 1, 2, 3])
    }

    @Test func expandGivesEachItemItsRunsValue() {
        let items = [1, 1, 2, 1, 1]
        let runs = Runs(items)
        #expect(runs.expand(runs.firsts.map { items[$0] * 10 }) == [10, 10, 20, 10, 10])
    }

    @Test func noItemsAndOneItem() {
        #expect(Runs([Int]()).firsts.isEmpty)
        #expect(Runs([Int]()).expand([String]()).isEmpty)
        #expect(Runs([7]) == Runs([8]))
        #expect(Runs([7]).run == [0])
    }

    @Test func allEqualIsOneRun() {
        let runs = Runs(Array(repeating: "rest", count: 240))
        #expect(runs.firsts == [0])
        #expect(runs.expand(["outline"]) == Array(repeating: "outline", count: 240))
    }

    @Test func theLastKeyIsWorkedOutOnce() {
        var cache = LastResult<String, Int>()
        var made: [String] = []
        let make = { (key: String) -> Int in made.append(key); return key.count }
        #expect(cache.value(for: "drop", make: make) == 4)
        #expect(cache.value(for: "drop", make: make) == 4)
        #expect(made == ["drop"])
        #expect(cache.value(for: "notch", make: make) == 5)
        #expect(cache.value(for: "drop", make: make) == 4)
        #expect(made == ["drop", "notch", "drop"])
    }

    @Test func aValueKeptElsewhereIsUsed() {
        var cache = LastResult<String, Int>()
        cache.keep(42, for: "rest")
        #expect(cache.value(for: "rest") { _ in Issue.record("worked out again"); return 0 } == 42)
        #expect(cache.last?.key == "rest")
    }
}
