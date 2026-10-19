#include <metal_stdlib>
using namespace metal;

// 텍스처 스플랫 레이어 렌더링(실험).
// 레이어 패스: 한 키프레임 레이어의 사각형(평면 4모서리 + 8×8 RGBA 텍스처)을 z-버퍼와 알파 테스트(< 0.5 버림)로 그려 (색, 선형 깊이)를 얻는다.
// 합성 패스: K개 레이어 중 가장 가까운 유효 깊이를 기준으로 깊이가 일관된 레이어만 시점 가중치로 평균한다(CPU 참조 TexLayerCPU와 같은 규칙).

struct TLUniforms {
    float4 rotRow0;   // 세계 -> CV 카메라 회전의 행 (xyz)
    float4 rotRow1;
    float4 rotRow2;
    float4 camPos;
    float4 intr;      // fx, fy, cx, cy (센서 픽셀)
    float4 viewport;  // 뷰 폭, 뷰 높이, 근평면 z, 예약
    float4 mapA;      // 센서 픽셀 -> 뷰 픽셀 2x2
    float4 mapT;
    float4 imgSize;
};

struct TLCompose {
    float4 w0;        // 가중치 0..3
    float4 w1;        // 가중치 4, 레이어 수, 깊이 허용 비율, 예약
    float4 scale;     // x: 레이어 텍스처/그리기 대상 배율
};

struct TLVOut {
    float4 position [[position]];
    float3 uvz;                       // (u/z, v/z, 1/z): 선형 보간하면 평면 사각형의 원근 보정 텍스처 좌표가 된다
    uint quad [[flat]];
};

vertex TLVOut tl_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        const device float4 *corners [[buffer(0)]],
                        constant TLUniforms &U [[buffer(1)]]) {
    TLVOut o;
    o.position = float4(2.0, 2.0, 0.0, 1.0);
    o.uvz = float3(0.0);
    o.quad = iid;
    float3 pcs[4];
    for (uint k = 0; k < 4; k++) {
        float3 d = corners[iid * 4 + k].xyz - U.camPos.xyz;
        pcs[k] = float3(dot(U.rotRow0.xyz, d), dot(U.rotRow1.xyz, d), dot(U.rotRow2.xyz, d));
        if (pcs[k].z < U.viewport.z) { return o; }       // 근평면 뒤에 걸치면 사각형 전체를 버린다
    }
    float3 pc = pcs[vid];
    float iz = 1.0 / pc.z;
    float u = U.intr.x * pc.x * iz + U.intr.z;
    float v = U.intr.y * pc.y * iz + U.intr.w;
    float2 vpx = float2(U.mapA.x * u + U.mapA.y * v + U.mapT.x, U.mapA.z * u + U.mapA.w * v + U.mapT.y);
    float2 uv = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
    o.uvz = float3(uv.x * iz, uv.y * iz, iz);
    // 깊이 버퍼: 1/z에 선형인 값(화면 공간에서 선형 보간이 정확하다). 가까울수록 작다.
    o.position = float4(2.0 * vpx.x / U.viewport.x - 1.0, 1.0 - 2.0 * vpx.y / U.viewport.y, 1.0 - U.viewport.z * iz, 1.0);
    return o;
}

struct TLFOut {
    float4 color [[color(0)]];
    float4 depth [[color(1)]];
};

fragment TLFOut tl_fragment(TLVOut in [[stage_in]], const device uchar4 *tex [[buffer(0)]]) {
    float iz = in.uvz.z;
    float u = in.uvz.x / iz, v = in.uvz.y / iz;
    // 8×8 텍셀 쌍선형(가장자리 고정). 텍셀 중심 = (i + 0.5) / 8
    float fu = clamp(u, 0.0, 1.0) * 8.0 - 0.5;
    float fv = clamp(v, 0.0, 1.0) * 8.0 - 0.5;
    int iu = int(floor(fu)), iv = int(floor(fv));
    float du = fu - float(iu), dv = fv - float(iv);
    int iu0 = clamp(iu, 0, 7), iu1 = clamp(iu + 1, 0, 7), iv0 = clamp(iv, 0, 7), iv1 = clamp(iv + 1, 0, 7);
    uint base = in.quad * 64;
    float4 t00 = float4(tex[base + uint(iv0 * 8 + iu0)]);
    float4 t10 = float4(tex[base + uint(iv0 * 8 + iu1)]);
    float4 t01 = float4(tex[base + uint(iv1 * 8 + iu0)]);
    float4 t11 = float4(tex[base + uint(iv1 * 8 + iu1)]);
    float4 c = mix(mix(t00, t10, du), mix(t01, t11, du), dv) / 255.0;
    if (c.a < 0.5) { discard_fragment(); }
    TLFOut o;
    o.color = float4(c.rgb, 1.0);
    o.depth = float4(1.0 / iz, 0.0, 0.0, 0.0);
    return o;
}

vertex float4 tl_compose_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    return float4(p, 0.0, 1.0);
}

fragment float4 tl_compose_fragment(float4 pos [[position]],
                                    texture2d<float> c0 [[texture(0)]], texture2d<float> c1 [[texture(1)]], texture2d<float> c2 [[texture(2)]],
                                    texture2d<float> c3 [[texture(3)]], texture2d<float> c4 [[texture(4)]],
                                    texture2d<float> z0 [[texture(5)]], texture2d<float> z1 [[texture(6)]], texture2d<float> z2 [[texture(7)]],
                                    texture2d<float> z3 [[texture(8)]], texture2d<float> z4 [[texture(9)]],
                                    constant TLCompose &P [[buffer(0)]]) {
    uint w = c0.get_width(), h = c0.get_height();
    uint2 xy = uint2(min(uint(pos.x * P.scale.x), w - 1), min(uint(pos.y * P.scale.x), h - 1));
    float zs[5] = { z0.read(xy).x, z1.read(xy).x, z2.read(xy).x, z3.read(xy).x, z4.read(xy).x };
    float4 cs[5] = { c0.read(xy), c1.read(xy), c2.read(xy), c3.read(xy), c4.read(xy) };
    float ws[5] = { P.w0.x, P.w0.y, P.w0.z, P.w0.w, P.w1.x };
    int count = int(P.w1.y + 0.5);
    float dmin = 1e30;
    for (int i = 0; i < 5; i++) { if (i < count && zs[i] < 1e8) { dmin = min(dmin, zs[i]); } }
    if (dmin > 1e8) { discard_fragment(); }
    float tol = P.w1.z * max(dmin, 0.3);
    float3 num = float3(0.0);
    float den = 0.0;
    for (int i = 0; i < 5; i++) {
        if (i < count && zs[i] < 1e8 && fabs(zs[i] - dmin) < tol) { num += cs[i].rgb * ws[i]; den += ws[i]; }
    }
    if (den <= 0.0) { discard_fragment(); }
    return float4(num / den, 1.0);
}
