#include <metal_stdlib>
using namespace metal;

// 실험 기능: 실시간 공간 생성 V2 렌더링.
// 표면 패치(불투명 사각형)를 깊이 버퍼와 함께 그리고, 각 화소에서 원본 키프레임(source) 몇 장을 투영해 색을 읽는다.
// 규칙(화면 밖·뒷면·깊이 불일치 가림 → 해상도·각도 가중 → 같은 색이면 블렌딩/아니면 최선 한 장)은
// SV2Appearance.swift의 SV2Shading(CPU 기준 구현)과 같다.
// 패치 버퍼 배치(패치당 float4 4개): [center.xyz, hu] [normal.xyz, hv] [tu.xyz, flags] [color.rgb, id]
// flags = state + 4*planeFill + 8*edge

struct SV2View {
    float4 rotRow0;   // 세계 -> CV 카메라 회전의 행
    float4 rotRow1;
    float4 rotRow2;
    float4 camPos;
    float4 intr;      // fx, fy, cx, cy (뷰 변환 전 영상 픽셀)
    float4 viewport;  // 뷰 폭, 높이, near, far
    float4 mapA;      // 영상 픽셀 -> 뷰 픽셀 2x2
    float4 mapT;      // tx, ty, 0, 0
    float4 opts;      // x: 임시 패치 색 구분, y: 질감 미지원 색 구분, z: 임시 패치 표시(1/0), w: 0
    float4 imgSize;   // 카메라 배경 영상 크기(센서 픽셀)
};

struct SV2SourceU {
    float4 rotRow0;
    float4 rotRow1;
    float4 rotRow2;
    float4 camPos;    // xyz, gain
    float4 intr;      // fx, fy, cx, cy (텍스처 픽셀)
    float4 sizes;     // texW, texH, depthW, depthH
    float4 params;    // weight, valid, 0, 0
};

struct SV2Sources {
    SV2SourceU s[4];
    int4 info;        // x: source 수
};

struct SV2VOut {
    float4 position [[position]];
    float3 world;
    float viewZ;
    float3 normal [[flat]];
    float4 color [[flat]];
    float flags [[flat]];
};

vertex SV2VOut sv2_vertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device float4 *g [[buffer(0)]],
                          constant SV2View &V [[buffer(1)]]) {
    SV2VOut o;
    o.position = float4(2.0, 2.0, 2.0, 1.0);
    o.world = float3(0.0);
    o.viewZ = 1.0;
    o.normal = float3(0.0, 0.0, 1.0);
    o.color = float4(0.0);
    o.flags = 0.0;

    float4 a = g[iid * 4 + 0];
    float4 b = g[iid * 4 + 1];
    float4 c = g[iid * 4 + 2];
    float4 d = g[iid * 4 + 3];
    int fl = int(c.w + 0.5);
    int state = fl & 3;
    if (V.opts.z < 0.5 && state == 0) { return o; }

    float3 n = normalize(b.xyz);
    float3 tu = c.xyz;
    float3 tv = cross(n, tu);
    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float3 wp = a.xyz + tu * (corner.x * a.w) + tv * (corner.y * b.w);

    float3 dc = a.xyz - V.camPos.xyz;
    float zc0 = dot(V.rotRow2.xyz, dc);
    if (zc0 < V.viewport.z + 0.02) { return o; }

    float3 dd = wp - V.camPos.xyz;
    float3 pc = float3(dot(V.rotRow0.xyz, dd), dot(V.rotRow1.xyz, dd), dot(V.rotRow2.xyz, dd));
    float zc = max(pc.z, V.viewport.z);
    float2 uv = float2(V.intr.x * pc.x / zc + V.intr.z, V.intr.y * pc.y / zc + V.intr.w);
    // 영상 픽셀 중심 규약(정수가 중심)을 Metal 창 좌표(중심이 +0.5)로 바꾼다.
    float2 px = float2(V.mapA.x * uv.x + V.mapA.y * uv.y + V.mapT.x,
                       V.mapA.z * uv.x + V.mapA.w * uv.y + V.mapT.y) + float2(0.5);
    float nearZ = V.viewport.z, farZ = V.viewport.w;
    float A = farZ / (farZ - nearZ);
    float B = -nearZ * farZ / (farZ - nearZ);
    float ndcx = 2.0 * px.x / V.viewport.x - 1.0;
    float ndcy = 1.0 - 2.0 * px.y / V.viewport.y;
    o.position = float4(ndcx * zc, ndcy * zc, A * zc + B, zc);
    o.world = wp;
    o.viewZ = zc;
    o.normal = n;
    o.color = float4(d.xyz, float(state));
    o.flags = c.w;
    return o;
}

