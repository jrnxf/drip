import DripCore
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif
import Testing

struct QueueTests {
    @Test func ticketNamesSortInQueueOrderAndParseBack() throws {
        let first = QueueTicket.name(stamp: 999, pid: 40)
        let second = QueueTicket.name(stamp: 1_000, pid: 7)
        #expect(first == "00000000000000000999-40")
        #expect(first < second)
        let ticket = try #require(QueueTicket(name: second))
        #expect(ticket.pid == 7)
        #expect(ticket.cards.isEmpty)
        #expect(ticket.claimed.isEmpty)
    }

    @Test func aTicketKeepsWhenItsProcessStarted() throws {
        let name = QueueTicket.name(stamp: 999, pid: 40, start: 1_792_357_665_123_456)
        #expect(name == "00000000000000000999-40-1792357665123456")
        let ticket = try #require(QueueTicket(name: name))
        #expect(ticket.pid == 40)
        #expect(ticket.start == 1_792_357_665_123_456)
        #expect(try #require(QueueTicket(name: QueueTicket.name(stamp: 999, pid: 40))).start == nil)
        #expect(QueueTicket.name(stamp: 999, pid: 40) < QueueTicket.name(stamp: 1_000, pid: 7, start: 1))
    }

    @Test func onlyTicketNamesAreTickets() {
        for name in ["00000000000000000999-40.claimed", ".00000000000000000999-40.40.tmp", "999-40",
                     "00000000000000000999-", "00000000000000000999-4x", "00000000000000000999-40-",
                     "00000000000000000999-40-1x", "00000000000000000999-40-1-2",
                     "00000000000000000999-40-123.claimed", "x"] {
            #expect(QueueTicket(name: name) == nil, "\(name)")
        }
        #expect(QueueTicket.claimName(for: "00000000000000000999-40") == "00000000000000000999-40.claimed")
    }

    @Test func aNewerLiveCardWithTheSameIDReplacesAQueuedOne() {
        let mine = ticket(1, pid: 10, card("a"))
        let queue = [mine, ticket(2, pid: 20, card("a"))]
        #expect(CardReplacement.isReplaced(card("a"), in: mine, queue: queue, isAlive: { _ in true }))
    }

