//
//  SubscriptionBox.swift
//  ReSwift
//

import Foundation

/**
 A box around subscriptions and subscribers. It erases the type of
 the transformed subscription while still allowing oldState -> newState calls.
 */
class SubscriptionBox<State>: Hashable {
    
    private let originalSubscription: Subscription<State>
    weak var subscriber: AnyStoreSubscriber?
    let id: UUID
    
    init<T>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber
    ) {
        self.originalSubscription = originalSubscription
        self.subscriber = subscriber
        self.id = UUID()
        
        if let transformedSubscription = transformedSubscription {
            // If a transformed subscription was provided, forward its updates to the subscriber
            transformedSubscription.observer = { [weak self] _, newState in
                self?.subscriber?._newState(state: newState)
            }
        } else {
            // Otherwise, forward the original subscription updates
            originalSubscription.observer = { [weak self] _, newState in
                self?.subscriber?._newState(state: newState)
            }
        }
    }
    
    func newValues(oldState: borrowing State?, newState: borrowing State) {
        // The original subscription notifies the chain
        self.originalSubscription.newValues(oldState: oldState, newState: newState)
    }
    
    // MARK: Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: SubscriptionBox<State>, rhs: SubscriptionBox<State>) -> Bool {
        lhs.id == rhs.id
    }
}
