import ArgumentParser
import Foundation
import MTouchKit

// MARK: - Shared --app option groups

struct RequiredAppOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Bundle identifier of the target application.", valueName: "bundleId"))
    var app: String

    mutating func validate() throws {
        guard !app.isEmpty else {
            throw ValidationError("--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'.")
        }
    }
}

struct OptionalAppOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Bundle identifier of the target application.", valueName: "bundleId"))
    var app: String?

    mutating func validate() throws {
        if let app, app.isEmpty {
            throw ValidationError("--app value must not be empty; pass a bundle identifier such as 'com.apple.Safari'.")
        }
    }
}

// MARK: - Argument conversions for MTouchKit value types

extension ScreenPoint: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

extension WaitDuration: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(parsing: argument)
    }
}

// MARK: - Stub exit

/// Placeholder body for subcommands whose behavior lands in later features.
func stubExit(_ commandPath: String) -> Never {
    FileHandle.standardError.write(Data("mtouch: \(commandPath): not implemented\n".utf8))
    exit(MTouchExitCode.runtimeFailure.rawValue)
}
