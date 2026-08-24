import Foundation
import MimicORT

/// The key/value cache for one autoregressive branch.
///
/// The buffers are allocated once and rewritten in place, and each has one
/// `ORT.Value` wrapped permanently around it. That matters more than it looks:
/// the slow branch holds forty-eight tensors of half a megabyte each, and
/// building fresh ones per step meant allocating and copying twenty-four
/// megabytes every frame — over five hundred megabytes a second at
/// twenty-one frames — to hand the runtime data it already had.
///
/// A class rather than a struct because the tensors point into these buffers;
/// copying the cache would leave them pointing at the original.
final class KVCache {
    let shape: [Int]                 // [1, heads, sequence, dim]
    let heads: Int
    let sequence: Int
    let dim: Int

    private let elements: Int
    private var buffers: [UnsafeMutablePointer<Float16>] = []
    private var tensors: [ORT.Value] = []

    init(layers: Int, heads: Int, sequence: Int, dim: Int) throws {
        shape = [1, heads, sequence, dim]
        self.heads = heads
        self.sequence = sequence
        self.dim = dim
        elements = heads * sequence * dim

        // Two per layer, keys and values interleaved, as the graph names them.
        for _ in 0..<(layers * 2) {
            let buffer = UnsafeMutablePointer<Float16>.allocate(capacity: elements)
            buffer.initialize(repeating: 0, count: elements)
            buffers.append(buffer)
            tensors.append(try ORT.Value(borrowing: buffer,
                                         byteCount: elements * MemoryLayout<Float16>.stride,
                                         shape: shape,
                                         type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16))
        }
    }

    deinit {
        for buffer in buffers { buffer.deallocate() }
    }

    /// Back to zeros, without giving the memory back — the fast branch needs a
    /// clean cache for every frame, twenty-one times a second.
    func clear() {
        for buffer in buffers { buffer.update(repeating: 0, count: elements) }
    }

    /// The tensor for one layer. The same object every time; only its contents
    /// change.
    func value(at index: Int) -> ORT.Value { tensors[index] }

    /// Scatter `delta` — shaped [1, heads, positions.count, dim] — into the
    /// rows named by `positions`.
    func update(index: Int, positions: [Int], delta: [Float16]) {
        let count = positions.count
        guard count > 0, delta.count >= heads * count * dim else { return }
        let cache = buffers[index]
        delta.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for head in 0..<heads {
                let cacheHead = head * sequence * dim
                let sourceHead = head * count * dim
                for (slot, position) in positions.enumerated() where position < sequence {
                    (cache + cacheHead + position * dim)
                        .update(from: base + sourceHead + slot * dim, count: dim)
                }
            }
        }
    }
}
