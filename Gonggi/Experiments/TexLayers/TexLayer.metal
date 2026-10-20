#include <metal_stdlib>
using namespace metal;

// 텍스처 스플랫 레이어 렌더링(실험).
// 레이어 패스: 한 키프레임 레이어의 사각형(평면 4모서리 + 8×8 RGBA 텍스처)을 앞면만, z-버퍼와 알파 테스트(< 0.5 버림)로 그려 (색, 선형 깊이)를 얻는다.
// 합성 패스: 선택된 레이어(최대 8개)에서 화소마다 가중치 합이 가장 큰 깊이를 표면으로 정하고, 그 표면에 일치한 레이어만 시점 가중치로 혼합한다.
// 일치한 색의 분산이 크면 대표 관측 하나만 쓴다. 같은 표면에 동의하는 레이어가 부족한 화소는 합의된 화소 옆(가장자리)일 때만 남긴다. CPU 참조 TexLayerCPU와 같은 규칙.

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
    float4 w1;        // 가중치 4..7
    float4 p0;        // 레이어 수, 깊이 허용 비율, 색 분산 한계, 필요한 동의 레이어 수
    float4 p1;        // x: 가장자리 확장 화소, y: 레이어 텍스처/그리기 대상 배율, z: 동의 레이어를 셀 때의 깊이 허용 비율
};

struct TLVOut {
    float4 position [[position]];
    float3 uvz;                       // (u/z, v/z, 1/z): 선형 보간하면 평면 사각형의 원근 보정 텍스처 좌표가 된다
    uint quad [[flat]];
};

vertex TLVOut tl_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        const device float4 *corners [[buffer(0)]],
                        constant TLUniforms &U [[buffer(1)]],
                        constant float4 &clip [[buffer(2)]]) {
    TLVOut o;
    o.position = float4(2.0, 2.0, 0.0, 1.0);
    o.uvz = float3(0.0);
    o.quad = iid;
    // 뒷면 버림: 촬영한 쪽(앞면)에서 보일 때만 그린다. 법선·(사각형 − 카메라) > 0
    float3 c0 = corners[iid * 4 + 0].xyz;
    float3 c1 = corners[iid * 4 + 1].xyz;
    float3 c2 = corners[iid * 4 + 2].xyz;
    float3 nrm = cross(c1 - c0, c2 - c0);
    if (dot(nrm, c0 - U.camPos.xyz) <= 0.0) { return o; }
    // 표시 범위 구 밖의 사각형은 그리지 않는다(제품에서 멀리 떨어진 조각)
    float3 c3 = corners[iid * 4 + 3].xyz;
    if (distance((c0 + c3) * 0.5, clip.xyz) > clip.w) { return o; }
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

struct TLCons {
    float3 rgb;
    float z;
    int count;
};

// 한 화소의 합의(TexLayerCPU.consensus와 같은 규칙). 빈 깊이는 5e4 이상으로 지워 둔다(r16Float).
static TLCons tl_consensus(int2 xy, texture2d_array<float> C, texture2d_array<float> Z, constant TLCompose &P) {
    TLCons r;
    r.rgb = float3(0.0); r.z = 1e30; r.count = 0;
    int count = int(P.p0.x + 0.5);
    float tol = P.p0.y;
    float zs[8];
    float3 cs[8];
    float ws[8];
    int nv = 0;
    for (int i = 0; i < 8; i++) {
        if (i >= count) { break; }
        float z = Z.read(uint2(xy), uint(i)).x;
        if (z < 50000.0) {
            zs[nv] = z;
            cs[nv] = C.read(uint2(xy), uint(i)).rgb;
            ws[nv] = (i < 4) ? P.w0[i] : P.w1[i - 4];
            nv++;
        }
    }
    if (nv == 0) { return r; }
    int bestK = 0;
    float bestKey = -1e30;
    for (int a = 0; a < nv; a++) {
        float tolA = tol * max(zs[a], 0.3);
        float support = 0.0;
        for (int b = 0; b < nv; b++) { if (fabs(zs[b] - zs[a]) < tolA) { support += ws[b]; } }
        float key = support - 1e-3 * zs[a];
        if (key > bestKey) { bestKey = key; bestK = a; }
    }
    float zb = zs[bestK];
    float tolB = tol * max(zb, 0.3);
    float tolAgree = P.p1.z * max(zb, 0.3);
    float wmaxAll = 0.0;
    for (int i = 0; i < 8; i++) { if (i >= count) { break; } wmaxAll = max(wmaxAll, (i < 4) ? P.w0[i] : P.w1[i - 4]); }
    float wCountMin = P.p1.w * wmaxAll;
    float3 num = float3(0.0);
    float den = 0.0;
    int cnt = 0;
    int repK = -1;
    float repW = -1e30;
    for (int b = 0; b < nv; b++) {
        if (fabs(zs[b] - zb) < tolAgree && ws[b] >= wCountMin) { cnt++; }
        if (fabs(zs[b] - zb) < tolB) {
            num += cs[b] * ws[b]; den += ws[b];
            if (ws[b] > repW) { repW = ws[b]; repK = b; }
        }
    }
    if (den <= 0.0 || repK < 0) { return r; }
    float3 avg = num / den;
    float spread = 0.0;
    for (int b = 0; b < nv; b++) {
        if (fabs(zs[b] - zb) < tolB) { float3 d = cs[b] - avg; spread += dot(d, d) * ws[b]; }
    }
    spread /= den;
    r.rgb = (spread > P.p0.z) ? cs[repK] : avg;
    r.z = zb; r.count = cnt;
    return r;
}

fragment float4 tl_compose_fragment(float4 pos [[position]],
                                    texture2d_array<float> C [[texture(0)]],
                                    texture2d_array<float> Z [[texture(1)]],
                                    constant TLCompose &P [[buffer(0)]]) {
    int w = int(C.get_width()), h = int(C.get_height());
    int2 xy = int2(min(int(pos.x * P.p1.y), w - 1), min(int(pos.y * P.p1.y), h - 1));
    TLCons r = tl_consensus(xy, C, Z, P);
    if (r.count == 0) { discard_fragment(); }
    int need = max(1, int(P.p0.w + 0.5));
    if (r.count < need) {
        bool keep = false;
        int fr = max(1, int(P.p1.x + 0.5));
        const int dx[8] = { -1, 0, 1, -1, 1, -1, 0, 1 };
        const int dy[8] = { -1, -1, -1, 0, 0, 1, 1, 1 };
        for (int d = 0; d < 8; d++) {
            int2 q = int2(xy.x + dx[d] * fr, xy.y + dy[d] * fr);
            if (q.x < 0 || q.y < 0 || q.x >= w || q.y >= h) { continue; }
            TLCons n = tl_consensus(q, C, Z, P);
            if (n.count >= need) { keep = true; break; }
        }
        if (!keep) { discard_fragment(); }
    }
    return float4(r.rgb, 1.0);
}
