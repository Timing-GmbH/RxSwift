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

private struct PointerEqualityWrapper<T>: Hashable where T: AnyObject {
	let value: T
	
	var hashValue: Int { return ObjectIdentifier(value).hashValue }
	
	static func ==<T>(A: PointerEqualityWrapper<T>, B: PointerEqualityWrapper<T>) -> Bool {
		return A.value === B.value
	}
}

private struct ObservableUsableEqualityWrapper: Hashable {
	let value: ObservableUsable
	
	var hashValue: Int { return ObjectIdentifier(value).hashValue }
	
	static func ==(A: ObservableUsableEqualityWrapper, B: ObservableUsableEqualityWrapper) -> Bool {
		return A.value === B.value
	}
}

public extension Sequence where Iterator.Element == ObservableUsable {
	func deduplicatedByPointer() -> [ObservableUsable] {
		return Array(Set(self.map { ObservableUsableEqualityWrapper(value: $0) }).map { $0.value })
	}
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
		// This is quite a bit faster than `observableSourcesTree.filter { $0.observableSources.isEmpty }`.
		let observableSources = self.observableSources
		if !observableSources.isEmpty {
			return observableSources.flatMap { $0.leafSources }
		} else {
			return [self]
		}
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

// MARK: -
class Leaf<SourceType>: Producer<SourceType> {
    // This must not be called _source as the whole point of this class is to disguise the observable's "real" source.
    private let _src: Observable<SourceType>
    
    init(source: Observable<SourceType>) {
        _src = source
    }
    
    override func run<O: ObserverType>(_ observer: O, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where O.E == SourceType {
		return (sink: Disposables.create(), subscription: Disposables.create(_src.subscribe(observer), cancel))
    }
}

extension ObservableType {
    // @warn_unused_result(message="http://git.io/rxs.uo")
    public func treatAsLeaf() -> Observable<E> {
        return Leaf(source: self.asObservable())
    }
}

// MARK: -
class IndirectDependency<SourceType, DependencyType>: Producer<SourceType> {
	// This must not be called _source as the whole point of this class is to disguise the observable's "real" source.
	private let _source: Observable<SourceType>
	private let _indirectDependencySource: Observable<DependencyType>
	
	init(source: Observable<SourceType>, dependency: Observable<DependencyType>) {
		_source = source
		_indirectDependencySource = dependency
	}
	
	override func run<O: ObserverType>(_ observer: O, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where O.E == SourceType {
		return (sink: Disposables.create(), subscription: Disposables.create(_source.subscribe(observer), cancel))
	}
}

extension ObservableType {
	// @warn_unused_result(message="http://git.io/rxs.uo")
	// When using `debounceDependencies: true`, this causes the leaf dependencies of `dependency` to also count as
	// dependencies for `source`.
	public func withIndirectDependency<DependencyType>(_ dependency: Observable<DependencyType>) -> Observable<E> {
		return IndirectDependency(source: self.asObservable(), dependency: dependency)
	}
}
