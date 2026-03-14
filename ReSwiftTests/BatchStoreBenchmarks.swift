import XCTest
@testable import ReSwift

final class BatchStoreBenchmarks: XCTestCase {
    private let actionCount = 10_000
    private let reducerCount = 128
    private let subscriberCount = 3_000

    func testBenchmarkManyActions() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(reducer: appReducer, state: TestAppState())

            for offset in 0..<actionCount {
                store.dispatch(SetValueAction(value: offset))
            }

            XCTAssertEqual(store.state.testValue, actionCount - 1)
        }
    }

    func testBenchmarkManyReducers() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(
                reducer: makeCompositeReducer(reducerCount: reducerCount),
                state: BenchmarkState.reducerHeavy(count: reducerCount)
            )

            for seed in 0..<1_000 {
                store.dispatch(BenchmarkReducerAction(seed: seed))
            }

            XCTAssertEqual(store.state.sections.count, reducerCount)
        }
    }

    func testBenchmarkManySubscribersUsingSelect() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(
                reducer: appReducer,
                state: TestAppState(),
                automaticallySkipsRepeats: false
            )
            let subscribers = makeProjectedSubscribers(count: subscriberCount)

            for subscriber in subscribers {
                store.subscribe(subscriber) {
                    $0.select(\TestAppState.testValue)
                }
            }

            XCTAssertEqual(store.subscriptions.count, subscriberCount)
            withExtendedLifetime(subscribers) {}
        }
    }

    func testBenchmarkDispatchToManySelectedSubscribersSequential() {
        let store = Store(
            reducer: appReducer,
            state: TestAppState(),
            automaticallySkipsRepeats: false
        )
        let subscribers = makeProjectedSubscribers(count: subscriberCount)
        subscribers.forEach { subscriber in
            store.subscribe(subscriber) {
                $0.select(\TestAppState.testValue)
            }
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<250 {
                store.dispatch(SetValueAction(value: offset), concurrent: false)
            }
        }

        withExtendedLifetime(subscribers) {}
    }

    func testBenchmarkDispatchToManySelectedSubscribersConcurrent() {
        let store = Store(
            reducer: appReducer,
            state: TestAppState(),
            automaticallySkipsRepeats: false
        )
        let subscribers = makeProjectedSubscribers(count: subscriberCount)
        subscribers.forEach { subscriber in
            store.subscribe(subscriber) {
                $0.select(\TestAppState.testValue)
            }
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<250 {
                store.dispatch(SetValueAction(value: offset), concurrent: true)
            }
        }

        withExtendedLifetime(subscribers) {}
    }
}

private struct BenchmarkState: Equatable {
    var sections: [Int]
    var checksum: Int

    static func reducerHeavy(count: Int) -> Self {
        Self(sections: Array(repeating: 0, count: count), checksum: 0)
    }
}

private struct BenchmarkReducerAction: Action {
    let seed: Int
}

private func makeCompositeReducer(reducerCount: Int) -> Reducer<BenchmarkState> {
    let reducers: [Reducer<BenchmarkState>] = (0..<reducerCount).map { index in
        { action, state in
            guard let action = action as? BenchmarkReducerAction else { return }
            state.sections[index] = (state.sections[index] + action.seed + index) % 10_000
            state.checksum = (state.checksum &+ state.sections[index]) % 1_000_000
        }
    }

    return { action, state in
        for reducer in reducers {
            reducer(action, &state)
        }
    }
}

private final class BenchmarkProjectedSubscriber: StoreSubscriber {
    typealias StoreSubscriberStateType = Int?

    func newState(state: Int?) {}
}

private func makeProjectedSubscribers(count: Int) -> [BenchmarkProjectedSubscriber] {
    (0..<count).map { _ in BenchmarkProjectedSubscriber() }
}
