/// Environment variable names reserved for mtouch sessions.
public enum MTouchEnvironment {
    public static let sessionKey = "MTOUCH_SESSION"
    public static let trajectoryKey = "MTOUCH_TRAJECTORY"
    /// Directory of the run evidence bundle every command appends to. Also
    /// settable per invocation with `--run-dir`.
    public static let runDirKey = "MTOUCH_RUN_DIR"
    /// Opt-in per-step screenshots inside the run bundle (`1`/`true`/`yes`).
    /// Also settable per invocation with `--capture`. Off by default because a
    /// capture costs real time on every action.
    public static let runCaptureKey = "MTOUCH_RUN_CAPTURE"
    /// Optional human label recorded once in the bundle's `run.json`.
    public static let runLabelKey = "MTOUCH_RUN_LABEL"
}

/// The mtouch release version stamped into the artifacts an operator reads back
/// (currently a run bundle's `run.json`), so a bundle names the binary that
/// produced it.
public enum MTouchVersion {
    public static let current = "0.2.0"
}
