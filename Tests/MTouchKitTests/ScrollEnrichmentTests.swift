import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MTouchKit

// MARK: - Fixtures (pure AXNode trees, zero AX/TCC dependency)

/// A horizontal scrollbar: wide-and-short frame, `AXValue` fraction as a string
/// (exactly what the walker renders from the scrollbar's `kAXValueAttribute`).
private func horizontalScrollBar(_ fraction: Double) -> AXNode {
    AXNode(role: kAXScrollBarRole, value: JSONText.number(fraction),
           frame: CGRect(x: 0, y: 200, width: 300, height: 15))
}

/// A vertical scrollbar: tall-and-narrow frame.
private func verticalScrollBar(_ fraction: Double) -> AXNode {
    AXNode(role: kAXScrollBarRole, value: JSONText.number(fraction),
           frame: CGRect(x: 300, y: 0, width: 15, height: 200))
}

/// A scroll area whose `isScrollArea` is derived from its role, with `content`
/// plus the given scrollbars — mirroring a real AXScrollArea subtree.
private func scrollArea(content: [AXNode], scrollBars: [AXNode]) -> AXNode {
    AXNode(role: kAXScrollAreaRole, frame: CGRect(x: 0, y: 0, width: 300, height: 200),
           isScrollArea: true, children: content + scrollBars)
}

@Suite struct ScrollEnrichmentTests {
    @Test func derivesBothAxesFromHorizontalAndVerticalScrollBars() {
        let area = scrollArea(
            content: [AXNode(role: kAXTextAreaRole, value: "body", actionable: true)],
            scrollBars: [horizontalScrollBar(0.25), verticalScrollBar(0.5)]
        )

        let enriched = ScrollEnrichment.enrich(area)

        #expect(enriched.scrollPosition == CGPoint(x: 0.25, y: 0.5))
        // The content survives untouched.
        #expect(enriched.children.first?.role == kAXTextAreaRole)
    }

    @Test func verticalOnlyDefaultsHorizontalToZero() {
        let area = scrollArea(content: [], scrollBars: [verticalScrollBar(0.75)])
        #expect(ScrollEnrichment.enrich(area).scrollPosition == CGPoint(x: 0, y: 0.75))
    }

    @Test func horizontalOnlyDefaultsVerticalToZero() {
        let area = scrollArea(content: [], scrollBars: [horizontalScrollBar(0.4)])
        #expect(ScrollEnrichment.enrich(area).scrollPosition == CGPoint(x: 0.4, y: 0))
    }

    @Test func scrollAreaWithNoScrollBarsStaysNil() {
        // Documented: a scroll area that genuinely exposes no scrollbars (e.g. an
        // empty TextEdit document) keeps `scrollPosition == nil`.
        let area = scrollArea(content: [AXNode(role: kAXTextAreaRole, value: "")], scrollBars: [])
        #expect(ScrollEnrichment.enrich(area).scrollPosition == nil)
    }

    @Test func unparseableScrollBarValueIsIgnored() {
        let bogus = AXNode(role: kAXScrollBarRole, value: "not-a-number",
                           frame: CGRect(x: 300, y: 0, width: 15, height: 200))
        let area = scrollArea(content: [], scrollBars: [bogus])
        #expect(ScrollEnrichment.enrich(area).scrollPosition == nil)
    }

    @Test func nestedScrollAreaInsideAWindowIsEnriched() throws {
        let window = AXNode(role: kAXWindowRole, title: "Doc", children: [
            scrollArea(content: [], scrollBars: [verticalScrollBar(0.9)]),
        ])

        let enriched = ScrollEnrichment.enrich([window])

        let area = try #require(enriched.first?.children.first)
        #expect(area.scrollPosition == CGPoint(x: 0, y: 0.9))
    }

    @Test func nonScrollAreaWithScrollBarChildrenIsNotEnriched() {
        // A plain group is not a scroll area, so it never gains a scroll position
        // even if it happens to contain a scrollbar node.
        let group = AXNode(role: kAXGroupRole, children: [verticalScrollBar(0.3)])
        #expect(ScrollEnrichment.enrich(group).scrollPosition == nil)
    }

    @Test func aPreexistingScrollPositionIsNotOverwritten() {
        let area = AXNode(role: kAXScrollAreaRole, isScrollArea: true,
                          scrollPosition: CGPoint(x: 1, y: 2),
                          children: [verticalScrollBar(0.5)])
        #expect(ScrollEnrichment.enrich(area).scrollPosition == CGPoint(x: 1, y: 2))
    }

    @Test func enrichmentReachesTheRenderedJSON() {
        // End-to-end at the model layer: enrich → build snapshot → JSON carries the
        // derived scroll position (the same path VAL-SNAP-014 probes).
        let window = AXNode(role: kAXWindowRole, title: "Doc",
                            frame: CGRect(x: 0, y: 0, width: 300, height: 200), children: [
            scrollArea(content: [AXNode(role: kAXTextAreaRole, value: "body",
                                        frame: CGRect(x: 0, y: 0, width: 280, height: 180),
                                        actionable: true)],
                       scrollBars: [horizontalScrollBar(0.1), verticalScrollBar(0.6)]),
        ])
        let snapshot = Snapshot(roots: ScrollEnrichment.enrich([window]))
        #expect(SnapshotJSON.render(snapshot).contains("\"scrollPosition\":{\"x\":0.1,\"y\":0.6}"))
    }
}
