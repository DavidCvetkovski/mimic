import Foundation
import OnnxRuntimeBindings

/// Marshalling between Swift arrays and ORTValue.
///
/// The Objective-C bindings take a shape and a blob of bytes and trust you
/// about both, so every conversion in the engine funnels through here rather
/// than being written out at each call site — one place to be careful in.
enum Tensor {

    static func int64(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        try make(values, shape: shape, type: .int64)
    }

    static func bool(_ values: [Bool], shape: [Int]) throws -> ORTValue {
        // ORT wants one byte per element; Swift's Bool is already that, but its
        // in-memory representation is not guaranteed, so convert explicitly.
        try make(values.map { UInt8($0 ? 1 : 0) }, shape: shape, type: .uInt8)
    }

    static func float16(_ values: [Float16], shape: [Int]) throws -> ORTValue {
        try make(values, shape: shape, type: .float16)
    }

    static func float(_ values: [Float], shape: [Int]) throws -> ORTValue {
        try make(values, shape: shape, type: .float)
    }

    private static func make<T>(_ values: [T], shape: [Int],
                                type: ORTTensorElementDataType) throws -> ORTValue {
        var copy = values
        let data = NSMutableData(bytes: &copy, length: values.count * MemoryLayout<T>.stride)
        return try ORTValue(tensorData: data,
                            elementType: type,
                            shape: shape.map(NSNumber.init(value:)))
    }

    // MARK: - Reading back

    static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    static func float16s(_ value: ORTValue) throws -> [Float16] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float16.self))
        }
    }

    static func shape(_ value: ORTValue) throws -> [Int] {
        try value.tensorTypeAndShapeInfo().shape.map(\.intValue)
    }

    /// Logits come back as float32 or float16 depending on the graph; the loop
    /// only ever wants Float.
    static func asFloats(_ value: ORTValue) throws -> [Float] {
        switch try value.tensorTypeAndShapeInfo().elementType {
        case .float:   return try floats(value)
        case .float16: return try float16s(value).map(Float.init)
        default:
            throw MimicError.inference("unexpected logits element type")
        }
    }
}
