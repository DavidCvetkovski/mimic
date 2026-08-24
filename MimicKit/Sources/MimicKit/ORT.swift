import Foundation
import MimicORT

/// A thin Swift wrapper over ONNX Runtime's C API.
///
/// The Objective-C bindings that ship with the package would be the obvious
/// choice, but their element-type enum has no float16 — it is Float, the
/// integer widths, and String — and this model needs float16 for all forty-eight
/// KV cache tensors on the slow branch as well as the hidden state passed
/// between the branches. The C API underneath has always supported it, so this
/// reaches past the wrapper rather than around the model.
///
/// Everything here is `final class` with a deinit, because the C API hands back
/// pointers it expects to be given back.
enum ORT {

    /// The API table. Fetched once; every call goes through it.
    static let api: UnsafePointer<OrtApi> = {
        guard let base = OrtGetApiBase(), let table = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            fatalError("ONNX Runtime did not return an API table")
        }
        return table
    }()

    /// Turn a non-null OrtStatus into a thrown Swift error, and release it.
    static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let raw = api.pointee.GetErrorMessage(status)
        let message = raw.map { String(cString: $0) } ?? "ONNX Runtime failed"
        api.pointee.ReleaseStatus(status)
        throw MimicError.inference(message)
    }

    // MARK: - Environment

    final class Env {
        let handle: OpaquePointer

        init(name: String = "mimic") throws {
            var pointer: OpaquePointer?
            // Warnings only: the INT4 graphs emit a constant-folding notice per
            // quantised node at load, which is hundreds of lines of noise.
            try ORT.check(ORT.api.pointee.CreateEnv(ORT_LOGGING_LEVEL_ERROR, name, &pointer))
            guard let pointer else { throw MimicError.inference("could not create an environment") }
            handle = pointer
        }

        deinit { ORT.api.pointee.ReleaseEnv(handle) }
    }

    // MARK: - Values

    /// A tensor, and the memory it points at.
    ///
    /// `CreateTensorWithDataAsOrtValue` does not copy — it borrows. The buffer
    /// therefore has to outlive the value, which is why the two are owned
    /// together here rather than passed around separately.
    final class Value {
        let handle: OpaquePointer
        private let storage: UnsafeMutableRawPointer?
        private let bytes: Int

        /// Wrap a value the runtime produced. It owns its own memory.
        init(owning handle: OpaquePointer) {
            self.handle = handle
            storage = nil
            bytes = 0
        }

        /// Wrap a buffer somebody else owns and keeps alive.
        ///
        /// The runtime borrows rather than copies, so this is how a tensor can
        /// be made once and its contents rewritten between runs — which is the
        /// difference between copying the KV cache every step and not.
        init(borrowing buffer: UnsafeMutableRawPointer, byteCount: Int,
             shape: [Int], type: ONNXTensorElementDataType) throws {
            storage = nil                     // not ours to free
            bytes = byteCount

            var memoryInfo: OpaquePointer?
            try ORT.check(ORT.api.pointee.CreateCpuMemoryInfo(
                OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
            defer { ORT.api.pointee.ReleaseMemoryInfo(memoryInfo) }

            var dimensions = shape.map(Int64.init)
            var pointer: OpaquePointer?
            try ORT.check(ORT.api.pointee.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer, byteCount, &dimensions, dimensions.count, type, &pointer))
            guard let pointer else { throw MimicError.inference("could not wrap a buffer") }
            handle = pointer
        }

        /// Copy `values` into a buffer this object owns, and make a tensor of it.
        init<T>(_ values: [T], shape: [Int], type: ONNXTensorElementDataType) throws {
            // A local, not self.bytes: the closure below would otherwise
            // capture self before every member is initialised.
            let byteCount = values.count * MemoryLayout<T>.stride
            bytes = byteCount
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: max(byteCount, 1), alignment: MemoryLayout<T>.alignment)
            values.withUnsafeBytes { source in
                if let base = source.baseAddress {
                    buffer.copyMemory(from: base, byteCount: byteCount)
                }
            }
            storage = buffer

            var memoryInfo: OpaquePointer?
            try ORT.check(ORT.api.pointee.CreateCpuMemoryInfo(
                OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
            defer { ORT.api.pointee.ReleaseMemoryInfo(memoryInfo) }

            var dimensions = shape.map(Int64.init)
            var pointer: OpaquePointer?
            try ORT.check(ORT.api.pointee.CreateTensorWithDataAsOrtValue(
                memoryInfo, buffer, byteCount, &dimensions, dimensions.count, type, &pointer))
            guard let pointer else {
                buffer.deallocate()
                throw MimicError.inference("could not create a tensor")
            }
            handle = pointer
        }

        deinit {
            ORT.api.pointee.ReleaseValue(handle)
            storage?.deallocate()
        }

        // ---- reading back ----

        var elementType: ONNXTensorElementDataType {
            var info: OpaquePointer?
            guard ORT.api.pointee.GetTensorTypeAndShape(handle, &info) == nil, let info else {
                return ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            }
            defer { ORT.api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
            var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            _ = ORT.api.pointee.GetTensorElementType(info, &type)
            return type
        }

        var shape: [Int] {
            var info: OpaquePointer?
            guard ORT.api.pointee.GetTensorTypeAndShape(handle, &info) == nil, let info else { return [] }
            defer { ORT.api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
            var count = 0
            _ = ORT.api.pointee.GetDimensionsCount(info, &count)
            var dimensions = [Int64](repeating: 0, count: count)
            _ = ORT.api.pointee.GetDimensions(info, &dimensions, count)
            return dimensions.map(Int.init)
        }

        var count: Int { shape.reduce(1, *) }

        private func raw<T>(as: T.Type) -> [T] {
            var pointer: UnsafeMutableRawPointer?
            guard ORT.api.pointee.GetTensorMutableData(handle, &pointer) == nil,
                  let pointer else { return [] }
            let typed = pointer.bindMemory(to: T.self, capacity: count)
            return Array(UnsafeBufferPointer(start: typed, count: count))
        }

        /// Floats, whatever the tensor actually holds.
        func floats() -> [Float] {
            switch elementType {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:   return raw(as: Float.self)
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16: return raw(as: Float16.self).map(Float.init)
            default: return []
            }
        }

        func int64s() -> [Int64] {
            switch elementType {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return raw(as: Int64.self)
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: return raw(as: Int32.self).map(Int64.init)
            default: return []
            }
        }

        func float16s() -> [Float16] {
            switch elementType {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16: return raw(as: Float16.self)
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:   return raw(as: Float.self).map(Float16.init)
            default: return []
            }
        }

        // ---- making one ----

        static func int64(_ values: [Int64], shape: [Int]) throws -> Value {
            try Value(values, shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        }
        static func float16(_ values: [Float16], shape: [Int]) throws -> Value {
            try Value(values, shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16)
        }
        static func bool(_ values: [Bool], shape: [Int]) throws -> Value {
            try Value(values.map { UInt8($0 ? 1 : 0) }, shape: shape,
                      type: ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL)
        }
    }

    // MARK: - Sessions

    final class Session {
        let handle: OpaquePointer
        let inputNames: [String]
        let outputNames: [String]

        private let inputCStrings: [UnsafePointer<CChar>?]
        private let outputCStrings: [UnsafePointer<CChar>?]

        init(env: Env, path: String, threads: Int, coreML: Bool = false) throws {
            var options: OpaquePointer?
            try ORT.check(ORT.api.pointee.CreateSessionOptions(&options))
            defer { ORT.api.pointee.ReleaseSessionOptions(options) }
            try ORT.check(ORT.api.pointee.SetIntraOpNumThreads(options, Int32(threads)))
            try ORT.check(ORT.api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
            try ORT.check(ORT.api.pointee.SetSessionLogSeverityLevel(options, 3))

            // CoreML takes whichever subgraphs it can and leaves the rest on
            // the CPU. Worth offering for the codec decoder, which is dense
            // convolution; the autoregressive branches are a poor fit and are
            // not offered it.
            if coreML {
                var flags: UInt32 = 0
                flags |= UInt32(COREML_FLAG_ONLY_ENABLE_DEVICE_WITH_ANE.rawValue)
                _ = OrtSessionOptionsAppendExecutionProvider_CoreML(options, flags)
            }

            var pointer: OpaquePointer?
            try ORT.check(ORT.api.pointee.CreateSession(env.handle, path, options, &pointer))
            guard let pointer else { throw MimicError.inference("could not open \(path)") }
            handle = pointer

            var allocator: UnsafeMutablePointer<OrtAllocator>?
            try ORT.check(ORT.api.pointee.GetAllocatorWithDefaultOptions(&allocator))

            // Free functions rather than methods: `self` is not fully
            // initialised yet, and a closure that captures it here will not
            // compile — correctly.
            inputNames = try ORT.Session.readNames(
                session: pointer, allocator: allocator, count: ORT.api.pointee.SessionGetInputCount,
                name: ORT.api.pointee.SessionGetInputName)
            outputNames = try ORT.Session.readNames(
                session: pointer, allocator: allocator, count: ORT.api.pointee.SessionGetOutputCount,
                name: ORT.api.pointee.SessionGetOutputName)

            // C strings for Run, made once. Building them per step showed up in
            // profiles: the loop runs this eleven times per frame.
            inputCStrings = inputNames.map { UnsafePointer(strdup($0)) }
            outputCStrings = outputNames.map { UnsafePointer(strdup($0)) }
        }

        private static func readNames(
            session: OpaquePointer,
            allocator: UnsafeMutablePointer<OrtAllocator>?,
            count: (OpaquePointer?, UnsafeMutablePointer<Int>?) -> OpaquePointer?,
            name: (OpaquePointer?, Int, UnsafeMutablePointer<OrtAllocator>?,
                   UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer?
        ) throws -> [String] {
            var total = 0
            try ORT.check(count(session, &total))
            return try (0..<total).map { index in
                var raw: UnsafeMutablePointer<CChar>?
                try ORT.check(name(session, index, allocator, &raw))
                defer { if let raw { _ = ORT.api.pointee.AllocatorFree(allocator, raw) } }
                return raw.map { String(cString: $0) } ?? ""
            }
        }

        deinit {
            ORT.api.pointee.ReleaseSession(handle)
            for pointer in inputCStrings + outputCStrings {
                free(UnsafeMutableRawPointer(mutating: pointer))
            }
        }

        /// Run with inputs given by name. Every output is returned, in order.
        func run(_ inputs: [String: Value]) throws -> [Value] {
            var names: [UnsafePointer<CChar>?] = []
            var values: [OpaquePointer?] = []
            names.reserveCapacity(inputs.count)
            values.reserveCapacity(inputs.count)
            for (index, name) in inputNames.enumerated() {
                guard let value = inputs[name] else { continue }
                names.append(inputCStrings[index])
                values.append(value.handle)
            }
            guard names.count == inputs.count else {
                let missing = Set(inputs.keys).subtracting(inputNames)
                throw MimicError.inference("the graph has no input named \(missing.sorted())")
            }

            var outputs = [OpaquePointer?](repeating: nil, count: outputNames.count)
            try ORT.check(ORT.api.pointee.Run(
                handle, nil,
                &names, &values, names.count,
                outputCStrings.map { $0 }, outputNames.count,
                &outputs))

            // `inputs` is kept alive to here on purpose: the tensors borrow
            // their buffers, and Run reads them.
            withExtendedLifetime(inputs) {}
            return outputs.map { Value(owning: $0!) }
        }
    }
}
