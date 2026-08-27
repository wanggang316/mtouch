import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fakes

/// A window server under full test control. It answers the flush's counter reads,
/// records the posts, and keeps ONE ordered timeline of both — so "the baseline was
/// read before the first event went out" is provable rather than assumed.
private final class FakeWindowServer: EventDeliveryCounter {
    enum Step: Equatable {
        case read(CGEventType)
        case posted
    }

    private(set) var steps: [Step] = []
    private(set) var posted: [CGEvent] = []
    private var counts: [CGEventType: UInt32]

    init(start: [CGEventType: UInt32] = [:]) {
        counts = start
    }

    func count(of type: CGEventType) -> UInt32 {
        steps.append(.read(type))
        return counts[type] ?? 0
    }

    func post(_ event: CGEvent) {
        steps.append(.posted)
        posted.append(event)
    }

    /// The window server finishing with `count` events of `type` — the only way a
    /// counter ever moves in these tests, so no confirmation can be accidental.
    func process(_ count: UInt32, of type: CGEventType) {
        counts[type] = (counts[type] ?? 0) &+ count
    }

    var reads: Int { steps.filter { if case .read = $0 { return true }; return false }.count }
}

/// A monotonic clock that only moves when the flush sleeps, so every deadline
/// assertion is exact and no test depends on wall time.
private final class FakeClock {
    private(set) var time: TimeInterval = 0
    private(set) var sleeps: [TimeInterval] = []
    /// Called after each sleep with the sleep's 1-based ordinal, so a test can make
    /// delivery arrive on a chosen tick.
    var onSleep: ((Int) -> Void)?

    func now() -> TimeInterval { time }

    func sleep(_ duration: TimeInterval) {
        sleeps.append(duration)
        time += duration
        onSleep?(sleeps.count)
    }
}

private func flush(
    server: FakeWindowServer,
    clock: FakeClock,
    interval: TimeInterval = 0.01,
    deadline: TimeInterval = 1
) -> InputDeliveryFlush {
    InputDeliveryFlush(
        counter: server,
        interval: interval,
        now: { clock.now() },
        sleep: { clock.sleep($0) },
        deadlineForEvents: { _ in deadline }
    )
}

/// `pairs` keydown/keyup pairs — the shape `act type` posts, two event types at
/// once, which is what makes "wait for EVERY type" a real requirement.
private func keyPairs(_ pairs: Int) -> [CGEvent] {
    var events: [CGEvent] = []
    for _ in 0..<pairs {
        for keyDown in [true, false] {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) {
                events.append(event)
            }
        }
    }
    return events
}

private func keyDowns(_ count: Int) -> [CGEvent] {
    (0..<count).compactMap { _ in CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) }
}

// MARK: - The flush: it waits for the signal, and only for as long as it must

@Suite struct InputDeliveryFlushTests {
    @Test func confirmsWithoutSleepingAtAllWhenTheEventsAreAlreadyThrough() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        // The window server drains the burst the instant it is posted.
        let events = keyPairs(3)
        let subject = InputDeliveryFlush(
            counter: server, interval: 0.01,
            now: { clock.now() },
            sleep: { clock.sleep($0) },
            deadlineForEvents: { _ in 1 }
        )
        let confirmation = subject.post(events) { event in
            server.post(event)
            server.process(1, of: event.type)
        }

