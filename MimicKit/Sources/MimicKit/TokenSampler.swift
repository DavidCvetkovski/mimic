import Foundation

/// Top-k then nucleus sampling over a language model's logits.
///
/// Separate from `Sampler`, which serves the speech model, because the shape of
/// the problem is different rather than because it is nicer. That one sorts the
/// whole distribution, which is fine over four thousand acoustic tokens; this
/// one is asked about a hundred and fifty-two thousand, once per word, on a
/// phone. Sorting all of it would cost more than the transformer.
///
/// So the k best are selected first — a bounded insertion into a small buffer,
/// linear in the vocabulary — and everything after that is arithmetic over k
/// entries rather than 152,000.
struct TokenSampler {
    private var generator: SplitMix
    private var buffer: [(index: Int, logit: Float)] = []

    init(seed: UInt64) {
        generator = SplitMix(seed: seed)
    }

    mutating func pick(from logits: [Float], temperature: Float,
                       topP: Float, topK: Int) -> Int {
        guard !logits.isEmpty else { return 0 }

        // Greedy is not a special case of sampling here, it is the absence of
        // it — and it has to be exact, because it is what the port is checked
        // against.
        if temperature <= 0 || topK <= 1 {
            var best = 0
            for index in logits.indices where logits[index] > logits[best] { best = index }
            return best
        }

        let keep = min(topK, logits.count)
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(keep)

        // The k largest, kept in descending order. `worst` is the bar to clear,
        // so the common case is one comparison per token in the vocabulary.
        var worst = -Float.infinity
        for index in logits.indices {
            let value = logits[index]
            if buffer.count == keep && value <= worst { continue }
            var at = buffer.count
            while at > 0 && buffer[at - 1].logit < value { at -= 1 }
            buffer.insert((index, value), at: at)
            if buffer.count > keep { buffer.removeLast() }
            worst = buffer[buffer.count - 1].logit
        }

        let scaled = buffer.map { Double($0.logit) / Double(temperature) }
        let highest = scaled[0]
        var weights = scaled.map { exp($0 - highest) }
        let total = weights.reduce(0, +)
        if total > 0 { for index in weights.indices { weights[index] /= total } }

        // The nucleus: the shortest prefix whose mass reaches topP. The first
        // is always kept, or a peaked distribution would leave nothing.
        var cumulative = 0.0
        var nucleus = weights.count
        for (rank, weight) in weights.enumerated() {
            cumulative += weight
            if cumulative >= Double(topP) { nucleus = rank + 1; break }
        }
        nucleus = max(1, nucleus)

        let mass = weights.prefix(nucleus).reduce(0, +)
        var draw = generator.nextDouble() * mass
        for rank in 0..<nucleus {
            draw -= weights[rank]
            if draw <= 0 { return buffer[rank].index }
        }
        return buffer[nucleus - 1].index
    }
}

/// Seedable, so a given seed writes the same thing twice. Foundation has no
/// reproducible generator and the system one cannot be seeded at all.
private struct SplitMix {
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
        Double(next() >> 11) * (1.0 / 9007199254740992.0)      // 53 bits, [0, 1)
    }
}
