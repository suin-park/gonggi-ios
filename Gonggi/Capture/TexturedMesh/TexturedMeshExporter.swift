import Foundation
import ModelIO
import simd
import UIKit

/// Exports textured mesh to USDZ for local preview.
enum TexturedMeshExporter {
    enum ExportError: LocalizedError {
        case emptyMesh
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .emptyMesh: return "Mesh is empty"
            case .writeFailed: return "Failed to write textured mesh"
            }
        }
    }

    static func exportUSDZ(mesh: MergedMeshGeometry, to url: URL) throws {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else {
            throw ExportError.emptyMesh
        }

        let allocator = MDLMeshBufferDataAllocator()
        var interleaved = Data()
        interleaved.reserveCapacity(mesh.vertices.count * 48)

        for index in mesh.vertices.indices {
            let position = mesh.vertices[index]
            let normal = mesh.normals[index]
            let color = mesh.vertexColors[index]
            interleaved.append(contentsOf: [
                position.x, position.y, position.z,
                normal.x, normal.y, normal.z,
                color.x, color.y, color.z,
            ].withUnsafeBytes { Data($0) })
        }

        let vertexBuffer = allocator.newBuffer(with: interleaved, type: .vertex)
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: 12,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[2] = MDLVertexAttribute(
            name: MDLVertexAttributeColor,
            format: .float3,
            offset: 24,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: 36)

        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: mesh.indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: mesh.vertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )

        let asset = MDLAsset()
        asset.add(mdlMesh)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try asset.export(to: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.writeFailed
        }
    }

    static func writeReport(_ report: TexturedMeshReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }
}
