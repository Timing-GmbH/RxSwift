//
//  CombineLatest+Collection.swift
//  Rx
//
//  Created by Krunoslav Zaher on 8/29/15.
//  Copyright © 2015 Krunoslav Zaher. All rights reserved.
//

import Foundation

class CombineLatestCollectionTypeSink<C: Collection, R, O: ObserverType>
    : Sink<O> where C.Iterator.Element : ObservableConvertibleType, O.E == R {
    typealias Parent = CombineLatestCollectionType<C, R>
    typealias SourceElement = C.Iterator.Element.E
    
    let _parent: Parent
    
    let _lock = NSRecursiveLock()

    // state
    var _numberOfValues = 0
    var _values: [SourceElement?]
    var _isDone: [Bool]
    var _numberOfDone = 0
    var _subscriptions: [SingleAssignmentDisposable]
    var _eraseSubscriptions: [Disposable]
    
    init(parent: Parent, observer: O) {
        _parent = parent
        _values = [SourceElement?](repeating: nil, count: parent._count)
        _isDone = [Bool](repeating: false, count: parent._count)
        _subscriptions = Array<SingleAssignmentDisposable>()
        _subscriptions.reserveCapacity(parent._count)
        
        for _ in 0 ..< parent._count {
            _subscriptions.append(SingleAssignmentDisposable())
        }
        
        _eraseSubscriptions = (0 ..< parent._count).map { _ in NopDisposable() }
        
        super.init(observer: observer)
    }
    
    func on(_ event: Event<SourceElement>, atIndex: Int) {
        _lock.lock(); defer { _lock.unlock() } // {
            switch event {
            case .next(let element):
                if _values[atIndex] == nil {
                   _numberOfValues += 1
                }
                
                _values[atIndex] = element
                
                if _numberOfValues < _parent._count {
                    let numberOfOthersThatAreDone = self._numberOfDone - (_isDone[atIndex] ? 1 : 0)
                    if numberOfOthersThatAreDone == self._parent._count - 1 {
                        forwardOn(.completed)
                        dispose()
                    }
                    return
                }
                
                do {
                    let result = try _parent._resultSelector(_values.map { $0! })
                    forwardOn(.next(result))
                }
                catch let error {
                    forwardOn(.error(error))
                    dispose()
                }
                
            case .error(let error):
                forwardOn(.error(error))
                dispose()
            case .completed:
                if _isDone[atIndex] {
                    return
                }
                
                _isDone[atIndex] = true
                _numberOfDone += 1
                
                if _numberOfDone == self._parent._count {
                    forwardOn(.completed)
                    dispose()
                }
                else {
                    _subscriptions[atIndex].dispose()
                    _eraseSubscriptions[atIndex].dispose()
                }
            }
        // }
    }
    
    func erase(_ index: Int) {
        _lock.lock(); defer { _lock.unlock() }
        if _isDone[index] {
            return
        }
        
        if _values[index] != nil {
            _values[index] = nil
            _numberOfValues -= 1
        }
    }
    
    func run(debounceDependencies: Bool) -> Disposable {
        var j = 0
        for i in _parent._sources {
            let index = j
            let source = i.asObservable()
            
            if debounceDependencies {
                var extraDisposables: [Disposable] = []
                for leafSource in source.leafSources {
                    let subscription = SingleAssignmentDisposable()
                    subscription.disposable = leafSource.subscribeAny { [weak self, weak subscription] in
                        switch $0 {
                        case .next(_):
                            self?.erase(index)
                        case .error, .completed:
                            subscription?.disposable.dispose()
                        } }
                    extraDisposables.append(subscription)
                }
                _eraseSubscriptions[index] = CompositeDisposable(disposables: extraDisposables)
            }
            
            let mainScheduler = ConcurrentDispatchQueueScheduler(queue: DispatchQueue.main)
            _subscriptions[j].disposable = (debounceDependencies ? source.observeOn(mainScheduler) : source).subscribe(
                AnyObserver { event in
                    self.on(event, atIndex: index)
                })
            
            j += 1
        }
        
        return Disposables.create(_subscriptions.map { $0 as Disposable } + _eraseSubscriptions)
    }
}

class CombineLatestCollectionType<C: Collection, R> : Producer<R> where C.Iterator.Element : ObservableConvertibleType {
    typealias ResultSelector = ([C.Iterator.Element.E]) throws -> R
    
    let _sources: C
    let _resultSelector: ResultSelector
    let _count: Int
    let _debounceDependencies: Bool

    init(sources: C, debounceDependencies: Bool, resultSelector: @escaping ResultSelector) {
        _sources = sources
        _resultSelector = resultSelector
        _count = Int(self._sources.count.toIntMax())
        _debounceDependencies = debounceDependencies
    }
    
    override func run<O : ObserverType>(_ observer: O) -> Disposable where O.E == R {
        let sink = CombineLatestCollectionTypeSink(parent: self, observer: observer)
		sink.disposable = sink.run(debounceDependencies: _debounceDependencies)
        return sink
    }
}