    @Test func otherIDsOlderTicketsAndDeadDripsReplaceNothing() {
        let mine = ticket(2, pid: 10, card("a"))
        #expect(!CardReplacement.isReplaced(
            card("a"), in: mine, queue: [mine, ticket(3, pid: 20, card("b"))], isAlive: { _ in true }))
        #expect(!CardReplacement.isReplaced(
            card("a"), in: mine, queue: [ticket(1, pid: 20, card("a")), mine], isAlive: { _ in true }))
        #expect(!CardReplacement.isReplaced(
            card("a"), in: mine, queue: [mine, ticket(3, pid: 20, card("a"))], isAlive: { $0.pid != 20 }))
        #expect(!CardReplacement.isReplaced(
            card(nil), in: mine, queue: [mine, ticket(3, pid: 20, card(nil))], isAlive: { _ in true }))
    }

    @Test func aClaimedCardIsReplaced() {
        var mine = ticket(2, pid: 10, card("a"))
        mine.claimed = ["a"]
        #expect(CardReplacement.isReplaced(card("a"), in: mine, queue: [mine], isAlive: { _ in true }))
    }

    @Test func theShownCardTakesTheNewestLiveReplacement() throws {
        let queue = [
            ticket(1, pid: 10, card("a", title: "shown")), ticket(2, pid: 20, card("a", title: "older")),
            ticket(3, pid: 30, card("b", title: "other")), ticket(4, pid: 40, card("a", title: "newest")),
            ticket(5, pid: 50, card("a", title: "dead")),
        ]
        let found = try #require(CardReplacement.replacement(
            for: card("a"), after: queue[0].name, queue: queue, isAlive: { $0.pid != 50 }))
        #expect(found.ticket == queue[3].name)
        #expect(found.card.title == "newest")
    }

    @Test func replacementsComeOnlyFromAfterTheSource() {
        let queue = [ticket(1, pid: 10, card("a")), ticket(2, pid: 20, card("a"))]
        #expect(CardReplacement.replacement(for: card("a"), after: queue[1].name, queue: queue, isAlive: { _ in true })
            == nil)
        #expect(CardReplacement.replacement(for: card(nil), after: queue[0].name, queue: queue, isAlive: { _ in true })
            == nil)
    }

    @Test func claimedTicketsAreSkipped() throws {
        var claimed = ticket(3, pid: 30, card("a", title: "claimed"))
        claimed.claimed = ["a"]
        let queue = [ticket(1, pid: 10, card("a")), ticket(2, pid: 20, card("a", title: "next")), claimed]
        let found = try #require(CardReplacement.replacement(
            for: card("a"), after: queue[0].name, queue: queue, isAlive: { _ in true }))
        #expect(found.card.title == "next")
    }

    @Test func aNewestCardThatCannotSwapWaitsForItsTurn() {
        var question = card("a")
        question.action = CardAction(label: "Allow", open: nil)
        let queue = [ticket(1, pid: 10, card("a")), ticket(2, pid: 20, card("a")), ticket(3, pid: 30, question)]
        #expect(CardReplacement.replacement(for: card("a"), after: queue[0].name, queue: queue, isAlive: { _ in true })
            == nil)
    }

    @Test func swappingNeedsTheSamePlaceAndNoQuestion() {
        #expect(CardReplacement.canSwap(card("a"), for: card("a")))
        var linked = card("a")
        linked.action = CardAction(label: "View", open: "https://example.com")
        #expect(CardReplacement.canSwap(card("a"), for: linked))
        var question = card("a")
        question.action = CardAction(label: "Promote", open: nil)
        #expect(!CardReplacement.canSwap(question, for: card("a")))
        #expect(!CardReplacement.canSwap(card("a"), for: question))
        var bottom = card("a")
        bottom.position = .bottom
        #expect(!CardReplacement.canSwap(card("a"), for: bottom))
    }

    @Test func onlyTheNewestCardForEachIDIsKeptInOrder() {
        let cards = [
            card("a", title: "needs you"), card(nil, title: "plain"), card("b", title: "deploy"),
            card(nil, title: "plain"), card("a", title: "is done"),
        ]
        #expect(CardReplacement.latest(cards).map(\.title) == ["plain", "deploy", "plain", "is done"])
        #expect(CardReplacement.latest([]).isEmpty)
    }

    // MARK: Adoption into a stack at the notch

    @Test func aStackAdoptsNewerNotchCardsFromLiveBackgroundDripsOldestFirst() {
        let mine = ticket(1, pid: 10, notch(nil))
        var elsewhere = card(nil, title: "elsewhere")
        elsewhere.position = .bottom
        let queue = [
            mine, adoptable(2, pid: 20, notch(nil, title: "b"), elsewhere),
            adoptable(3, pid: 30, notch(nil, title: "c")),
        ]
        let found = CardAdoption.candidates(after: mine.name, queue: queue, isAlive: { _ in true })
        #expect(found.map(\.card.title) == ["b", "c"])
        #expect(found.map(\.index) == [0, 0])
    }

    @Test func aStackNeverAdoptsWaitingDripsQuestionsClaimedCardsDeadDripsOrOlderTickets() {
        let mine = ticket(2, pid: 10, notch(nil))
        var question = notch(nil)
        question.action = CardAction(label: "OK", open: nil)
        var claimed = adoptable(4, pid: 40, notch(nil))
        claimed.claimed = [CardAdoption.claimKey(index: 0)]
        let queue = [
            adoptable(1, pid: 15, notch(nil)), mine, ticket(3, pid: 30, notch(nil)), claimed,
            adoptable(5, pid: 50, question), adoptable(6, pid: 60, notch(nil)),
        ]
        #expect(CardAdoption.candidates(after: mine.name, queue: queue, isAlive: { $0.pid != 60 }).isEmpty)
    }

    @Test func aStackSkipsACardThatANewerOneWithTheSameIDReplaces() {
        let mine = ticket(1, pid: 10, notch(nil))
        let queue = [mine, adoptable(2, pid: 20, notch("x", title: "old")), adoptable(3, pid: 30, notch("x", title: "new"))]
        let found = CardAdoption.candidates(after: mine.name, queue: queue, isAlive: { _ in true })
        #expect(found.map(\.card.title) == ["new"])
    }

    @Test func aTicketIsFullyAdoptedOnceEveryCardIsClaimed() {
        var two = adoptable(1, pid: 10, notch(nil), notch(nil))
        #expect(!two.isFullyAdopted)
        two.claimed = [CardAdoption.claimKey(index: 0)]
        #expect(!two.isFullyAdopted)
        two.claimed.insert(CardAdoption.claimKey(index: 1))
        #expect(two.isFullyAdopted)
        #expect(!ticket(2, pid: 20).isFullyAdopted)
    }

    @Test func ticketContentsReadBothFormats() throws {
        let cards = [notch("a")]
        let current = try JSONEncoder().encode(TicketContents(cards: cards, adoptable: true))
        #expect(TicketContents.decode(current) == TicketContents(cards: cards, adoptable: true))
        let older = try JSONEncoder().encode(cards)
        #expect(TicketContents.decode(older) == TicketContents(cards: cards, adoptable: false))
        #expect(TicketContents.decode(Data("nope".utf8)) == nil)
    }

    private func notch(_ id: String?, title: String = "hi") -> Card {
        var card = card(id, title: title)
        card.position = .notch
        return card
    }

    private func adoptable(_ stamp: UInt64, pid: Int32, _ cards: Card...) -> QueueTicket {
        QueueTicket(name: QueueTicket.name(stamp: stamp, pid: pid), cards: cards, adoptable: true)!
    }

    private func card(_ id: String?, title: String = "hi") -> Card {
        var card = Card(preset: .info, title: title)
        card.id = id
        return card
    }

    private func ticket(_ stamp: UInt64, pid: Int32, _ cards: Card...) -> QueueTicket {
        QueueTicket(name: QueueTicket.name(stamp: stamp, pid: pid), cards: cards)!
    }
}
