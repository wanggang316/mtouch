/// The opt-in "deliver without verification" mode shared by the `act` verbs that
/// synthesize input.
///
/// mtouch's whole value is that an action returns EVIDENCE: it walks the target's
/// accessibility tree before and after the action and reports the diff, so an
/// agent never has to assume its input landed. A modal panel breaks that contract
/// from the other side — it runs a nested event loop that blocks the owning
/// application's accessibility server, so every read of the tree times out and
/// mtouch (correctly) refuses to act on what it cannot verify. The panel is still
/// there and still driveable: keystrokes and clicks are delivered through
/// CGEvent, which needs no accessibility tree at all.
///
/// `--no-verify` is the explicit way to say so. It skips both walks, delivers the
/// input, and reports — in place of the diff — that nothing was verified. That
/// notice is the entire safety story of the mode: it knowingly trades away the
/// evidence mtouch exists to produce, so it must never be mistaken for a verified
/// action. Both surfaces render the SAME notice, and the trajectory record marks
/// the delivery with a dedicated `verified: false` field rather than a prose hint.
public enum UnverifiedDelivery {
    /// The verbs that accept the flag. Each one synthesizes input through CGEvent
    /// and resolves no element reference, so it needs no accessibility read to do
    /// its work. The ref verbs (`press`/`focus`/`show-menu`/`set-value`) and
    /// `menu` are absent deliberately: they LOCATE their target by reading the
    /// tree, so for them "skip the read" is not a weaker contract but an
    /// impossible one.
    public static let verbs = [
        "type", "key", "click", "rightclick", "doubleclick", "drag", "scroll",
    ]

    /// Printed on stdout WHERE THE DIFF WOULD NORMALLY GO, so an agent that reads
    /// the action's output for its effect is told plainly that there is none to
    /// read — never a blank line, and never something that parses as a diff.
    public static let notice = "delivered without verification (no accessibility diff was taken)"

    /// The `--json` form of the notice. `verified` is the field a consumer keys
    /// off; `note` repeats the human sentence so a log stays readable.
    public static let noticeJSON =
        "{\"delivered\":true,\"verified\":false,\"note\":\(JSONText.string(notice))}"

    /// The notice in the caller's chosen rendering — the single source both the
    /// CLI and the MCP surface print, so their payloads stay byte-identical.
    public static func rendered(json: Bool) -> String { json ? noticeJSON : notice }

    /// The pinned refusal when the flag reaches a ref verb. It names WHY the verb
    /// cannot honour it and which verbs can, so the agent's next call is right
    /// rather than another guess.
    public static let refVerbRefusal =
        "--no-verify is not accepted by the ref verbs (press, focus, show-menu, set-value): each one "
            + "locates its target by reading the accessibility tree, so it cannot skip that read. It "
            + "applies to the verbs that synthesize input directly: " + verbList + "."

    /// The pinned refusal when the flag reaches `act menu`, which walks the menu
    /// bar over the accessibility API to find the command it was asked for.
    public static let menuRefusal =
        "--no-verify is not accepted by 'act menu': it walks the menu bar over the accessibility API "
            + "to find the command, so it cannot skip that read. It applies to the verbs that "
            + "synthesize input directly: " + verbList + "."

    private static let verbList = verbs.joined(separator: ", ")
}