// 원본 키프레임 source의 깊이(가림 검사용) 패스: 카메라 Z를 R32Float에 쓴다.
fragment float4 sv2_depth_fragment(SV2VOut in [[stage_in]]) {
    return float4(in.viewZ, 0.0, 0.0, 0.0);
}

inline float3 sv2_sample(int i, float2 uv,
                         texture2d<float> t0, texture2d<float> t1, texture2d<float> t2, texture2d<float> t3) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge, coord::normalized);
    switch (i) {
        case 0: return t0.sample(smp, uv).rgb;
        case 1: return t1.sample(smp, uv).rgb;
        case 2: return t2.sample(smp, uv).rgb;
        default: return t3.sample(smp, uv).rgb;
    }
}

inline float sv2_depth(int i, uint2 p,
                       texture2d<float> d0, texture2d<float> d1, texture2d<float> d2, texture2d<float> d3) {
    switch (i) {
        case 0: return d0.read(p).r;
        case 1: return d1.read(p).r;
        case 2: return d2.read(p).r;
        default: return d3.read(p).r;
    }
}

// 원자 연산(통계)이 있어도 깊이 검사를 먼저 해 가려진 화소의 텍스처 읽기를 피한다.
[[early_fragment_tests]]
fragment float4 sv2_fragment(SV2VOut in [[stage_in]],
                             constant SV2View &V [[buffer(0)]],
                             constant SV2Sources &S [[buffer(1)]],
                             device atomic_uint *counters [[buffer(2)]],
                             texture2d<float> t0 [[texture(0)]],
                             texture2d<float> t1 [[texture(1)]],
                             texture2d<float> t2 [[texture(2)]],
                             texture2d<float> t3 [[texture(3)]],
                             texture2d<float> d0 [[texture(4)]],
                             texture2d<float> d1 [[texture(5)]],
                             texture2d<float> d2 [[texture(6)]],
                             texture2d<float> d3 [[texture(7)]]) {
    float3 n = normalize(in.normal);
    float3 X = in.world;
    float zt = in.viewZ;
    float3 cols[4];
    float ws[4];
    int nc = 0;
    int nOccl = 0;
    int nOut = 0;
    int count = min(S.info.x, 4);
    for (int i = 0; i < count; i++) {
        SV2SourceU s = S.s[i];
        if (s.params.y < 0.5) { continue; }
        float3 d = X - s.camPos.xyz;
        float3 pc = float3(dot(s.rotRow0.xyz, d), dot(s.rotRow1.xyz, d), dot(s.rotRow2.xyz, d));
        if (pc.z < 0.05) { nOut++; continue; }
        float u = s.intr.x * pc.x / pc.z + s.intr.z;
        float v = s.intr.y * pc.y / pc.z + s.intr.w;
        float tw = s.sizes.x, th = s.sizes.y;
        if (u < 1.0 || v < 1.0 || u > tw - 2.0 || v > th - 2.0) { nOut++; continue; }
        float3 dirS = normalize(s.camPos.xyz - X);
        float cosS = dot(n, dirS);
        if (cosS < 0.15) { nOut++; continue; }
        float dw = s.sizes.z, dh = s.sizes.w;
        int dx = clamp(int(u * dw / tw), 0, int(dw) - 1);
        int dy = clamp(int(v * dh / th), 0, int(dh) - 1);
        float dz = sv2_depth(i, uint2(uint(dx), uint(dy)), d0, d1, d2, d3);
        float bias = 0.012 + 0.02 * pc.z + 0.04 * pc.z * (1.0 - cosS);
        if (dz < pc.z - bias) { nOccl++; continue; }
        float rf = clamp(zt / pc.z, 0.3, 1.2);
        float w = s.params.x * cosS * cosS * rf * rf;
        float3 col = sv2_sample(i, float2((u + 0.5) / tw, (v + 0.5) / th), t0, t1, t2, t3);
        float g = clamp(s.camPos.w, 0.5, 2.0);
        cols[nc] = clamp(col / g, 0.0, 1.0);
        ws[nc] = w;
        nc++;
    }

    float3 outColor = in.color.rgb;
    bool supported = false;
    bool disagree = false;
    if (nc > 0) {
        supported = true;
        int bi = 0;
        for (int i = 1; i < nc; i++) { if (ws[i] > ws[bi]) { bi = i; } }
        outColor = cols[bi];
        if (nc > 1) {
            float wsum = 0.0;
            float3 csum = float3(0.0);
            bool agree = true;
            for (int i = 0; i < nc; i++) {
                if (ws[i] >= 0.35 * ws[bi]) {
                    float3 df = abs(cols[i] - cols[bi]);
                    if (max(df.x, max(df.y, df.z)) > 0.16) { agree = false; break; }
                    wsum += ws[i];
                    csum += cols[i] * ws[i];
                }
            }
            if (agree && wsum > 0.0) { outColor = csum / wsum; } else { disagree = true; }
        }
    } else {
        // 질감을 읽을 source가 없다: 대체 평균 색. 옵션이 켜져 있으면 눈에 띄게 구분한다.
        if (V.opts.y > 0.5) { outColor = mix(outColor, float3(0.9, 0.2, 0.9), 0.5); }
    }
    if (V.opts.x > 0.5 && int(in.color.a) == 0) { outColor = mix(outColor, float3(1.0, 0.55, 0.1), 0.5); }

    // 통계: 화소의 1/16만 센다(원자 연산 경합 방지).
    uint px = uint(in.position.x), py = uint(in.position.y);
    if (((px ^ (py * 7u)) & 15u) == 0u) {
        atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);
        if (supported) { atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed); }
        else if (nOccl > 0) { atomic_fetch_add_explicit(&counters[3], 1u, memory_order_relaxed); }
        else { atomic_fetch_add_explicit(&counters[2], 1u, memory_order_relaxed); }
        if (disagree) { atomic_fetch_add_explicit(&counters[4], 1u, memory_order_relaxed); }
        if (nOccl > 0) { atomic_fetch_add_explicit(&counters[5], uint(nOccl), memory_order_relaxed); }
        if (nOut > 0) { atomic_fetch_add_explicit(&counters[6], uint(nOut), memory_order_relaxed); }
    }
    return float4(outColor, 1.0);
}

// 카메라 영상 배경(명시적 비교 옵션에서만 쓴다)
struct SV2BGOut {
    float4 position [[position]];
    float2 uv;
};

vertex SV2BGOut sv2_bg_vertex(uint vid [[vertex_id]], constant SV2View &V [[buffer(0)]]) {
    float2 uv = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
    float2 s = uv * V.imgSize.xy;
    float2 vpx = float2(V.mapA.x * s.x + V.mapA.y * s.y + V.mapT.x,
                        V.mapA.z * s.x + V.mapA.w * s.y + V.mapT.y);
    SV2BGOut o;
    o.position = float4(2.0 * vpx.x / V.viewport.x - 1.0, 1.0 - 2.0 * vpx.y / V.viewport.y, 1.0, 1.0);
    o.uv = uv;
    return o;
}

fragment float4 sv2_bg_fragment(SV2BGOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(tex.sample(s, in.uv).rgb * 0.55, 1.0);
}
