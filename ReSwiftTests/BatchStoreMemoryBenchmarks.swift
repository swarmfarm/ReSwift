import XCTest
@testable import ReSwift

final class BatchStoreMemoryBenchmarks: XCTestCase {
    private let blobCount = 256
    private let blobSize = 16 * 1024
    private let iterationCount = 200
    private let subscriberCount = 1_000

    func testBenchmarkLargeActionPayload() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(
                reducer: largeMemoryReducer,
                state: LargeMemoryState.initial(blobCount: blobCount, blobSize: blobSize)
            )

            for offset in 0..<iterationCount {
                store.dispatch(
                    ReplaceLargePayloadAction(
                        payload: makeLargePayload(
                            blobCount: blobCount,
                            blobSize: blobSize,
                            seed: offset
                        )
                    )
                )
            }

            XCTAssertEqual(store.state.version, iterationCount - 1)
        }
    }

    func testBenchmarkLargeStateMutation() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let store = Store(
                reducer: largeMemoryReducer,
                state: LargeMemoryState.initial(blobCount: blobCount, blobSize: blobSize)
            )

            for offset in 0..<iterationCount {
                store.dispatch(MutateSingleBlobAction(index: offset % blobCount, seed: offset))
            }

            XCTAssertEqual(store.state.version, iterationCount - 1)
        }
    }

    func testBenchmarkLargeStateWithProjectedSubscribers() {
        let store = Store(
            reducer: largeMemoryReducer,
            state: LargeMemoryState.initial(blobCount: blobCount, blobSize: blobSize),
            automaticallySkipsRepeats: false
        )
        let subscribers = makeLargeMemorySubscribers(count: subscriberCount)

        subscribers.forEach { subscriber in
            store.subscribe(subscriber) {
                $0.select(\LargeMemoryState.summary)
            }
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for offset in 0..<100 {
                store.dispatch(MutateSingleBlobAction(index: offset % blobCount, seed: offset))
            }
        }

        withExtendedLifetime(subscribers) {}
    }
}

private struct LargeMemoryState: Equatable {
    var payload: [[UInt8]]
    var version: Int

    var summary: Int {
        payload.first?.first.map(Int.init) ?? -1
    }

    static func initial(blobCount: Int, blobSize: Int) -> Self {
        Self(payload: makeLargePayload(blobCount: blobCount, blobSize: blobSize, seed: 0), version: 0)
    }
}

private struct ReplaceLargePayloadAction: Action {
    let payload: [[UInt8]]
}

private struct MutateSingleBlobAction: Action {
    let index: Int
    let seed: Int
}

private func largeMemoryReducer(action: Action, state: inout LargeMemoryState) {
    switch action {
    case let action as ReplaceLargePayloadAction:
        state.payload = action.payload
        state.version = (action.payload.first?.first).map(Int.init) ?? state.version

    case let action as MutateSingleBlobAction:
        var nextPayload = state.payload
        guard nextPayload.indices.contains(action.index) else { return }
        let fill = UInt8(action.seed % 251)
        nextPayload[action.index] = Array(repeating: fill, count: nextPayload[action.index].count)
        state.payload = nextPayload
        state.version = action.seed

    default:
        break
    }
}

private func makeLargePayload(blobCount: Int, blobSize: Int, seed: Int) -> [[UInt8]] {
    let base = UInt8(seed % 251)
    return (0..<blobCount).map { offset in
        let value = UInt8((Int(base) + offset) % 251)
        return Array(repeating: value, count: blobSize)
    }
}

private final class LargeMemoryProjectedSubscriber: StoreSubscriber {
    typealias StoreSubscriberStateType = Int

    func newState(state: Int) {}
}

private func makeLargeMemorySubscribers(count: Int) -> [LargeMemoryProjectedSubscriber] {
    (0..<count).map { _ in LargeMemoryProjectedSubscriber() }
}