        #expect(confirmation == .confirmed)
        // The whole point: the condition is checked BEFORE any wait, so a healthy
        // delivery costs nothing.
        #expect(clock.sleeps.isEmpty)
        #expect(clock.time == 0)
    }

    @Test func returnsTheMOMENTTheCounterShowsEveryPostedEventDelivered() {
        let server = FakeWindowServer(start: [.keyDown: 40, .keyUp: 40])
        let clock = FakeClock()
        // Three characters: 3 keydowns + 3 keyups. Delivery lands on the 2nd tick.
        clock.onSleep = { tick in
            guard tick == 2 else { return }
            server.process(3, of: .keyDown)
            server.process(3, of: .keyUp)
        }

        let confirmation = flush(server: server, clock: clock).post(keyPairs(3)) { server.post($0) }

        #expect(confirmation == .confirmed)
        // It returned on the tick the signal arrived — not one interval later, and
        // nowhere near the deadline.
        #expect(clock.sleeps.count == 2)
        #expect(clock.time < 1)
    }

    @Test func waitsForEVERYEventTypeNotJustTheFirstToArrive() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        // The keydowns drain immediately; the keyups lag four ticks behind. A flush
        // that watched only one type would return with half the burst still in
        // flight — which is exactly how a trailing keyup gets lost.
        clock.onSleep = { tick in
            if tick == 1 { server.process(2, of: .keyDown) }
            if tick == 5 { server.process(2, of: .keyUp) }
        }

        let confirmation = flush(server: server, clock: clock).post(keyPairs(2)) { server.post($0) }

        #expect(confirmation == .confirmed)
        #expect(clock.sleeps.count == 5)
    }

    @Test func aPartiallyDrainedBurstIsNeverMistakenForADeliveredOne() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        // Two of the three keydowns land; the third never does.
        clock.onSleep = { tick in
            if tick == 1 { server.process(2, of: .keyDown) }
        }

        let confirmation = flush(server: server, clock: clock).post(keyDowns(3)) { server.post($0) }

        #expect(confirmation == .unconfirmed)
    }

    @Test func readsTheBaselineBeforeTheFirstEventIsPosted() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        _ = flush(server: server, clock: clock).post(keyPairs(1)) { event in
            server.post(event)
            server.process(1, of: event.type)
        }

        let firstPost = server.steps.firstIndex(of: .posted)
        let baselineReads = server.steps.prefix(while: { $0 != .posted })
        #expect(firstPost != nil)
        // One baseline read per event type, all of them before anything went out.
        // Read the baseline on the wrong side of a post and the delta is always
        // zero — the signal would silently mean nothing.
        #expect(baselineReads.count == 2)
        #expect(baselineReads.allSatisfy { if case .read = $0 { return true }; return false })
    }
}

// MARK: - Bounded: the deadline ends the wait, and says so

@Suite struct InputDeliveryFlushDeadlineTests {
    @Test func aSignalThatNeverArrivesEndsAtTheDeadlineRatherThanHanging() {
        let server = FakeWindowServer()
        let clock = FakeClock()

        let confirmation = flush(server: server, clock: clock, interval: 0.01, deadline: 1)
            .post(keyPairs(2)) { server.post($0) }

        // Not a hang, and not a silent success: the documented "could not confirm"
        // outcome, reached only after the whole budget was spent.
        #expect(confirmation == .unconfirmed)
        #expect(clock.time >= 1)
    }

    @Test func anUnconfirmedFlushStillPostedEveryEventItWasGiven() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        let events = keyPairs(4)

        let confirmation = flush(server: server, clock: clock).post(events) { server.post($0) }

