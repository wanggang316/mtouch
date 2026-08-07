import ApplicationServices
import Foundation
import Testing
@testable import MTouchKit

@Suite struct GuardedWalkTests {
    @Test func healthyWalkReturnsTheTree() {
        let tree = [AXNode(role: kAXWindowRole, title: "Untitled")]
        let guarded = GuardedWalk(work: { tree })

        #expect(guarded.sample() == tree)
        #expect(guarded.sample() == tree)
        // Each healthy poll spawns and completes its own short-lived task.
        #expect(guarded.spawnCount == 2)
    }

    @Test func hungTargetNeverSpawnsMoreThanOneBackgroundWalk() {
        // Model a hung target: the walk blocks until the test releases it. Under a
        // short deadline every poll times out; the single-flight guard must ensure
        // NO second background walk is ever spawned, no matter how many polls run.
        let release = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let guarded = GuardedWalk(deadline: 0.05, work: {
            release.wait()   // block as if the target is unresponsive
            drained.signal() // let the test observe the hung walk actually unblocked
            return []
        })

        for _ in 0..<25 {
            #expect(guarded.sample() == nil) // times out: not met this round
        }
        // The cap held: exactly one background walk was ever started.
        #expect(guarded.spawnCount == 1)

        // Let the hung walk finish AND wait for it to drain before the test returns.
        // Signaling alone leaves the just-released background thread racing the
        // swift-testing teardown; an abandoned/in-flight queue thread SIGBUSes on the
        // Xcode 16.x testing runtime, so we block until it has observed the release.
        release.signal()
        drained.wait()
    }
}
