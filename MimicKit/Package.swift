// swift-tools-version: 5.9
import PackageDescription

// The engine, in Swift, with no Python anywhere.
//
// Deliberately platform-agnostic rather than an iOS target: the same code
// builds for macOS, which is the only way any of it can be tested. An iPhone
// cannot be attached to a debugger halfway through a port, and a Swift
// reimplementation of an autoregressive loop is exactly the kind of thing that
// is wrong in ways only a comparison against the original will reveal.
let package = Package(
    name: "MimicKit",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "MimicKit", targets: ["MimicKit"]),
    ],
    dependencies: [
        // 1.20 is the floor: the INT4 models use the GatherBlockQuantized
        // contrib operator, which older runtimes refuse to load outright.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 from: "1.24.2"),
        // Reads the same tokenizer.json the Python side uses, so the two
        // cannot disagree about what a prompt tokenises to.
        .package(url: "https://github.com/huggingface/swift-transformers",
                 from: "1.3.3"),
    ],
    targets: [
        .target(name: "MimicKit",
                dependencies: [
                    .product(name: "onnxruntime",
                             package: "onnxruntime-swift-package-manager"),
                    .product(name: "Tokenizers", package: "swift-transformers"),
                ]),
        .testTarget(name: "MimicKitTests", dependencies: ["MimicKit"]),
    ]
)