        // "Unconfirmed" is a statement about the acknowledgement, not the posting:
        // the events went out, which is why the verb must not invite a retry that
        // would deliver them twice.
        #expect(confirmation == .unconfirmed)
        #expect(server.posted.count == events.count)
    }

    @Test func neverSleepsPastTheDeadline() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        // An interval far larger than the budget: the last wait must be clipped, so
        // expiry is prompt instead of rounded up to a whole interval.
        _ = flush(server: server, clock: clock, interval: 0.4, deadline: 1).post(keyDowns(1)) { server.post($0) }

        #expect(clock.sleeps.count == 3)
        #expect(clock.sleeps.dropLast() == [0.4, 0.4])
        // The final wait is clipped to what remained, so nothing sleeps past expiry.
        let last = clock.sleeps.last ?? 0
        #expect(last < 0.4)
        #expect(abs(last - 0.2) < 1e-9)
        #expect(clock.time == 1)
    }

    @Test func theBudgetScalesWithTheBurstAndIsCapped() {
        // A key combo gets essentially the fixed budget...
        #expect(InputDeliveryFlush.deadline(forEvents: 0) == InputDeliveryFlush.baseDeadline)
        // ...a long `act type` gets one proportional to what it posted...
        let forTwoHundred = InputDeliveryFlush.deadline(forEvents: 200)
        #expect(abs(forTwoHundred - (InputDeliveryFlush.baseDeadline + 1)) < 1e-9)
        #expect(forTwoHundred > InputDeliveryFlush.deadline(forEvents: 2))
        // ...and nothing outlasts the ceiling, which matches the bounded-walk one so
        // no single input verb can exceed the hung-target budget.
        #expect(InputDeliveryFlush.deadline(forEvents: 1_000_000) == InputDeliveryFlush.maxDeadline)
        #expect(InputDeliveryFlush.maxDeadline == BoundedWalk.defaultDeadline)
    }

    @Test func aLargeBurstReallyGetsTheLargerBudget() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        let events = keyPairs(400) // 800 events
        let subject = InputDeliveryFlush(
            counter: server, interval: 0.05,
            now: { clock.now() },
            sleep: { clock.sleep($0) }
        )

        let confirmation = subject.post(events) { server.post($0) }

        #expect(confirmation == .unconfirmed)
        // The real (unstubbed) budget was used, sized to the 800 events posted.
        #expect(clock.time == InputDeliveryFlush.deadline(forEvents: events.count))
        #expect(clock.time > InputDeliveryFlush.baseDeadline)
    }

    @Test func aCounterThatWrapsPastItsMaximumStillMeasuresTheAdvance() {
        // The window server's counter is a rolling 32-bit value. Straight
        // subtraction across the wrap would read as a huge NEGATIVE advance and
        // never confirm; wrapping subtraction reads the true delta of 3.
        let server = FakeWindowServer(start: [.keyDown: UInt32.max - 1])
        let clock = FakeClock()
        clock.onSleep = { tick in
            if tick == 1 { server.process(3, of: .keyDown) }
        }

        let confirmation = flush(server: server, clock: clock).post(keyDowns(3)) { server.post($0) }

        #expect(confirmation == .confirmed)
        #expect(clock.sleeps.count == 1)
    }
}

// MARK: - Zero events: nothing to wait for, so nothing is waited for

@Suite struct InputDeliveryFlushZeroEventTests {
    @Test func postingNothingNeitherReadsTheCounterNorSleeps() {
        let server = FakeWindowServer()
        let clock = FakeClock()

        let confirmation = flush(server: server, clock: clock).post([]) { server.post($0) }

        // A delivery of zero events has no signal coming, ever. Waiting for one
        // would turn the secure-input refusal and `act type ""` into a stall.
        #expect(confirmation == .nothingPosted)
        #expect(server.reads == 0)
        #expect(server.posted.isEmpty)
        #expect(clock.sleeps.isEmpty)
        #expect(clock.time == 0)
    }
}

// MARK: - The synthesis chokepoint reports what the flush established

private struct StubActivator: Activator {
    func activate(pid: pid_t) {}
}

private struct StubSecureInputState: SecureInputState {
    let active: Bool
    var isSecureInputActive: Bool { active }
}

private struct ServerPoster: EventPoster {
    let server: FakeWindowServer
    let drains: Bool
    func post(_ event: CGEvent) {
        server.post(event)
        if drains { server.process(1, of: event.type) }
    }
}

@Suite struct InputSynthesizerFlushTests {
    private func synthesizer(
        server: FakeWindowServer,
        clock: FakeClock,
        drains: Bool = true,
        secureInputActive: Bool = false
    ) -> InputSynthesizer {
        InputSynthesizer(
            targetPID: 4242,
            activator: StubActivator(),
            secureInput: StubSecureInputState(active: secureInputActive),
            poster: ServerPoster(server: server, drains: drains),
            source: nil,
            flush: flush(server: server, clock: clock)
        )
    }

