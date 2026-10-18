import Foundation
import simd

/// 기존 지도를 현재 키프레임 시점으로 투영해 깊이 격자 예측을 만든다.
/// - 스테레오 탐색의 사전값(정답이 아니라 힌트): 반복 무늬 등 모호한 곳에서 지도와 같은 깊이를 택할 수 있게 한다.
/// - 새 관측과 지도가 얼마나 일치하는지(설명되는 영역 / 새로 드러난 영역 / 어긋난 영역) 계측.
/// - 일시정지 후 재개 때 이전 세그먼트 좌표계와 새 세그먼트가 맞는지 검증.
enum RTMapPrediction {
    struct Result {
        var z: [Float]           // 격자별 예측 깊이(camera-Z), 0 = 지도가 설명하지 않는 곳
        var covered = 0
    }

    /// minState 이상(후보·안정)의 가우시안만 사용한다. 격자 칸마다 가장 가까운 깊이(앞면)를 남긴다.
    static func predict(map: RTGaussianMap, frame: RTFrame, gw: Int, gh: Int, step: Int, segment: UInt16, minState: UInt8 = 1) -> Result {
        var z = [Float](repeating: 0, count: gw * gh)
        let K = frame.kSmall
        var covered = 0
        for i in 0..<map.count where map.alive[i] && map.segment[i] == segment && map.state[i] >= minState && map.state[i] <= 2 {
            let pc = frame.pose.worldToCam(map.pos[i])
            if pc.z < 0.2 || pc.z > 10 { continue }
            // 뒤쪽을 향한 면(카메라에서 보이지 않는 면)은 제외
            let view = simd_normalize(map.pos[i] - frame.pose.center)
            if simd_dot(map.nrm[i], -view) < 0.15 { continue }
            guard let uv = K.project(pc) else { continue }
            let gx = Int(uv.x) / step, gy = Int(uv.y) / step
            if uv.x < 0 || uv.y < 0 || gx >= gw || gy >= gh { continue }
            // 가우시안이 화면에서 덮는 격자 반경(칸)
            let rPx = max(map.scl[i].x, map.scl[i].y) * K.fx / pc.z
            let rc = max(0, min(2, Int((rPx / Float(step)).rounded())))
            for yy in max(0, gy - rc)...min(gh - 1, gy + rc) {
                for xx in max(0, gx - rc)...min(gw - 1, gx + rc) {
                    let k = yy * gw + xx
                    if z[k] == 0 { covered += 1; z[k] = pc.z } else if pc.z < z[k] { z[k] = pc.z }
                }
            }
        }
        return Result(z: z, covered: covered)
    }

    struct Agreement {
        var compared = 0         // 스테레오 확정 표본 중 예측이 있는 곳
        var agree = 0            // 깊이가 허용 오차 안
        var behind = 0           // 관측이 예측보다 멀다(지도가 앞을 막고 있음 = 어긋남)
        var nearer = 0           // 관측이 예측보다 가깝다(지도 뒤로 새 표면 또는 어긋남)
        var unexplained = 0      // 스테레오 확정 표본 중 예측이 없는 곳(새로 드러난 영역)
        var stereoValid = 0

        var agreeRatio: Double { compared > 0 ? Double(agree) / Double(compared) : 0 }
        var coverageRatio: Double { stereoValid > 0 ? Double(compared) / Double(stereoValid) : 0 }
    }

    static func compare(depth: RTDepthMap, prediction: Result) -> Agreement {
        var a = Agreement()
        for i in 0..<depth.z.count where depth.z[i] > 0 && depth.source[i] == RTDepthSource.stereo.rawValue && !depth.isAssisted(i) {
            a.stereoValid += 1
            let p = prediction.z[i]
            if p <= 0 { a.unexplained += 1; continue }
            a.compared += 1
            let tol = max(0.06, 0.08 * p)
            let d = depth.z[i] - p
            if abs(d) <= tol { a.agree += 1 } else if d > 0 { a.behind += 1 } else { a.nearer += 1 }
        }
        return a
    }

    /// 두 좌표계(이전 세그먼트 지도 vs 새 세그먼트 관측)가 맞는지 판정한다.
    /// 여러 키프레임에서 표본 수가 충분하고 일치 비율이 높을 때만 true.
    struct AlignmentVote {
        var compared = 0
        var agree = 0
        var keyframes = 0

        mutating func add(_ a: Agreement) { compared += a.compared; agree += a.agree; if a.compared >= 80 { keyframes += 1 } }
        var ratio: Double { compared > 0 ? Double(agree) / Double(compared) : 0 }

        func decide(minCompared: Int = 600, minKeyframes: Int = 3, minRatio: Double = 0.7) -> Bool {
            compared >= minCompared && keyframes >= minKeyframes && ratio >= minRatio
        }
    }
}
