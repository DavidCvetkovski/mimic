import Foundation
import OnnxRuntimeBindings

/// The key/value cache for one autoregressive branch.
///
/// Held as flat Float16 buffers with the shape the graph expects, and written
/// in place: the model returns only the slice for the positions it just
/// processed, and those get scattered back into the full buffer. Allocating a
/// fresh cache per step instead would dominate the runtime — this is called
/// ten times per frame, twenty-one times a second of audio.
struct KVCache {
    let shape: [Int]                 // [1, heads, sequence, dim]
    private(set) var buffers: [[Float16]]

    var heads: Int { shape[1] }
    var sequence: Int { shape[2] }
    var dim: Int { shape[3] }

    init(layers: Int, heads: Int, sequence: Int, dim: Int) {
        shape = [1, heads, sequence, dim]
        // Two per layer: keys and values, interleaved, as the graph names them.
        buffers = Array(repeating: [Float16](repeating: 0, count: heads * sequence * dim),
                        count: layers * 2)
    }

    /// Scatter `delta` — shaped [1, heads, positions.count, dim] — into the
    /// rows named by `positions`.
    mutating func update(index: Int, positions: [Int], delta: [Float16]) {
        let count = positions.count
        guard count > 0, delta.count >= heads * count * dim else { return }
        buffers[index].withUnsafeMutableBufferPointer { cache in
            delta.withUnsafeBufferPointer { source in
                for head in 0..<heads {
                    let cacheHead = head * sequence * dim
                    let sourceHead = head * count * dim
                    for (slot, position) in positions.enumerated() where position < sequence {
                        let to = cacheHead + position * dim
                        let from = sourceHead + slot * dim
                        for element in 0..<dim {
                            cache[to + element] = source[from + element]
                        }
                    }
                }
            }
        }
    }

    func value(at index: Int) throws -> ORTValue {
        try Tensor.float16(buffers[index], shape: shape)
    }
}
