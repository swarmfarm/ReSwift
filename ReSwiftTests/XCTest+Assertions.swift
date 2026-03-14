//
//  Assertions
//  Copyright © 2015 mohamede1945. All rights reserved.
//  https://github.com/mohamede1945/AssertionsTestingExample
//

import Foundation
import XCTest
/**
 @testable import for testing of `Assertions.fatalErrorClosure`
 */
@testable import ReSwift

private let noReturnFailureWaitTime = 0.1

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
public extension XCTestCase {
    /**
     Expects an `fatalError` to be called.
     If `fatalError` not called, the test case will fail.

     - parameter expectedMessage: The expected message to be asserted to the one passed to the
     `fatalError`. If nil, then ignored.
     - parameter file:            The file name that called the method.
     - parameter line:            The line number that called the method.
     - parameter testCase:        The test case to be executed that expected to fire the assertion
     method.
     */
    func expectFatalError(expectedMessage: String? = nil, file: StaticString = #file,
                          line: UInt = #line, testCase: @escaping () -> Void) {
        expectAssertionNoReturnFunction(
            functionName: "fatalError",
            file: file,
            line: line,
            function: { (caller: @escaping @Sendable (String) -> Void) -> Void in
                Assertions.fatalErrorClosure = { message, _, _ in caller(message) }
        },
            expectedMessage: expectedMessage,
            testCase: testCase,
            cleanUp: {
                Assertions.fatalErrorClosure = Assertions.swiftFatalErrorClosure
        })
    }

    // MARK: Private Methods

    // swiftlint:disable function_parameter_count
    private func expectAssertionNoReturnFunction(
        functionName funcName: String,
        file: StaticString,
        line: UInt,
        function: (_ caller: @escaping @Sendable (String) -> Void) -> Void,
        expectedMessage: String? = nil,
        testCase: @escaping () -> Void,
        cleanUp: @escaping @Sendable () -> Void) {

        let asyncExpectation = futureExpectation(withDescription: funcName + "-Expectation")
        let assertionMessage = LockedValue<String?>(nil)

        function { (message) -> Void in
            assertionMessage.set(message)
            asyncExpectation.fulfill()
        }

        // act, perform on separate thread because a call to function runs forever
        dispatchUserInitiatedAsync(execute: testCase)

        waitForFutureExpectations(withTimeout: noReturnFailureWaitTime) { _ in
            defer { cleanUp() }
            guard let assertionMessage = assertionMessage.get() else {
                XCTFail(funcName + " is expected to be called.", file: file, line: line)
                return
            }
            if let expectedMessage = expectedMessage {
                XCTAssertEqual(assertionMessage, expectedMessage, funcName +
                    " called with incorrect message.", file: file, line: line)
            }
        }
    }
    // swiftlint:enable function_parameter_count
}
