import Testing
@testable import MTouchKit

@Suite struct AXSupportTests {
    /// The KEY regression guard for the soft-bound `_AXUIElementGetWindow`:
    /// HIServices is loaded during `swift test` on macOS, so the dlsym lookup
    /// MUST resolve here. A false means the symbol name is wrong and the runtime
    /// binding is dead — every `windowID(of:)` would silently degrade to nil.
    /// Kept hermetic: no real AXUIElement/window (that needs TCC); the `?? index`
    /// fallback callers are already covered by the WindowEnumeration tests.
    @Test func windowResolverIsBoundOnTheTestHost() {
        #expect(AXSupport.windowResolverIsBound)
    }
}
