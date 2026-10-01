#include <metal_stdlib>
using namespace metal;

// Urutan & tipe HARUS identik dengan GPUVHSUniforms di VHSFilter.swift (semua 4 byte).
struct VHSUniforms {
    uint  sourceKind;     // 0 = BGRA, 1 = YCbCr 4:2:2 packed
    uint  fullRange;
    uint  matrixKind;     // 0 = 709, 1 = 2020
    uint  osdEnabled;
    uint  frameIndex;
    uint  width;
    uint  height;
    uint  effectsOn;      // 0 = hanya decode (+OSD)
    float time;
    float chromaBlur;     // px virtual (grid 640)
    float chromaDelay;
    float aberration;
    float lowRes;
    float scanlines;
    float grain;
    float jello;
    float saturation;
    float glitchY;        // <0 = tidak ada band
    float glitchH;        // setengah tinggi band (ternormalisasi)
    float glitchShift;    // px virtual
    float dropY;          // <0 = tidak ada dropout
    float dropX0;
    float dropX1;
    float headSwitch;
};

constant float3 kVHSLuma = float3(0.2126, 0.7152, 0.0722);

static inline uint vhs_pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
static inline float vhs_rand(uint2 p, uint seed) {
    return float(vhs_pcg(p.x + vhs_pcg(p.y + vhs_pcg(seed)))) / 4294967295.0;
}

static float3 vhs_fetch(texture2d<float> tex, float2 uv, constant VHSUniforms& u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, uv);
    if (u.sourceKind == 0) return saturate(c.rgb);
    float y, cb, cr;                                   // r = Cr, g = Y, b = Cb
    if (u.fullRange != 0) { y = c.g; cb = c.b - 128.0 / 255.0; cr = c.r - 128.0 / 255.0; }
    else { y = (c.g * 255.0 - 16.0) / 219.0; cb = (c.b * 255.0 - 128.0) / 224.0; cr = (c.r * 255.0 - 128.0) / 224.0; }
    float3 rgb = (u.matrixKind == 0)
        ? float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb)
        : float3(y + 1.4746 * cr, y - 0.16455 * cb - 0.57135 * cr, y + 1.8814 * cb);
    return saturate(rgb);
}

static inline float3 vhs_ycc(float3 rgb) {
    float y = dot(rgb, kVHSLuma);
    return float3(y, (rgb.b - y) / 1.8556, (rgb.r - y) / 1.5748);
}
static inline float3 vhs_rgb(float y, float cb, float cr) {
    float r = y + 1.5748 * cr, b = y + 1.8556 * cb;
    return float3(r, (y - 0.2126 * r - 0.0722 * b) / 0.7152, b);
}

