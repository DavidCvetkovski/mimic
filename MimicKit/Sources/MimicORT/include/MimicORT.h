// Re-exports ONNX Runtime's C API so Swift can reach it.
//
// The Objective-C bindings that ship with the package cannot represent
// float16, and this model needs it for every KV cache tensor. The C API
// underneath can — but the xcframework has no module.modulemap, so Swift
// cannot import it directly. This target exists solely to give it one.
#import <onnxruntime/onnxruntime_c_api.h>
