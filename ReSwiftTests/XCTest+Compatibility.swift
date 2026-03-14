//  Copyright © 2019 ReSwift Community. All rights reserved.

import XCTest

func dispatchAsync(execute work: @escaping @convention(block) () -> Swift.Void) {
    DispatchQueue.global(qos: .default).async(execute: work)
}

func dispatchUserInitiatedAsync
    (execute work: @escaping @convention(block) () -> Swift.Void) {
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
}

@MainActor
extension XCTestCase {

    func futureExpectation(withDescription description: String) -> XCTestExpectation {
        expectation(description: description)
    }

    func waitForFutureExpectations(
        withTimeout timeout: TimeInterval,
        handler: (@Sendable ((any Error)?) -> Void)? = nil) {
        waitForExpectations(timeout: timeout, handler: handler)
    }
}
