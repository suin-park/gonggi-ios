import CoreGraphics
import Foundation
import simd
import UIKit

/// Projects captured RGB keyframes onto merged mesh vertices.
enum TextureProjector {
    struct Result: Equatable {
        let mesh: MergedMeshGeometry
        let texturedVertexCount: Int
        let texturedCoveragePercent: Double
    }

    static func project(
        mesh: MergedMeshGeometry,
        keyframes: [CaptureKeyframeRecord],
        keyframeDirectory: URL
    ) throws -> Result {
        guard !mesh.vertices.isEmpty else {
            return Result(mesh: mesh, texturedVertexCount: 0, texturedCoveragePercent: 0)
        }

        var colors = mesh.vertexColors
        var texturedCount = 0

        let decodedKeyframes: [(CaptureKeyframeRecord, CGImage)] = try keyframes.compactMap { record in
            let url = keyframeDirectory.appendingPathComponent(record.fileName)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data)?.cgImage else {
                return nil
            }
            return (record, image)
        }

        for vertexIndex in mesh.vertices.indices {
            let world = mesh.vertices[vertexIndex]
            let normal = mesh.normals[vertexIndex]

            var bestScore: Float = -1
            var bestColor: SIMD3<Float>?

            for (record, image) in decodedKeyframes {
                guard let projected = CameraProjection.project(
                    worldPoint: world,
                    worldNormal: normal,
                    cameraTransform: record.cameraTransform,
                    intrinsics: record.intrinsics
                ) else { continue }

                let score = CameraProjection.scoreProjection(projected)
                guard score > bestScore else { continue }

                if let rgb = sampleRGB(from: image, pixel: projected.pixel) {
                    bestScore = score
                    bestColor = rgb
                }
            }

            if let bestColor {
                colors[vertexIndex] = bestColor
                texturedCount += 1
            }
        }

        let coverage = mesh.vertices.isEmpty
            ? 0
            : Double(texturedCount) / Double(mesh.vertices.count) * 100

        return Result(
            mesh: MergedMeshGeometry(
                vertices: mesh.vertices,
                normals: mesh.normals,
                indices: mesh.indices,
                vertexColors: colors
            ),
            texturedVertexCount: texturedCount,
            texturedCoveragePercent: coverage
        )
    }

    static func sampleRGB(from image: CGImage, pixel: SIMD2<Float>) -> SIMD3<Float>? {
        let width = image.width
        let height = image.height
        let x = min(max(Int(pixel.x.rounded()), 0), width - 1)
        let y = min(max(Int(pixel.y.rounded()), 0), height - 1)

        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        let offset = y * bytesPerRow + x * bytesPerPixel
        let isBGRA = image.bitmapInfo.contains(.byteOrder32Little)

        let r: Float
        let g: Float
        let b: Float
        if isBGRA {
            b = Float(bytes[offset]) / 255
            g = Float(bytes[offset + 1]) / 255
            r = Float(bytes[offset + 2]) / 255
        } else {
            r = Float(bytes[offset]) / 255
            g = Float(bytes[offset + 1]) / 255
            b = Float(bytes[offset + 2]) / 255
        }
        return SIMD3<Float>(r, g, b)
    }
}
