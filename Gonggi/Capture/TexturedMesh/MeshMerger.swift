import Foundation
import simd

/// Merges LiDAR mesh anchor snapshots into a single world-space mesh.
enum MeshMerger {
    static func merge(snapshots: [MeshAnchorSnapshot]) -> MergedMeshGeometry {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(snapshots.reduce(0) { $0 + $1.vertices.count })
        indices.reserveCapacity(snapshots.reduce(0) { $0 + $1.indices.count })

        for snapshot in snapshots {
            let base = UInt32(vertices.count)
            for local in snapshot.vertices {
                let world = ARMeshWireframeBuilder.worldPosition(local: local, transform: snapshot.transform)
                vertices.append(world)
            }
            for index in snapshot.indices {
                indices.append(base + index)
            }
        }

        let normals = computeVertexNormals(vertices: vertices, indices: indices)
        let colors = Array(repeating: SIMD3<Float>(0.55, 0.55, 0.58), count: vertices.count)

        return MergedMeshGeometry(
            vertices: vertices,
            normals: normals,
            indices: indices,
            vertexColors: colors
        )
    }

    static func computeVertexNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var accum = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
        let faceCount = indices.count / 3
        for face in 0..<faceCount {
            let i0 = Int(indices[face * 3])
            let i1 = Int(indices[face * 3 + 1])
            let i2 = Int(indices[face * 3 + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let e1 = vertices[i1] - vertices[i0]
            let e2 = vertices[i2] - vertices[i0]
            let normal = simd_cross(e1, e2)
            accum[i0] += normal
            accum[i1] += normal
            accum[i2] += normal
        }

        return accum.map { value in
            let length = simd_length(value)
            return length > 1e-6 ? value / length : SIMD3<Float>(0, 1, 0)
        }
    }
}
