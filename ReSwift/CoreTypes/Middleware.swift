//
//  Middleware.swift
//  ReSwift
//
//  Created by Benji Encz on 12/24/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

public typealias DispatchFunction =  @Sendable (Action) async -> Void
public typealias Middleware<State> =  @Sendable (@escaping @Sendable DispatchFunction, @escaping @Sendable () async -> State?)
    ->  @Sendable (@escaping  @Sendable DispatchFunction) -> DispatchFunction
