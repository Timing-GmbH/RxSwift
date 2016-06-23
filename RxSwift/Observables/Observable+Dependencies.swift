//
//  Observable+Dependencies.swift
//  Rx
//
//  Created by Daniel Alm on 22/06/16.
//  Copyright © 2016 Krunoslav Zaher. All rights reserved.
//

import Foundation

public protocol ObservableUsable: class {
    func subscribeAny(on: (event: Event<Any>) -> Void) -> Disposable
}

private func unwrap(any: Any) -> Any? {
    let mirror = Mirror(reflecting: any)
    if mirror.displayStyle != .Optional {
        return any
    }
    
    if mirror.children.count == 0 { return nil }
    let (_, some) = mirror.children.first!
    return some
    
}

public extension ObservableUsable {
    public var observableSources: [ObservableUsable] {
        var result: [ObservableUsable] = []
        let mirror = Mirror(reflecting: self)
        for case let (label?, value) in mirror.children {
            if label.containsString("source"),
                // We need to use unwrap() here to also cover cases where the source variable is an Optional, as just
                // as? could not unwrap that otherwise.
                let observableValue = unwrap(value) as? ObservableUsable {
                result.append(observableValue)
            }
        }
        return result
    }
    
    public var observableSourcesTree: [ObservableUsable] {
        return [self] + observableSources.flatMap { $0.observableSourcesTree }
    }
    
    public var leafSources: [ObservableUsable] {
        return observableSourcesTree.filter { $0.observableSources.isEmpty }
    }
}

extension Observable: ObservableUsable {
    public func subscribeAny(on: (event: Event<Any>) -> Void) -> Disposable {
        return subscribe {
            switch $0 {
            case .Next(let element):
                on(event: .Next(element))
            case .Error(let error):
                on(event: .Error(error))
            case .Completed:
                on(event: .Completed)
            }
        }
    }
}

class Leaf<SourceType>: Producer<SourceType> {
    // This must not be called _source as the whole point of this class is to disguise the observable's "real" source.
    private let _src: Observable<SourceType>
    
    init(source: Observable<SourceType>) {
        _src = source
    }
    
    override func run<O: ObserverType where O.E == SourceType>(observer: O) -> Disposable {
        return _src.subscribe(observer)
    }
}

extension ObservableType {
    @warn_unused_result(message="http://git.io/rxs.uo")
    public func treatAsLeaf() -> Observable<E> {
        return Leaf(source: self.asObservable())
    }
}
