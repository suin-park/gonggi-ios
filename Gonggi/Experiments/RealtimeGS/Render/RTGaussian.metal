#include <metal_stdlib>
using namespace metal;

// 실험 기능: 3D 가우시안 스플랫 렌더링.
// 각 가우시안은 세계 공분산 Sigma_w = R diag(s^2) R^T 를 갖고, 카메라 투영의 야코비안 J 로 화면 2D 공분산
// Sigma_2D = J W Sigma_w W^T J^T 를 만든다. 정렬된(먼 것 -> 가까운 것) 순서로 알파 합성한다.
// 버퍼 배치(가우시안당 float4 4개): [pos.xyz, opacity] [rgb, state] [scale.xyz, 0] [quat.xyzw]

struct RTUniforms {
    float4 rotRow0;   // 세계 -> CV 카메라 회전의 행 0 (xyz)
    float4 rotRow1;
    float4 rotRow2;
    float4 camPos;    // 세계 좌표 카메라 위치 (xyz)
    float4 intr;      // fx, fy, cx, cy (센서 픽셀)
    float4 viewport;  // 뷰 폭, 뷰 높이, 근평면 z, 디버그(임시 가우시안 색 구분)
    float4 mapA;      // 센서 픽셀 -> 뷰 픽셀 2x2: m00, m01, m10, m11
    float4 mapT;      // tx, ty, 0, 0
    float4 imgSize;   // 센서 영상 폭, 높이
};

struct RTVOut {
    float4 position [[position]];
    float4 color;
    float2 local;
};

vertex RTVOut rt_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        const device float4 *g [[buffer(0)]],
                        const device uint *order [[buffer(1)]],
                        constant RTUniforms &U [[buffer(2)]]) {
    RTVOut o;
    o.position = float4(2.0, 2.0, 0.0, 1.0);
    o.color = float4(0.0);
    o.local = float2(0.0);

    uint gi = order[iid];
    float4 a = g[gi * 4 + 0];
    float4 b = g[gi * 4 + 1];
    float4 c = g[gi * 4 + 2];
    float4 q = g[gi * 4 + 3];

    float3 d = a.xyz - U.camPos.xyz;
    float3 pc = float3(dot(U.rotRow0.xyz, d), dot(U.rotRow1.xyz, d), dot(U.rotRow2.xyz, d));
    if (pc.z < U.viewport.z) { return o; }

    float x = q.x, y = q.y, z = q.z, w = q.w;
    float3 col0 = float3(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + z * w), 2.0 * (x * z - y * w));
    float3 col1 = float3(2.0 * (x * y - z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + x * w));
    float3 col2 = float3(2.0 * (x * z + y * w), 2.0 * (y * z - x * w), 1.0 - 2.0 * (x * x + y * y));
    // M = R * diag(s): 열마다 크기를 곱한다. Sigma_w = M M^T
    float3 m0 = col0 * c.x, m1 = col1 * c.y, m2 = col2 * c.z;
    // T = W * M (W의 행으로 계산)
    float3 t0 = float3(dot(U.rotRow0.xyz, m0), dot(U.rotRow1.xyz, m0), dot(U.rotRow2.xyz, m0));
    float3 t1 = float3(dot(U.rotRow0.xyz, m1), dot(U.rotRow1.xyz, m1), dot(U.rotRow2.xyz, m1));
    float3 t2 = float3(dot(U.rotRow0.xyz, m2), dot(U.rotRow1.xyz, m2), dot(U.rotRow2.xyz, m2));

    float fx = U.intr.x, fy = U.intr.y;
    float iz = 1.0 / pc.z;
    float3 j0 = float3(fx * iz, 0.0, -fx * pc.x * iz * iz);
    float3 j1 = float3(0.0, fy * iz, -fy * pc.y * iz * iz);
    // P = J T (2x3): 행 A, B (각각 float3)
    float3 A = float3(dot(j0, t0), dot(j0, t1), dot(j0, t2));
    float3 B = float3(dot(j1, t0), dot(j1, t1), dot(j1, t2));
    // 센서 픽셀 -> 뷰 픽셀 선형 변환을 공분산에 적용: (Mv P)(Mv P)^T
    float3 A2 = U.mapA.x * A + U.mapA.y * B;
    float3 B2 = U.mapA.z * A + U.mapA.w * B;
    float sa = dot(A2, A2) + 0.3;
    float sb = dot(A2, B2);
    float sc = dot(B2, B2) + 0.3;

    float u = fx * pc.x * iz + U.intr.z;
    float v = fy * pc.y * iz + U.intr.w;
    float2 center = float2(U.mapA.x * u + U.mapA.y * v + U.mapT.x,
                           U.mapA.z * u + U.mapA.w * v + U.mapT.y);

    float mid = 0.5 * (sa + sc);
    float rad = sqrt(max(0.25 * (sa - sc) * (sa - sc) + sb * sb, 0.0));
    float l1 = mid + rad;
    float l2 = max(mid - rad, 1e-4);
    float2 e1 = float2(sb, l1 - sa);
    float len = length(e1);
    e1 = len > 1e-6 ? e1 / len : (sa >= sc ? float2(1.0, 0.0) : float2(0.0, 1.0));
    float2 e2 = float2(-e1.y, e1.x);
    float r1 = min(3.0 * sqrt(l1), 600.0);
    float r2 = min(3.0 * sqrt(l2), 600.0);

    // 화면 밖이면 그리지 않는다.
    float2 vp = U.viewport.xy;
    float margin = max(r1, r2);
    if (center.x < -margin || center.y < -margin || center.x > vp.x + margin || center.y > vp.y + margin) { return o; }

    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float2 px = center + e1 * (corner.x * r1) + e2 * (corner.y * r2);
    o.position = float4(2.0 * px.x / vp.x - 1.0, 1.0 - 2.0 * px.y / vp.y, 0.0, 1.0);
    o.local = corner * 3.0;
    float3 rgb = b.xyz;
    if (U.viewport.w > 0.5 && b.w < 0.5) { rgb = mix(rgb, float3(1.0, 0.55, 0.1), 0.5); }
    o.color = float4(rgb, a.w);
    return o;
}

fragment float4 rt_fragment(RTVOut in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    if (r2 > 9.0) { discard_fragment(); }
    float alpha = in.color.a * exp(-0.5 * r2);
    if (alpha < 1.0 / 255.0) { discard_fragment(); }
    return float4(in.color.rgb * alpha, alpha);   // 미리 곱한 알파
}

// 카메라 영상 배경 (센서 영상을 가우시안과 같은 변환으로 놓는다)
struct RTBGOut {
    float4 position [[position]];
    float2 uv;
};

vertex RTBGOut rt_bg_vertex(uint vid [[vertex_id]], constant RTUniforms &U [[buffer(0)]]) {
    float2 uv = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
    float2 s = uv * U.imgSize.xy;
    float2 vpx = float2(U.mapA.x * s.x + U.mapA.y * s.y + U.mapT.x,
                        U.mapA.z * s.x + U.mapA.w * s.y + U.mapT.y);
    RTBGOut o;
    o.position = float4(2.0 * vpx.x / U.viewport.x - 1.0, 1.0 - 2.0 * vpx.y / U.viewport.y, 0.0, 1.0);
    o.uv = uv;
    return o;
}

fragment float4 rt_bg_fragment(RTBGOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = tex.sample(s, in.uv).rgb * 0.55;   // 가우시안이 위에 보이도록 어둡게
    return float4(c, 1.0);
}
