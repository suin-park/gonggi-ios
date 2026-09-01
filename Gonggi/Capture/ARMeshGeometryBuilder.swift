import ARKit
import RealityKit
import simd

/// Converts `ARMeshGeometry` to RealityKit `MeshDescriptor` (Xcode 16+ removed direct `generate(from: ARMeshGeometry)`).
enum ARMeshGeometryBuilder {
    static func meshResource(from geometry: ARMeshGeometry) -> MeshResource? {
        guard let descriptor = meshDescriptor(from: geometry) else { return nil }
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func meshDescriptor(from geometry: ARMeshGeometry) -> MeshDescriptor? {
        let vertexSource = geometry.vertices
        guard vertexSource.count > 0 else { return nil }

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexSource.count)
        let vertexStride = vertexSource.stride
        let vertexBuffer = vertexSource.buffer.contents()

        for index in 0..<vertexSource.count {
            let pointer = vertexBuffer.advanced(by: vertexSource.offset + index * vertexStride)
            positions.append(pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }

        let faceSource = geometry.faces
        guard faceSource.count > 0 else { return nil }

        var indices: [UInt32] = []
        indices.reserveCapacity(faceSource.count * faceSource.indexCountPerPrimitive)
        let faceBuffer = faceSource.buffer.contents()
        let bytesPerIndex = faceSource.bytesPerIndex
        let indicesPerFace = faceSource.indexCountPerPrimitive
        let faceStride = indicesPerFace * bytesPerIndex

        for faceIndex in 0..<faceSource.count {
            let base = faceIndex * faceStride
            for i in 0..<indicesPerFace {
                let offset = base + i * bytesPerIndex
                let index: UInt32
                switch bytesPerIndex {
                case 2:
                    index = UInt32(faceBuffer.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
                case 4:
                    index = faceBuffer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
                default:
                    return nil
                }
                indices.append(index)
            }
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}
