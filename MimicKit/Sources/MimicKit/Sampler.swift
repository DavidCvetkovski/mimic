import Foundation

/// Top-k / top-p sampling, matching the reference implementation step for step.
///
/// Note that it does not draw from the distribution directly: it perturbs the
/// probabilities with exponential noise and takes the largest. That is the
/// Gumbel-max trick, and reproducing it exactly matters — a "cleaner" sampler
/// here would be a different model, not a tidier one.
struct Sampler {
    private var generator: SplitMix64

    init(seed: UInt64) {
        // Not the same stream as NumPy's PCG64, so a given seed does not
        // reproduce the Python output token for token. Both are valid draws
        // from the same distribution; only reproducibility across the two
        // implementations is lost, and nothing depends on it.
        generator = SplitMix64(seed: seed)
    }

    mutating func pick(from logits: [Float], temperature: Float,
                       topP: Float, topK: Int) -> Int {
        guard !logits.isEmpty else { return 0 }
        let values = logits.map(Double.init)

        // Descending order, so the cumulative mass below can be walked.
        let order = values.indices.sorted { values[$0] > values[$1] }
        let sorted = order.map { values[$0] }

        let highest = sorted[0]
        var weights = sorted.map { exp($0 - highest) }
        let total = weights.reduce(0, +)
        if total > 0 { for index in weights.indices { weights[index] /= total } }

        // Everything past the nucleus, or past k, is removed — except the most
        // likely token, which is always kept so that something survives.
        var masked = values
        var cumulative = 0.0
        for (rank, weight) in weights.enumerated() {
            cumulative += weight
            let beyondNucleus = cumulative > Double(topP)
            let beyondK = rank >= topK
            if rank > 0 && (beyondNucleus || beyondK) {
                masked[order[rank]] = -.infinity
            }
        }

        let scaled = masked.map { $0 / Double(max(temperature, 1e-5)) }
        let top = scaled.max() ?? 0
        var probabilities = scaled.map { exp($0 - top) }
        let sum = probabilities.reduce(0, +)
        if sum > 0 { for index in probabilities.indices { probabilities[index] /= sum } }

        var best = 0
        var bestScore = -Double.infinity
        for index in probabilities.indices {
            let uniform = min(max(generator.nextDouble(), 1e-12), 1.0)
            let noise = -log(uniform)
            let score = probabilities[index] / noise
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }
}

/// A small, seedable generator. Foundation has no reproducible one, and the
/// system source cannot be seeded at all.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)   // 53 bits, [0, 1)
    }
}
