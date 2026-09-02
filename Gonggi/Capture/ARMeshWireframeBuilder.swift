import ARKit
import RealityKit
import simd
import UIKit

/// Builds coverage-colored LiDAR mesh wireframes (line primitives only — no solid fill).
enum ARMeshWireframeBuilder {
    struct LineMesh {
        var positions: [SIMD3<Float>]
        var indices: [UInt32]
    }

    struct WireframeMeshes {
        var needsCapture: LineMesh
        var captured: LineMesh
    }

    static func wireframeMeshes(
        from geometry: ARMeshGeometry,
        anchorTransform: simd_float4x4,
        coverageStateAt: (simd_float3) -> CoverageState
    ) -> WireframeMeshes? {
        let vertices = localVertices(from: geometry)
        guard !vertices.isEmpty else { return nil }

        let faces = triangleIndices(from: geometry)
        guard !faces.isEmpty else { return nil }

        let buckets = classifyEdges(
            vertices: vertices,
            faces: faces,
            anchorTransform: anchorTransform,
            coverageStateAt: coverageStateAt
        )
        return WireframeMeshes(
            needsCapture: buckets.needsCapture,
            captured: buckets.captured
        )
    }

    static func meshResource(from lineMesh: LineMesh) -> MeshResource? {
        guard !lineMesh.positions.isEmpty, !lineMesh.indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(lineMesh.positions)
        descriptor.primitives = .lines(lineMesh.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

  // MARK: - Pure helpers (testable)

    static func localVertices(from geometry: ARMeshGeometry) -> [SIMD3<Float>] {
        let vertexSource = geometry.vertices
        guard vertexSource.count > 0 else { return [] }

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexSource.count)
        let vertexStride = vertexSource.stride
        let vertexBuffer = vertexSource.buffer.contents()

        for index in 0..<vertexSource.count {
            let pointer = vertexBuffer.advanced(by: vertexSource.offset + index * vertexStride)
            positions.append(pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }
        return positions
    }

    static func triangleIndices(from geometry: ARMeshGeometry) -> [UInt32] {
        let faceSource = geometry.faces
        guard faceSource.count > 0 else { return [] }

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
                    return []
                }
                indices.append(index)
            }
        }
        return indices
    }

    static func classifyEdges(
        vertices: [SIMD3<Float>],
        faces: [UInt32],
        anchorTransform: simd_float4x4,
        coverageStateAt: (simd_float3) -> CoverageState
    ) -> WireframeMeshes {
        var needs = LineMesh(positions: [], indices: [])
        var captured = LineMesh(positions: [], indices: [])
        var seenEdges: Set<EdgeKey> = []

        let faceCount = faces.count / 3
        for faceIndex in 0..<faceCount {
            let base = faceIndex * 3
            let i0 = Int(faces[base])
            let i1 = Int(faces[base + 1])
            let i2 = Int(faces[base + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            for (a, b) in [(i0, i1), (i1, i2), (i2, i0)] {
                let key = EdgeKey(a, b)
                guard !seenEdges.contains(key) else { continue }
                seenEdges.insert(key)

                let worldA = worldPosition(local: vertices[a], transform: anchorTransform)
                let worldB = worldPosition(local: vertices[b], transform: anchorTransform)
                let midpoint = (worldA + worldB) * 0.5
                let bucket = CoverageMeshWireStyle.bucket(for: coverageStateAt(midpoint))

                switch bucket {
                case .needsCapture:
                    appendLine(from: vertices[a], to: vertices[b], into: &needs)
                case .captured:
                    appendLine(from: vertices[a], to: vertices[b], into: &captured)
                }
            }
        }

        return WireframeMeshes(needsCapture: needs, captured: captured)
    }

    static func worldPosition(local: SIMD3<Float>, transform: simd_float4x4) -> SIMD3<Float> {
        let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    private static func appendLine(from a: SIMD3<Float>, to b: SIMD3<Float>, into mesh: inout LineMesh) {
        let start = UInt32(mesh.positions.count)
        mesh.positions.append(a)
        mesh.positions.append(b)
        mesh.indices.append(contentsOf: [start, start + 1])
    }

    private struct EdgeKey: Hashable {
        let low: Int
        let high: Int

        init(_ a: Int, _ b: Int) {
            if a < b {
                low = a
                high = b
            } else {
                low = b
                high = a
            }
        }
    }
}

enum CoverageMeshMaterials {
    static func needsCaptureMaterial() -> SimpleMaterial {
        var material = SimpleMaterial()
        material.color = .init(
            tint: UIColor(red: 0.30, green: 0.72, blue: 0.96, alpha: 0.62),
            texture: nil
        )
        material.metallic = 0
        material.roughness = 1
        return material
    }

    static func capturedMaterial() -> SimpleMaterial {
        var material = SimpleMaterial()
        material.color = .init(
            tint: UIColor(red: 0.38, green: 0.84, blue: 0.58, alpha: 0.20),
            texture: nil
        )
        material.metallic = 0
        material.roughness = 1
        return material
    }
}

enum CaptureDeviceCapabilities {
    static var supportsLiDARMeshReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}
