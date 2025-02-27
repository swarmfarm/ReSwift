//
//  Assertions.swift
//

import Foundation

// One approach is to define a concurrency-safe closure type:
public typealias FatalErrorFunction = @Sendable (String, StaticString, UInt) -> Never

func raiseFatalError(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) -> Never {
    // Since we define `fatalErrorClosure` as a function that must be safe
    // across concurrency boundaries, we are good here:
    Assertions.fatalErrorClosure(message(), file, line)
    repeat {
        RunLoop.current.run()
    } while true
}

/// We can put the logic in a final class or enum. Mark it Sendable if truly no shared mutable state.
public enum Assertions: @unchecked Sendable {
    // Must also be `@Sendable` to be concurrency safe
    public static let fatalErrorClosure: FatalErrorFunction = { message, file, line in
        Swift.fatalError(message, file: file, line: line)
    }
}
