import XCTest
@testable import ReSwift

final class BatchStoreSubscriptionTests: XCTestCase {
    func testSubscriberReceivesCurrentStateOnSubscribe() {
        let store = Store(reducer: appReducer, state: TestAppState(testValue: 7))
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [7])
    }

    func testLateSubscriberReceivesLatestState() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<TestAppState>()

        store.dispatch(SetValueAction(value: 13))
        store.subscribe(subscriber)

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [13])
    }

    func testUnsubscribeStopsFutureUpdates() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(value: 5))
        store.unsubscribe(subscriber)
        store.dispatch(SetValueAction(value: 8))

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [nil, 5])
    }

    func testDuplicateSubscriptionCreatesMultipleNotificationsWithCurrentImplementation() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)
        store.subscribe(subscriber)
        store.dispatch(SetValueAction(value: 3))

        XCTAssertEqual(store.subscriptions.count, 2)
        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [nil, nil, 3, 3])
    }

    func testDeallocatedSubscriberIsNotRetainedAndRemovedOnNotify() {
        let store = Store(reducer: appReducer, state: TestAppState())
        weak var weakSubscriber: RecordingSubscriber<TestAppState>?

        autoreleasepool {
            let subscriber = RecordingSubscriber<TestAppState>()
            weakSubscriber = subscriber
            store.subscribe(subscriber)
            XCTAssertEqual(store.subscriptions.count, 1)
        }

        XCTAssertNil(weakSubscriber)

        store.dispatch(SetValueAction(value: 4))

        XCTAssertEqual(store.subscriptions.count, 0)
    }

    func testSubscriberAddedDuringNotificationIsPreserved() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let lateSubscriber = RecordingSubscriber<TestAppState>()

        let subscriber = ClosureSubscriber<TestAppState> { state in
            if state.testValue == 1 {
                store.subscribe(lateSubscriber) {
                    $0.skip { _, _ in true }
                }
            }
        }

        store.subscribe(subscriber) {
            $0.only { _, new in new.testValue == 1 }
        }

        store.dispatch(SetValueAction(value: 1))

        XCTAssertEqual(store.subscriptions.count, 2)
        XCTAssertEqual(lateSubscriber.receivedStates.map(\.testValue), [1])
    }

    func testDispatchWithinSubscriberIsAllowed() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = DispatchingSubscriber(store: store)

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(value: 2))

        XCTAssertEqual(store.state.testValue, 5)
    }

    func testNestedDispatchResumesOuterNotificationWithOriginalStateSnapshot() {
        let store = Store(reducer: appReducer, state: TestAppState())
        var didDispatchFollowUp = false
        var secondSubscriberValues: [Int?] = []

        let firstSubscriber = ClosureSubscriber<TestAppState> { state in
            guard state.testValue == 1, !didDispatchFollowUp else { return }
            didDispatchFollowUp = true
            store.dispatchSync(SetValueAction(value: 2))
        }
        let secondSubscriber = ClosureSubscriber<TestAppState> { state in
            secondSubscriberValues.append(state.testValue)
        }

        store.subscribe(firstSubscriber)
        store.subscribe(secondSubscriber)

        store.dispatch(SetValueAction(value: 1))

        XCTAssertEqual(secondSubscriberValues, [nil, 2, 1])
    }

    func testSubscriberCanUnsubscribeItselfDuringNotification() {
        let store = Store(reducer: appReducer, state: TestAppState())
        var subscriber: ClosureSubscriber<TestAppState>?
        var receivedValues: [Int?] = []

        subscriber = ClosureSubscriber<TestAppState> { state in
            receivedValues.append(state.testValue)
            if state.testValue == 1, let subscriber {
                store.unsubscribe(subscriber)
            }
        }

        store.subscribe(subscriber!)
        store.dispatch(SetValueAction(value: 1))
        store.dispatch(SetValueAction(value: 2))

        XCTAssertEqual(receivedValues, [nil, 1])
        XCTAssertEqual(store.subscriptions.count, 0)
    }

    func testClosureSelectionForwardsProjectedState() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<Int?>()

        store.subscribe(subscriber) {
            $0.select { $0.testValue }
        }

        store.dispatch(SetValueAction(value: 3))
        store.dispatch(SetValueAction(value: nil))

        XCTAssertEqual(subscriber.receivedStates, [nil, 3, nil])
    }

    func testKeyPathSelectionForwardsProjectedState() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<String>()

        store.subscribe(subscriber) {
            $0.select(\TestAppState.label)
        }

        store.dispatch(SetLabelAction(value: "Updated"))

        XCTAssertEqual(subscriber.receivedStates, ["Initial", "Updated"])
    }

    func testExplicitSkipRepeatsSkipsEqualProjectedValues() {
        let store = Store(reducer: appReducer, state: TestAppState(testValue: 3))
        let subscriber = RecordingSubscriber<Int?>()

        store.subscribe(subscriber) {
            $0.select(\TestAppState.testValue).skipRepeats { $0 == $1 }
        }

        store.dispatch(SetValueAction(value: 3))
        store.dispatch(SetValueAction(value: 4))

        XCTAssertEqual(subscriber.receivedStates, [3, 4])
    }

    func testSkipConvenienceFiltersProjectedState() {
        let store = Store(reducer: appReducer, state: TestAppState(nested: NestedState(value: 5)))
        let subscriber = RecordingSubscriber<NestedState>()

        store.subscribe(subscriber) {
            $0.select(\TestAppState.nested).skip { $0.value == $1.value }
        }

        store.dispatch(SetNestedValueAction(value: 5))
        store.dispatch(SetNestedValueAction(value: 6))

        XCTAssertEqual(subscriber.receivedStates.map(\.value), [5, 6])
    }

    func testOnlyConvenienceForwardsMatchingChanges() {
        let store = Store(reducer: appReducer, state: TestAppState())
        let subscriber = RecordingSubscriber<NestedState>()

        store.subscribe(subscriber) {
            $0.select(\TestAppState.nested).only { $0.value != $1.value }
        }

        store.dispatch(SetNestedValueAction(value: 0))
        store.dispatch(SetNestedValueAction(value: 7))

        XCTAssertEqual(subscriber.receivedStates.map(\.value), [0, 7])
    }

    func testEquatableSubstateAutomaticallySkipsRepeats() {
        let store = Store(reducer: appReducer, state: TestAppState(label: "Same"))
        let subscriber = RecordingSubscriber<String>()

        store.subscribe(subscriber) {
            $0.select(\TestAppState.label)
        }

        store.dispatch(SetLabelAction(value: "Same"))
        store.dispatch(SetLabelAction(value: "New"))

        XCTAssertEqual(subscriber.receivedStates, ["Same", "New"])
    }

    func testEquatableStateAutomaticallySkipsRepeats() {
        let state = TestAppState(testValue: 1, label: "State")
        let store = Store(reducer: appReducer, state: state)
        let subscriber = RecordingSubscriber<TestAppState>()

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(value: 1))
        store.dispatch(SetValueAction(value: 2))

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [1, 2])
    }

    func testDisablingAutomaticSkipRepeatsAllowsDuplicateEquatableNotifications() {
        let store = Store(
            reducer: appReducer,
            state: TestAppState(label: "Same"),
            middleware: [],
            automaticallySkipsRepeats: false
        )
        let subscriber = RecordingSubscriber<String>()

        store.subscribe(subscriber) {
            $0.select(\TestAppState.label)
        }

        store.dispatch(SetLabelAction(value: "Same"))

        XCTAssertEqual(subscriber.receivedStates, ["Same", "Same"])
    }

    func testNonEquatableSelectionDoesNotAutomaticallySkipRepeats() {
        let store = Store(reducer: nonEquatableReducer, state: TestNonEquatableState())
        let subscriber = RecordingSubscriber<NonEquatablePayload>()

        store.subscribe(subscriber) {
            $0.select(\TestNonEquatableState.payload)
        }

        store.dispatch(SetNonEquatableAction(value: "Initial"))

        XCTAssertEqual(subscriber.receivedStates.map(\.value), ["Initial", "Initial"])
    }
}
