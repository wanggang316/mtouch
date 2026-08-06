import Foundation

/// Hand-rolled JSON fragments (project pattern: byte-stable key order, see
/// `DoctorReport.jsonString`). Any value embedding a user-controlled string
/// must go through `string(_:)`.
enum JSONText {
    /// Quoted, escaped JSON representation of a string.
    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Compact numeric rendering shared by JSON and text output: integral
    /// doubles drop the trailing ".0" (`585.0` -> `585`) so frames read
    /// naturally; fractional values keep their full representation.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
