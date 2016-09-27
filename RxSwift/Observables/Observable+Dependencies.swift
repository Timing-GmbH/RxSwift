//
//  Observable+Dependencies.swift
//  Rx
//
//  Created by Daniel Alm on 22/06/16.
//  Copyright © 2016 Krunoslav Zaher. All rights reserved.
//

import Foundation

public protocol ObservableUsable: class {
    func subscribeAny(_ on: @escaping (Event<Any>) -> Void) -> Disposable
}

private func unwrap(_ any: Any) -> Any? {
    let mirror = Mirror(reflecting: any)
    if mirror.displayStyle != .optional {
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
            if label.contains("source") || label.contains("first") || label.contains("pauser"),
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
    public func subscribeAny(_ on: @escaping (Event<Any>) -> Void) -> Disposable {
        return subscribe {
            switch $0 {
            case .next(let element):
                on(.next(element))
            case .error(let error):
                on(.error(error))
            case .completed:
                on(.completed)
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
    
    override func run<O: ObserverType>(_ observer: O) -> Disposable where O.E == SourceType {
        return _src.subscribe(observer)
    }
}

extension ObservableType {
    // @warn_unused_result(message="http://git.io/rxs.uo")
    public func treatAsLeaf() -> Observable<E> {
        return Leaf(source: self.asObservable())
    }
}
