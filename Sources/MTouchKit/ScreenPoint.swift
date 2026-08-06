import Foundation

/// A screen coordinate expressed on the command line as `x,y` (e.g. `120,64.5`).
public struct ScreenPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Parses the `x,y` grammar: exactly two comma-separated numbers,
    /// optional surrounding whitespace per component.
    public init?(parsing string: String) {
        let components = string.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2,
              let x = Double(components[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(components[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        self.init(x: x, y: y)
    }
}
