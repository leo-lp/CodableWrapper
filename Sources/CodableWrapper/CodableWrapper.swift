//
//  TransformWrapper.swift
//  CodableWrapperDev
//
//  Created by winddpan on 2020/8/15.
//  Copyright © 2020 YR. All rights reserved.
//

import Foundation

@propertyWrapper
public final class CodableWrapper<Value>: Codable {
    struct Construct {
        var codingKeys: [String]
        var fromNull: () -> Value
        var fromJSON: (Any) -> TransformTypeResult<Value?>
        var toJSON: (Value) -> TransformTypeResult<Encodable?>
    }

    private var unsafeCreated: Bool
    fileprivate var construct: Construct?
    fileprivate var storedValue: Value?
    fileprivate var decoderInjetion: ((CodableWrapper<Value>) -> Void)?

    deinit {
        if !unsafeCreated, let construct = construct, let lastWrapper = Thread.current.lastCodableWrapper as? CodableWrapper<Value> {
            lastWrapper.invokeAfterInjection(with: construct)
            Thread.current.lastCodableWrapper = nil
        }
    }

    init(construct: Construct) {
        unsafeCreated = false
        self.construct = construct
    }

    init(storedValue: Value) {
        unsafeCreated = false
        self.storedValue = storedValue
    }

    fileprivate init(unsafed: ()) {
        unsafeCreated = true
    }

    private func invokeAfterInjection(with construct: Construct) {
        self.construct = construct
        decoderInjetion?(self)
        decoderInjetion = nil
    }

    public var wrappedValue: Value {
        get { storedValue ?? construct!.fromNull() }
        set { storedValue = newValue }
    }

    public required init(from decoder: Decoder) throws {
        unsafeCreated = true
    }

    public func encode(to encoder: Encoder) throws {
        // Do nothing, KeyedEncodingContainer extension has done dirty stuff
    }
}

// - KeyedEncodingContainer

public extension KeyedEncodingContainer {
    mutating func encode<T, Value>(_ value: T, forKey key: Key) throws where T: CodableWrapper<Value> {
        if let construct = value.construct {
            switch construct.toJSON(value.wrappedValue) {
            case let .custom(json):
                if let dictionary = _container() {
                    dictionary.setValue(json, forKey: construct.codingKeys.first ?? key.stringValue)
                }
            case .default:
                if let encoder = _encoder(), let key = AnyCodingKey(stringValue: construct.codingKeys.first ?? key.stringValue), let wrappedValue = value.wrappedValue as? Encodable {
                    var container = encoder.container(keyedBy: AnyCodingKey.self)
                    try wrappedValue.encode(to: &container, forKey: key)
                }
            }
        } else if let encoder = _encoder(), let key = AnyCodingKey(stringValue: key.stringValue), let wrappedValue = value.wrappedValue as? Encodable {
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try wrappedValue.encode(to: &container, forKey: key)
        }
    }
}

// - KeyedDecodingContainer

public extension KeyedDecodingContainer {
    func decode<Value>(_ type: CodableWrapper<Value>.Type, forKey key: Key) throws -> CodableWrapper<Value> {
        return try _decode(type, forKey: key) { (_, _) -> Value? in
            nil
        }
    }

    func decode<Value: Decodable>(_ type: CodableWrapper<Value>.Type, forKey key: Key) throws -> CodableWrapper<Value> {
        return try _decode(type, forKey: key) { (container, key) -> Value? in
            if let key = AnyCodingKey(stringValue: key), let value = try? container.decode(Value.self, forKey: key) {
                return value
            }
            return nil
        }
    }

    private func _decode<Value>(_ type: CodableWrapper<Value>.Type, forKey key: Key, onDecoding: @escaping ((KeyedDecodingContainer<AnyCodingKey>, String) -> Value?)) throws -> CodableWrapper<Value> {
        let injection: ((CodableWrapper<Value>) -> Void) = { wrapper in
            guard let construct = wrapper.construct, let dictionary = self._containerDictionary() else { return }
            guard let decoder = self._decoder(), let container = try? decoder.container(keyedBy: AnyCodingKey.self) else { return }

            for codingKey in [key.stringValue] + construct.codingKeys {
                if let json = dictionary[codingKey] {
                    switch construct.fromJSON(json) {
                    case let .custom(resultValue):
                        wrapper.storedValue = resultValue
                        return
                    case .default:
                        if let decoded = onDecoding(container, codingKey) {
                            wrapper.storedValue = decoded
                            return
                        }
                    }
                    if let bridge = Value.self as? _BuiltInBridgeType.Type, let bridged = bridge._transform(from: json) as? Value {
                        wrapper.storedValue = bridged
                        return
                    }
                }
            }
            if wrapper.storedValue == nil {
                wrapper.storedValue = construct.fromNull()
            }
        }

        var wrapper: CodableWrapper<Value>
        if let decodeIfPresent = try? decodeIfPresent(CodableWrapper<Value>.self, forKey: key) {
            wrapper = decodeIfPresent
        } else {
            wrapper = CodableWrapper<Value>(unsafed: ())
        }

        // Try parse bridged type at first
        if let bridge = Value.self as? _BuiltInBridgeType.Type,
            let dictionary = _containerDictionary(),
            let json = dictionary[key.stringValue],
            let bridged = bridge._transform(from: json) as? Value {
            wrapper.storedValue = bridged
        }
        wrapper.decoderInjetion = injection
        Thread.current.lastCodableWrapper = wrapper
        return wrapper
    }
}
