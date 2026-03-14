import XCTest
@testable import ReSwift

final class BatchStoreBenchmarks: XCTestCase {
    private let actionCount = 10_000
    private let reducerCount = 128
    private let veryHighReducerCount = 512
    private let subscriberCount = 3_000
    private let middlewareActionCount = 20_000

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

    func testBenchmarkVeryManyReducers() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(
                reducer: makeCompositeReducer(reducerCount: veryHighReducerCount),
                state: BenchmarkState.reducerHeavy(count: veryHighReducerCount)
            )

            for seed in 0..<500 {
                store.dispatch(BenchmarkReducerAction(seed: seed))
            }

            XCTAssertEqual(store.state.sections.count, veryHighReducerCount)
        }
    }

    func testBenchmarkManyActionsThroughManyReducers() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(
                reducer: makeCompositeReducer(reducerCount: reducerCount),
                state: BenchmarkState.reducerHeavy(count: reducerCount)
            )

            for seed in 0..<actionCount {
                store.dispatch(BenchmarkReducerAction(seed: seed))
            }

            XCTAssertGreaterThan(store.state.checksum, 0)
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

    func testBenchmarkManyReducersAndManySelectedSubscribers() {
        let store = Store(
            reducer: makeSelectFriendlyCompositeReducer(reducerCount: reducerCount),
            state: BenchmarkSubscriberState.reducerHeavy(count: reducerCount),
            automaticallySkipsRepeats: false
        )
        let subscribers = makeProjectedReducerSubscribers(count: subscriberCount)
        subscribers.forEach { subscriber in
            store.subscribe(subscriber) {
                $0.select(\BenchmarkSubscriberState.headlineValue)
            }
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for seed in 0..<250 {
                store.dispatch(BenchmarkSubscriberAction(seed: seed), concurrent: false)
            }
        }

        withExtendedLifetime(subscribers) {}
    }

    func testBenchmarkMiddlewarePassThroughSingle() {
        let store = Store(
            reducer: middlewareBenchmarkReducer,
            state: MiddlewareBenchmarkState(),
            middleware: makePassThroughMiddleware(count: 1)
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<middlewareActionCount {
                store.dispatch(MiddlewareBenchmarkAction(value: offset))
            }
        }

        XCTAssertEqual(store.state.value, middlewareActionCount - 1)
    }

    func testBenchmarkMiddlewarePassThroughMany() {
        let store = Store(
            reducer: middlewareBenchmarkReducer,
            state: MiddlewareBenchmarkState(),
            middleware: makePassThroughMiddleware(count: 8)
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<middlewareActionCount {
                store.dispatch(MiddlewareBenchmarkAction(value: offset))
            }
        }

        XCTAssertEqual(store.state.value, middlewareActionCount - 1)
    }

    func testBenchmarkMiddlewareReadsState() {
        let reader: DefaultMiddleware<MiddlewareBenchmarkState> = { action, context in
            _ = context.getState()?.label
            context.next(action)
        }
        let store = Store(
            reducer: middlewareBenchmarkReducer,
            state: MiddlewareBenchmarkState(),
            middleware: [reader]
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<middlewareActionCount {
                store.dispatch(MiddlewareBenchmarkAction(value: offset))
            }
        }

        XCTAssertEqual(store.state.value, middlewareActionCount - 1)
    }

    func testBenchmarkMiddlewareDispatchesAdditionalAction() {
        let middleware: DefaultMiddleware<MiddlewareBenchmarkState> = { action, context in
            if let action = action as? MiddlewareBenchmarkAction {
                context.dispatch(MiddlewareBenchmarkSideEffectAction(value: action.value))
            }
            context.next(action)
        }
        let store = Store(
            reducer: middlewareBenchmarkReducer,
            state: MiddlewareBenchmarkState(),
            middleware: [middleware]
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<10_000 {
                store.dispatch(MiddlewareBenchmarkAction(value: offset))
            }
        }

        XCTAssertEqual(store.state.value, 9_999)
        XCTAssertEqual(store.state.sideEffectCount, 10_000)
    }

    func testBenchmarkTypedStoreMiddlewarePassThrough() {
        let middleware: Middleware<MiddlewareBenchmarkState, MiddlewareBenchmarkAction> = { action, context in
            context.next(action)
        }
        let store = BatchStore<MiddlewareBenchmarkState, MiddlewareBenchmarkAction>(
            reducer: typedMiddlewareBenchmarkReducer,
            state: MiddlewareBenchmarkState(),
            middleware: [middleware]
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<middlewareActionCount {
                store.dispatch(MiddlewareBenchmarkAction(value: offset))
            }
        }

        XCTAssertEqual(store.state.value, middlewareActionCount - 1)
    }
}

private struct BenchmarkState: Equatable, Sendable {
    var sections: [Int]
    var checksum: Int

    static func reducerHeavy(count: Int) -> Self {
        Self(sections: Array(repeating: 0, count: count), checksum: 0)
    }
}

private struct BenchmarkReducerAction: Action {
    let seed: Int
}

private struct BenchmarkSubscriberState: Equatable, Sendable {
    var sections: [Int]

    var headlineValue: Int? {
        sections.first
    }

    static func reducerHeavy(count: Int) -> Self {
        Self(sections: Array(repeating: 0, count: count))
    }
}

private struct BenchmarkSubscriberAction: Action {
    let seed: Int
}

private struct MiddlewareBenchmarkState: Equatable, Sendable {
    var value: Int = 0
    var label: String = ""
    var sideEffectCount: Int = 0
}

private struct MiddlewareBenchmarkAction: Action {
    let value: Int
}

private struct MiddlewareBenchmarkSideEffectAction: Action {
    let value: Int
}

private func makeCompositeReducer(reducerCount: Int) -> DefaultReducer<BenchmarkState> {
    let reducers: [DefaultReducer<BenchmarkState>] = (0..<reducerCount).map { index in
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

private func makeSelectFriendlyCompositeReducer(reducerCount: Int) -> DefaultReducer<BenchmarkSubscriberState> {
    let reducers: [DefaultReducer<BenchmarkSubscriberState>] = (0..<reducerCount).map { index in
        { action, state in
            guard let action = action as? BenchmarkSubscriberAction else { return }
            state.sections[index] = (state.sections[index] + action.seed + index) % 10_000
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

private final class BenchmarkReducerProjectedSubscriber: StoreSubscriber {
    typealias StoreSubscriberStateType = Int?

    func newState(state: Int?) {}
}

private func makeProjectedReducerSubscribers(count: Int) -> [BenchmarkReducerProjectedSubscriber] {
    (0..<count).map { _ in BenchmarkReducerProjectedSubscriber() }
}

private func middlewareBenchmarkReducer(action: any Action, state: inout MiddlewareBenchmarkState) {
    switch action {
    case let action as MiddlewareBenchmarkAction:
        state.value = action.value
        state.label = "\(action.value)"
    case let action as MiddlewareBenchmarkSideEffectAction:
        state.sideEffectCount = action.value + 1
    default:
        break
    }
}

private func typedMiddlewareBenchmarkReducer(
    action: MiddlewareBenchmarkAction,
    state: inout MiddlewareBenchmarkState
) {
    state.value = action.value
    state.label = "\(action.value)"
}

private func makePassThroughMiddleware(count: Int) -> [DefaultMiddleware<MiddlewareBenchmarkState>] {
    (0..<count).map { _ in
        { action, context in
            context.next(action)
        }
    }
}