    @Test func everyKeyboardVerbWaitsForItsOwnEventsAndReportsConfirmation() throws {
        let server = FakeWindowServer()
        let clock = FakeClock()
        let subject = synthesizer(server: server, clock: clock)

        #expect(try subject.type("hi") == .confirmed)
        #expect(try subject.key(KeyCombo(parsing: "cmd+s")) == .confirmed)
        // 2 characters * 2 events + one keydown/keyup pair.
        #expect(server.posted.count == 6)
    }

    @Test func everyPointerVerbWaitsForItsOwnEventsAndReportsConfirmation() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        let subject = synthesizer(server: server, clock: clock)
        let point = ScreenPoint(x: 100, y: 100)

        #expect(subject.click(at: point) == .confirmed)
        #expect(subject.rightClick(at: point) == .confirmed)
        #expect(subject.doubleClick(at: point) == .confirmed)
        #expect(subject.drag(from: point, to: ScreenPoint(x: 140, y: 100)) == .confirmed)
        #expect(subject.scroll(at: point, dy: -3) == .confirmed)
        #expect(subject.move(to: point) == .confirmed)
    }

    @Test func aBurstTheWindowServerNeverAcknowledgesComesBackUnconfirmed() throws {
        let server = FakeWindowServer()
        let clock = FakeClock()
        let subject = synthesizer(server: server, clock: clock, drains: false)

        #expect(try subject.type("hi") == .unconfirmed)
        #expect(server.posted.count == 4) // posted all the same
    }

    @Test func anEmptyTypeDeliversNothingAndWaitsForNothing() throws {
        let server = FakeWindowServer()
        let clock = FakeClock()

        #expect(try synthesizer(server: server, clock: clock).type("") == .nothingPosted)
        #expect(server.posted.isEmpty)
        #expect(server.reads == 0)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func aSecureInputRefusalNeverReachesTheFlushAtAll() {
        let server = FakeWindowServer()
        let clock = FakeClock()
        let subject = synthesizer(server: server, clock: clock, secureInputActive: true)

        #expect(throws: SecureInputActive.self) {
            try subject.type("correct horse battery staple")
        }
        // Exit 5 posts zero events, so there is no signal to wait for: the refusal
        // must stay instant.
        #expect(server.posted.isEmpty)
        #expect(server.reads == 0)
        #expect(clock.sleeps.isEmpty)
    }
}

// MARK: - The notice: a different, and stronger, statement than --no-verify's

@Suite struct UnconfirmedDeliveryNoticeTests {
    @Test func theNoticeSaysWhatIsKnownWhatIsNotAndWhatToDoNext() {
        let notice = UnconfirmedDelivery.notice
        #expect(notice.contains("posted"))
        #expect(notice.contains("could NOT be confirmed"))
        #expect(notice.contains("may not have taken effect"))
        #expect(notice.contains("mtouch snapshot"))
        #expect(UnconfirmedDelivery.rendered(json: false) == notice)
        // It must not parse as a diff, or the absence of evidence reads as evidence.
        #expect(notice != DiffText.noChangesMarker)
    }

    @Test func itIsDistinctFromAndStrongerThanTheUnverifiedNotice() {
        // Two different states of knowledge: "delivered, effect unchecked" versus
        // "posted, arrival unestablished". An agent that cannot tell them apart
        // cannot tell whether its input happened at all.
        #expect(UnconfirmedDelivery.notice != UnverifiedDelivery.notice)
        #expect(UnconfirmedDelivery.noticeJSON != UnverifiedDelivery.noticeJSON)
        #expect(!UnverifiedDelivery.notice.contains("could NOT be confirmed"))
    }

    @Test func theJSONFormSeparatesPostedFromConfirmed() throws {
        let rendered = UnconfirmedDelivery.rendered(json: true)
        #expect(rendered == UnconfirmedDelivery.noticeJSON)
        let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        let parsed = try #require(object)
        #expect(parsed["posted"] as? Bool == true)
        #expect(parsed["confirmed"] as? Bool == false)
        #expect(parsed["verified"] as? Bool == false)
        #expect(parsed["note"] as? String == UnconfirmedDelivery.notice)
        // No `delivered` key: that is the UNVERIFIED notice's field, and a consumer
        // keying off it must not read this as an ordinary unverified delivery.
        #expect(parsed["delivered"] == nil)
        // And it must not shape like a diff.
        #expect(parsed["added"] == nil)
    }
}

