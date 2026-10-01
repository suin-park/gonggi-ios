// The Apple `simd` module does not exist on Linux. The pure logic only needs these three functions; on Apple platforms
// (`canImport(simd)`) this file compiles to nothing and the real module is used.
#if !canImport(simd)
import Foundation

func simd_length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) }
func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / simd_length(v) }
#endif
