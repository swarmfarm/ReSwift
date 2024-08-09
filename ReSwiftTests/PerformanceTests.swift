//  Copyright © 2019 ReSwift Community. All rights reserved.

import XCTest
import ReSwift

final class PerformanceTests: XCTestCase {
    struct MockState {}
    struct MockAction: Action {}

    let subscribers: [MockSubscriber] = (0..<3000).map { _ in MockSubscriber() }
    let store = Store(
        reducer: { _, state in return state ?? MockState() },
        state: MockState(),
        automaticallySkipsRepeats: false
    )

    class MockSubscriber: StoreSubscriber {
        typealias StoreSubscriberStateType = MockState
        func newState(state: MockState) {
            // Do nothing
        }
    }

    func subscribeAll() {
        self.subscribers.forEach  { subscriber in
            store.subscribe(subscriber) { mockState in
                mockState.select { state in
                        //            block for 20ms
                        usleep(200)
                        return MockState()
                    }
            }
        }
    }
    func testNotify() {
        subscribeAll()
        self.measure {
            self.store.dispatch(MockAction())
        }
    }

    func testSubscribe() {
        self.measure {
            subscribeAll()
        }
    }
}