// MARK: - Pipeline fixtures

private func textArea(_ value: String) -> AXNode {
    AXNode(
        role: "AXTextArea", value: value,
        frame: CGRect(x: 0, y: 0, width: 300, height: 200), actionable: true
    )
}

private func window(_ children: [AXNode]) -> AXNode {
    AXNode(role: kAXWindowRole, title: "W", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: children)
}

private func walked(_ nodes: [AXNode]) -> WalkResult {
    WalkResult(nodes: nodes, fallbackFired: false, fallbackHelped: false, truncated: false)
}

private struct GrantedPermissions: PermissionProvider {
    var accessibilityGranted: Bool { true }
    var screenRecordingGranted: Bool { false }
}

private let liveTree = [window([textArea("")])]

private func liveSession() -> Session {
    Session(snapshot: Snapshot(roots: liveTree), app: "com.example.App", pid: 4242)
}

/// Counts walks so "the post-action walk was skipped" is asserted against the seam.
private final class WalkCounter {
    private(set) var calls = 0
    func walk(_ pid: pid_t) -> WalkResult? {
        calls += 1
        return walked(liveTree)
    }
}

// MARK: - Every input verb reports an unconfirmed delivery, verified or not

@Suite struct ActUnconfirmedDeliveryTests {
    @Test func anUnverifiedKeyboardDeliveryReportsTheStrongerNotice() {
        let walker = WalkCounter()
        let outcome = ActPipeline.runKeyboard(
            action: .type("hello"), appOverride: nil, json: false, noVerify: true,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            rewalk: { walker.walk($0) },
            deliver: { _, _ in throw DeliveryUnconfirmed() },
            persist: { _, _, _, _ in Issue.record("an unconfirmed delivery must not persist a session") },
            sleep: { _ in Issue.record("an unconfirmed delivery must not settle") }
        )

        #expect(outcome == .deliveredUnconfirmed(UnconfirmedDelivery.notice))
        // Never the weaker notice: the input's ARRIVAL is what is in doubt here.
        #expect(outcome != .deliveredUnverified(UnverifiedDelivery.notice))
        #expect(walker.calls == 0)
    }

    /// The verified path is where the old behaviour was merely lucky: it "worked"
    /// because its post-action walk happened to hold the process open. Now the
    /// delivery is flushed first, and an unflushable one stops there.
    @Test func aVerifiedKeyboardDeliveryStopsAtTheFlushInsteadOfWalkingAnyway() {
        let walker = WalkCounter()
        let outcome = ActPipeline.runKeyboard(
            action: .type("hello"), appOverride: nil, json: false,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            rewalk: { walker.walk($0) },
            deliver: { _, _ in throw DeliveryUnconfirmed() },
            persist: { _, _, _, _ in Issue.record("an unconfirmed delivery must not persist a session") },
            sleep: { _ in Issue.record("an unconfirmed delivery must not settle") }
        )

        #expect(outcome == .deliveredUnconfirmed(UnconfirmedDelivery.notice))
        // Only the pre-action baseline was taken. A post-action diff would describe
        // a UI that may never have received the input, and presenting it as the
        // effect of the action would be exactly the false claim to avoid.
        #expect(walker.calls == 1)
    }

    @Test func aVerifiedCoordinateDeliveryStopsAtTheFlushToo() {
        let walker = WalkCounter()
        let outcome = ActPipeline.runCoordinate(
            action: .click(ScreenPoint(x: 100, y: 100)), appOverride: nil, json: false,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { walker.walk($0) },
            deliver: { _, _ in throw DeliveryUnconfirmed() },
            persist: { _, _, _, _ in Issue.record("an unconfirmed delivery must not persist a session") },
            sleep: { _ in Issue.record("an unconfirmed delivery must not settle") }
        )

        #expect(outcome == .deliveredUnconfirmed(UnconfirmedDelivery.notice))
        #expect(walker.calls == 1)
    }

