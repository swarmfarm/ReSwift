//
//  Action.swift
//  ReSwift
//
//  Created by Benjamin Encz on 12/14/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

/// All actions that want to be able to be dispatched to a store need to conform to this protocol
/// Currently it is just a marker protocol with no requirements.
public protocol Action { }

/// Initial Action that is dispatched as soon as the store is created.
/// Reducers respond to this action by configuring their initial state.
public struct ReSwiftInit: Action {}

/// Default ActionType for BatchStore when no specific action enum is specified.
/// Enables `BatchStore<State>` as shorthand for `BatchStore<State, DefaultStoreAction>`.
public struct DefaultStoreAction: Action {}


public protocol BatchedKeyedAction: Action {
    var batchKey: String { get }
}
