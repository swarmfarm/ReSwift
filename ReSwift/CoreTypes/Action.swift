//
//  Action.swift
//  ReSwift
//
//  Created by Benjamin Encz on 12/14/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

/// All actions that want to be able to be dispatched to a store need to conform to this protocol.
/// Actions are required to be `Sendable` so stores and middleware can safely move them through
/// `@Sendable` execution paths.
public protocol Action: Sendable { }

/// Initial Action that is dispatched as soon as the store is created.
/// Reducers respond to this action by configuring their initial state.
public struct ReSwiftInit: Action {}

public protocol BatchedKeyedAction: Action {
    var batchKey: String { get }
}