    @Test func anUnverifiedCoordinateDeliveryReportsTheStrongerNoticeToo() {
        let walker = WalkCounter()
        let outcome = ActPipeline.runCoordinate(
            action: .scroll(at: ScreenPoint(x: 100, y: 100), dy: -300),
            appOverride: nil, json: false, noVerify: true,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            onScreen: { _ in true },
            rewalk: { walker.walk($0) },
            deliver: { _, _ in throw DeliveryUnconfirmed() },
            persist: { _, _, _, _ in Issue.record("must not persist") },
            sleep: { _ in Issue.record("must not settle") }
        )

        #expect(outcome == .deliveredUnconfirmed(UnconfirmedDelivery.notice))
        #expect(walker.calls == 0)
    }

    @Test func jsonRendersTheMachineReadableUnconfirmedNotice() throws {
        let outcome = try ActPipeline.runKeyboard(
            action: .key(KeyCombo(parsing: "return")), appOverride: nil, json: true, noVerify: true,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            rewalk: { _ in nil },
            deliver: { _, _ in throw DeliveryUnconfirmed() },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        #expect(outcome == .deliveredUnconfirmed(UnconfirmedDelivery.noticeJSON))
    }

    /// The contrast, in the same suite as the claim: a CONFIRMED delivery is
    /// untouched — it still walks, still diffs, still persists.
    @Test func aConfirmedVerifiedDeliveryStillWalksDiffsAndPersists() {
        let pre = [window([textArea("")])]
        let post = [window([textArea("hello")])]
        var walks = 0
        var persisted = 0

        let outcome = ActPipeline.runKeyboard(
            action: .type("hello"), appOverride: nil, json: false,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in Session(snapshot: Snapshot(roots: pre), app: "com.example.App", pid: 4242) },
            isRunning: { _, _ in true },
            rewalk: { _ in
                walks += 1
                return walks == 1 ? walked(pre) : walked(post)
            },
            deliver: { _, _ in },
            persist: { _, _, _, _ in persisted += 1 },
            sleep: { _ in }
        )

        guard case let .acted(rendered) = outcome else { Issue.record("expected a verified act"); return }
        #expect(rendered.contains("hello"))
        #expect(walks >= 2)
        #expect(persisted == 1)
    }

    /// Precedence is unchanged: a refusal that posts ZERO events is still a
    /// refusal, never an unconfirmed delivery.
    @Test func aSecureInputRefusalIsStillExit5AndNotAnUnconfirmedDelivery() {
        let outcome = ActPipeline.runKeyboard(
            action: .type("secret"), appOverride: nil, json: false, noVerify: true,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in liveSession() },
            isRunning: { _, _ in true },
            rewalk: { _ in nil },
            deliver: { _, _ in throw SecureInputActive() },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        guard case let .failed(_, code) = outcome else { Issue.record("expected a refusal"); return }
        #expect(code == .secureInput)
    }

    /// An empty `type` posts nothing, so there is no delivery to confirm and the
    /// no-op contract is untouched.
    @Test func anEmptyTypeIsStillAPlainNoOp() {
        let outcome = ActPipeline.runKeyboard(
            action: .type(""), appOverride: nil, json: false, noVerify: true,
            environment: [:], permissions: GrantedPermissions(),
            loadSession: { _ in Issue.record("an empty type resolves nothing"); return nil },
            isRunning: { _, _ in true },
            rewalk: { _ in nil },
            deliver: { _, _ in Issue.record("an empty type delivers nothing") },
            persist: { _, _, _, _ in }, sleep: { _ in }
        )
        guard case let .acted(rendered) = outcome else { Issue.record("expected a no-op act"); return }
        #expect(rendered == DiffText.noChangesMarker)
    }
}

// MARK: - Trajectory: unconfirmed is recorded as its own, stronger fact

