//
//  DispatchingStoreType.swift
//  ReSwift
//

/// A minimal protocol that provides dispatch functionality without exposing state.
public protocol DispatchingStoreType {
    /// Dispatches an action to the store.
    func dispatch(_ action: any Action)
}