kernel void vhs_effect(texture2d<float> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       texture2d<float> osd [[texture(2)]],
                       constant VHSUniforms& u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.width || gid.y >= u.height) return;
    float W = float(u.width), H = float(u.height);
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float3 rgb;

    if (u.effectsOn == 0) {
        rgb = vhs_fetch(src, uv, u);
    } else {
        float t = u.time;
        float ln = uv.y * 480.0;                                   // resolusi vertikal analog
        float2 p = uv;
        p.y = mix(uv.y, (floor(ln) + 0.5) / 480.0, u.lowRes);

        // --- "jello" + tracking band + head-switching (semua = pergeseran horizontal per baris)
        float dx = u.jello * (sin(uv.y * 38.0 + t * 2.7) * 0.35 + sin(uv.y * 9.0 - t * 1.3) * 0.5);
        float band = 0.0;
        if (u.glitchY >= 0.0) {
            float d = fabs(uv.y - u.glitchY);
            if (d < u.glitchH) {
                band = 1.0 - d / u.glitchH;
                dx += u.glitchShift * band * (0.6 + 0.8 * vhs_rand(uint2(3u, uint(ln)), u.frameIndex));
            }
        }
        float hs = smoothstep(0.965, 1.0, uv.y);
        if (hs > 0.0) dx += (vhs_rand(uint2(1u, uint(ln)), u.frameIndex) - 0.5) * 24.0 * hs * 0.8;
        p.x += dx / 640.0;

        // --- aberrasi kromatik (membesar ke tepi frame)
        float ab = u.aberration * (1.0 + 3.0 * fabs(uv.x - 0.5)) / 640.0;
        float3 cR = vhs_fetch(src, p + float2( ab, 0.0), u);
        float3 cG = vhs_fetch(src, p, u);
        float3 cB = vhs_fetch(src, p + float2(-ab, 0.0), u);
        float3 split = float3(cR.r, cG.g, cB.b);

        // --- luma sedikit lembut (bandwidth analog)
        float ls = (0.4 + 0.8 * u.lowRes) / 640.0;
        float yA = dot(vhs_fetch(src, p + float2( ls, 0.0), u), kVHSLuma);
        float yB = dot(vhs_fetch(src, p + float2(-ls, 0.0), u), kVHSLuma);
        float y = 0.5 * dot(split, kVHSLuma) + 0.25 * (yA + yB);

        // --- chroma di-blur + tertunda (7 tap segitiga); Cr/Cb diambil dari posisi R/B yang bergeser
        float stepX = max(u.chromaBlur, 0.001) / 640.0;
        float delay = u.chromaDelay / 640.0;
        float cb = 0.0, cr = 0.0, wsum = 0.0;
        for (int k = -3; k <= 3; ++k) {
            float w = 4.0 - fabs(float(k));
            float2 o = float2(delay + float(k) * stepX, 0.0);
            cr += w * vhs_ycc(vhs_fetch(src, p + o + float2( ab, 0.0), u)).z;
            cb += w * vhs_ycc(vhs_fetch(src, p + o + float2(-ab, 0.0), u)).y;
            wsum += w;
        }
        rgb = vhs_rgb(y, cb / wsum, cr / wsum);

        // --- grading: desaturasi + black lift + scanline
        float ly = dot(rgb, kVHSLuma);
        rgb = mix(float3(ly), rgb, u.saturation);
        rgb = rgb * 0.96 + 0.02;
        float sc = 0.5 + 0.5 * cos(uv.y * 480.0 * 6.2831853);
        rgb *= 1.0 - u.scanlines * sc * 0.6;

        // --- noise di dalam band tracking + dropout putih
        if (band > 0.0) rgb = mix(rgb, float3(vhs_rand(uint2(gid.x / 3u, gid.y / 2u), u.frameIndex)), 0.28 * band);
        if (u.dropY >= 0.0 && fabs(uv.y - u.dropY) < 0.6 / 480.0 && uv.x > u.dropX0 && uv.x < u.dropX1) {
            rgb = mix(rgb, float3(1.0), 0.55 + 0.35 * vhs_rand(uint2(gid.x / 2u, 0u), u.frameIndex));
        }

        // --- grain bergerak (luma + sedikit chroma)
        float cell = max(1.0, W / 640.0 * 0.9);
        uint2 gp = uint2(float2(gid) / cell);
        float n = vhs_rand(gp, u.frameIndex) - 0.5;
        float3 cn = float3(vhs_rand(gp + uint2(7919u, 13u), u.frameIndex),
                           vhs_rand(gp + uint2(31u, 104729u), u.frameIndex),
                           vhs_rand(gp + uint2(577u, 3571u), u.frameIndex)) - 0.5;
        rgb += u.grain * (n * 0.20 + cn * 0.06);
    }

    // --- OSD (layer kecil, di-upscale nearest-neighbor -> piksel kotak)
    if (u.osdEnabled != 0) {
        constexpr sampler ns(filter::nearest, address::clamp_to_edge);
        float4 o = osd.sample(ns, uv);                 // premultiplied
        rgb = o.rgb + rgb * (1.0 - o.a);
    }
    dst.write(float4(saturate(rgb), 1.0), gid);
}
