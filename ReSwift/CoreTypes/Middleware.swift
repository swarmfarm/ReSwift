//
//  Middleware.swift
//  ReSwift
//
//  Created by Benji Encz on 12/24/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

public typealias DispatchFunction = (inout Action) -> Void
public typealias Middleware<State> = (@escaping DispatchFunction, @escaping () -> State?)
    -> (@escaping DispatchFunction) -> DispatchFunction
