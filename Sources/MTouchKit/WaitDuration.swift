/// Minimal placeholder for wait durations: a plain decimal number of seconds
/// (e.g. `5` or `2.5`). The full duration grammar lands with the wait feature.
public struct WaitDuration: Equatable, Sendable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public init?(parsing string: String) {
        guard let seconds = Double(string), seconds >= 0 else { return nil }
        self.init(seconds: seconds)
    }
}
