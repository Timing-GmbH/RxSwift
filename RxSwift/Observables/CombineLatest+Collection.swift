//
//  CombineLatest+Collection.swift
//  RxSwift
//
//  Created by Krunoslav Zaher on 8/29/15.
//  Copyright © 2015 Krunoslav Zaher. All rights reserved.
//

import Foundation

extension ObservableType {
    /**
     Merges the specified observable sequences into one observable sequence by using the selector function whenever any of the observable sequences produces an element.

     - seealso: [combinelatest operator on reactivex.io](http://reactivex.io/documentation/operators/combinelatest.html)

     - parameter resultSelector: Function to invoke whenever any of the sources produces an element.
     - returns: An observable sequence containing the result of combining elements of the sources using the specified result selector function.
     */
    public static func combineLatest<Collection: Swift.Collection>(_ collection: Collection, debounceDependencies: Bool = false, resultSelector: @escaping ([Collection.Element.Element]) throws -> Element) -> Observable<Element>
        where Collection.Element: ObservableType {
        return CombineLatestCollectionType(sources: collection, debounceDependencies: debounceDependencies, resultSelector: resultSelector)
    }

    /**
     Merges the specified observable sequences into one observable sequence whenever any of the observable sequences produces an element.

     - seealso: [combinelatest operator on reactivex.io](http://reactivex.io/documentation/operators/combinelatest.html)

     - returns: An observable sequence containing the result of combining elements of the sources.
     */
    public static func combineLatest<Collection: Swift.Collection>(_ collection: Collection, debounceDependencies: Bool = false) -> Observable<[Element]>
        where Collection.Element: ObservableType, Collection.Element.Element == Element {
        return CombineLatestCollectionType(sources: collection, debounceDependencies: debounceDependencies, resultSelector: { $0 })
    }
}

final private class CombineLatestCollectionTypeSink<Collection: Swift.Collection, Observer: ObserverType>
    : Sink<Observer> where Collection.Element: ObservableConvertibleType {
    typealias Result = Observer.Element 
    typealias Parent = CombineLatestCollectionType<Collection, Result>
    typealias SourceElement = Collection.Element.Element
    
    let _parent: Parent
    
    let _lock = RecursiveLock()

    // state
    var _numberOfValues = 0
    var _values: [SourceElement?]
    var _isDone: [Bool]
    var _numberOfDone = 0
    var _subscriptions: [SingleAssignmentDisposable]
    var _eraseSubscriptions: [Disposable]
    
    init(parent: Parent, observer: Observer, cancel: Cancelable) {
        self._parent = parent
        self._values = [SourceElement?](repeating: nil, count: parent._count)
        self._isDone = [Bool](repeating: false, count: parent._count)
        self._subscriptions = [SingleAssignmentDisposable]()
        self._subscriptions.reserveCapacity(parent._count)
        
        for _ in 0 ..< parent._count {
            self._subscriptions.append(SingleAssignmentDisposable())
        }
        
        _eraseSubscriptions = (0 ..< parent._count).map { _ in Disposables.create() }
        
        super.init(observer: observer, cancel: cancel)
    }
    
    func on(_ event: Event<SourceElement>, atIndex: Int) {
        self._lock.lock(); defer { self._lock.unlock() } // {
            switch event {
            case .next(let element):
                if self._values[atIndex] == nil {
                   self._numberOfValues += 1
                }
                
                self._values[atIndex] = element
                
                if self._numberOfValues < self._parent._count {
                    let numberOfOthersThatAreDone = self._numberOfDone - (self._isDone[atIndex] ? 1 : 0)
                    if numberOfOthersThatAreDone == self._parent._count - 1 {
                        self.forwardOn(.completed)
                        self.dispose()
                    }
                    return
                }
                
                do {
                    let result = try self._parent._resultSelector(self._values.map { $0! })
                    self.forwardOn(.next(result))
                }
                catch let error {
                    self.forwardOn(.error(error))
                    self.dispose()
                }
                
            case .error(let error):
                self.forwardOn(.error(error))
                self.dispose()
            case .completed:
                if self._isDone[atIndex] {
                    return
                }
                
                self._isDone[atIndex] = true
                self._numberOfDone += 1
                
                if self._numberOfDone == self._parent._count {
                    self.forwardOn(.completed)
                    self.dispose()
                }
                else {
                    self._subscriptions[atIndex].dispose()
                    self._eraseSubscriptions[atIndex].dispose()
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
        for i in self._parent._sources {
            let index = j
            let source = i.asObservable()

            if debounceDependencies {
                var extraDisposables: [Disposable] = []
                for leafSource in source.leafSources.deduplicatedByPointer() {
                    let subscription = SingleAssignmentDisposable()
                    let disposable = leafSource.subscribeAny { [weak self, weak subscription] in
                        switch $0 {
                        case .next(_):
                            self?.erase(index)
                        case .error, .completed:
                            subscription?.dispose()
                        } }
					subscription.setDisposable(disposable)
                    extraDisposables.append(subscription)
                }
                _eraseSubscriptions[index] = CompositeDisposable(disposables: extraDisposables)
            }

            let mainScheduler = ConcurrentDispatchQueueScheduler(queue: DispatchQueue.main)
            let disposable = (debounceDependencies ? source.observeOn(mainScheduler) : source).subscribe(
                AnyObserver { event in
                self.on(event, atIndex: index)
            })

            self._subscriptions[j].setDisposable(disposable)
            
            j += 1
        }

        if self._parent._sources.isEmpty {
            do {
                let result = try self._parent._resultSelector([])
                self.forwardOn(.next(result))
                self.forwardOn(.completed)
                self.dispose()
            }
            catch let error {
                self.forwardOn(.error(error))
                self.dispose()
            }
        }
        
        return Disposables.create(_subscriptions.map { $0 as Disposable } + _eraseSubscriptions)
    }
}

final private class CombineLatestCollectionType<Collection: Swift.Collection, Result>: Producer<Result> where Collection.Element: ObservableConvertibleType {
    typealias ResultSelector = ([Collection.Element.Element]) throws -> Result
    
    let _sources: Collection
    let _resultSelector: ResultSelector
    let _count: Int
    let _debounceDependencies: Bool

    init(sources: Collection, debounceDependencies: Bool, resultSelector: @escaping ResultSelector) {
        self._sources = sources
        self._resultSelector = resultSelector
        self._count = self._sources.count
        self._debounceDependencies = debounceDependencies
    }
    
    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Result {
        let sink = CombineLatestCollectionTypeSink(parent: self, observer: observer, cancel: cancel)
        let subscription = sink.run(debounceDependencies: _debounceDependencies)
        return (sink: sink, subscription: subscription)
    }
}
