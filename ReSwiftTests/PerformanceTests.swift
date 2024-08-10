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
                        usleep(20)
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



final class PerformanceTestsBatch: XCTestCase {
    struct MockState {}
    struct MockAction: Action {}

    let subscribers: [MockSubscriber] = (0..<3000).map { _ in MockSubscriber() }
    let store = BatchStore(
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
                        usleep(20)
                        return MockState()
                    }
            }
        }
    }
    func testNotify() {
        subscribeAll()
        self.measure {
            self.store.dispatch(MockAction(), concurrent: true)
        }
    }

    func testSubscribe() {
        self.measure {
            subscribeAll()
        }
    }
    
    
    func testPerformanceComparison() {
            let iterations = 1
            subscribeAll()
            let method1Time = measureExecutionTime(iterations: iterations) {
               self.store.dispatch(MockAction(), concurrent: true)
            }

            let method2Time = measureExecutionTime(iterations: iterations) {
               self.store.dispatch(MockAction(), concurrent: false)
            }

            let speedup = method2Time / method1Time
            print("Method 1 average time: \(method1Time) seconds")
            print("Method 2 average time: \(method2Time) seconds")
            print("Method 1 is \(speedup)x faster than Method 2")

            // Optional: Add an assertion to ensure a minimum speedup
            XCTAssertGreaterThan(speedup, 1.5, "Method 1 should be at least 1.5x faster than Method 2")
       }
       
       func measureExecutionTime(iterations: Int, for block: () -> Void) -> Double {
           let startTime = CFAbsoluteTimeGetCurrent()
           
           for _ in 0..<iterations {
               block()
           }
           
           let endTime = CFAbsoluteTimeGetCurrent()
           let totalTime = endTime - startTime
           
           return totalTime / Double(iterations)
       }

}