@Suite struct UnconfirmedTrajectoryTests {
    @Test func theOutcomeMapsToBothVerifiedFalseAndDeliveryConfirmedFalse() {
        let unconfirmed = ActOutcome.deliveredUnconfirmed(UnconfirmedDelivery.notice).trajectoryInfo
        #expect(unconfirmed.deliveryConfirmed == false)
        // Nothing was verified either — no walk was taken.
        #expect(unconfirmed.verified == false)
        // The notice is NOT a diff and must never be recorded as one.
        #expect(unconfirmed.diff == nil)

        // The weaker case makes no claim about delivery: it WAS delivered.
        let unverified = ActOutcome.deliveredUnverified(UnverifiedDelivery.notice).trajectoryInfo
        #expect(unverified.verified == false)
        #expect(unverified.deliveryConfirmed == nil)

        // And an ordinary verified act claims nothing in either field.
        let acted = ActOutcome.acted("~ e1 AXTextArea \"hi\"").trajectoryInfo
        #expect(acted.verified == nil)
        #expect(acted.deliveryConfirmed == nil)
    }

    @Test func theRecordCarriesDeliveryConfirmedFalseAndNoDiff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-unconfirmed-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let trajectory = dir.appendingPathComponent("t.jsonl").path
        let environment = [
            "MTOUCH_TRAJECTORY": trajectory,
            "MTOUCH_SESSION": dir.appendingPathComponent("s.json").path,
        ]

        _ = try TrajectoryRecorder.record(
            command: "act",
            args: TrajectoryArgs.build(["verb": .string("type"), "text": .string("hello")]),
            kind: .action,
            environment: environment,
            operation: { ActOutcome.deliveredUnconfirmed(UnconfirmedDelivery.notice) },
            describe: { $0.trajectoryInfo }
        )

        let content = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
        let line = try #require(content.split(separator: "\n").first)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let record = try #require(object)

        // Both fields, so a reader can tell an unconfirmed delivery from a merely
        // unverified one without parsing prose.
        #expect(record["deliveryConfirmed"] as? Bool == false)
        #expect(record["verified"] as? Bool == false)
        #expect(record["diff"] == nil)
        let outcome = try #require(record["outcome"] as? [String: Any])
        #expect(outcome["ok"] as? Bool == true)
        #expect(outcome["exit"] as? Int32 == 0)
    }

    @Test func anOrdinaryActRecordStillCarriesNeitherField() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtouch-confirmed-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let trajectory = dir.appendingPathComponent("t.jsonl").path
        _ = try TrajectoryRecorder.record(
            command: "act",
            args: TrajectoryArgs.build(["verb": .string("type")]),
            kind: .action,
            environment: [
                "MTOUCH_TRAJECTORY": trajectory,
                "MTOUCH_SESSION": dir.appendingPathComponent("s.json").path,
            ],
            operation: { ActOutcome.acted("~ e1 AXTextArea \"hi\"") },
            describe: { $0.trajectoryInfo }
        )

        let content = try String(contentsOf: URL(fileURLWithPath: trajectory), encoding: .utf8)
        let line = try #require(content.split(separator: "\n").first)
        let record = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(record["deliveryConfirmed"] == nil)
        #expect(record["verified"] == nil)
        #expect(record["diff"] as? String == "~ e1 AXTextArea \"hi\"")
    }

    @Test func theMCPSurfaceMarksItsOwnUnconfirmedDeliveriesToo() {
        let payload = ToolResult(
            payloads: [.text(UnconfirmedDelivery.notice)], isError: false, deliveryConfirmed: false
        )
        let info = payload.trajectoryInfo(kind: .action)
        #expect(info.deliveryConfirmed == false)
        // Unconfirmed implies unverified: no walk was taken, so the notice is not a diff.
        #expect(info.verified == false)
        #expect(info.diff == nil)

        // Unchanged for an ordinary action.
        let verified = ToolResult.text("+ e2 AXButton \"B\"").trajectoryInfo(kind: .action)
        #expect(verified.diff == "+ e2 AXButton \"B\"")
        #expect(verified.deliveryConfirmed == nil)
    }
}
