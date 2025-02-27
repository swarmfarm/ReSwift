//
//  Action.swift
//  ReSwift
//

/// All actions that can be dispatched to a store must conform to this protocol.
/// This is a marker protocol with no requirements.
public protocol Action { }

/// An action automatically dispatched when the store is first created.
/// Reducers can respond to configure their initial state.
public struct ReSwiftInit: Action {}
