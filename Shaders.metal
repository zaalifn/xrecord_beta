#include <metal_stdlib>
using namespace metal;

// Urutan HARUS identik dengan GPUUniforms di MetalPipeline.swift (semua field 4 byte).
struct Uniforms {
    uint  sourceKind;      // 0 = BGRA, 1 = YCbCr 4:2:2 packed
    uint  fullRange;
    uint  matrixKind;      // 0 = 709, 1 = 2020
    uint  lutEnabled;
    uint  zebraEnabled;
    uint  peakingEnabled;
    uint  gridW;
    uint  gridH;
    float zebraLow;
    float zebraHigh;
    float peakingThreshold;
    float texelX;
    float texelY;
    float time;
    float waveGain;
    float vecGain;
    float histScale;
};

constant float3 kLuma709 = float3(0.2126, 0.7152, 0.0722);
constant float3 kChan[3] = { float3(1.0, 0.25, 0.25), float3(0.25, 1.0, 0.25), float3(0.35, 0.5, 1.0) };

// Decode sumber -> RGB (sinyal ASLI kamera, sebelum LUT)
static float3 decodeSource(texture2d<float> tex, float2 uv, constant Uniforms& u) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(smp, uv);
    if (u.sourceKind == 0) return saturate(c.rgb);

    // Tekstur .bgrg422 / .gbgr422: r = Cr, g = Y, b = Cb (verifikasi dengan color bars kamera)
    float y, cb, cr;
    if (u.fullRange != 0) {
        y = c.g; cb = c.b - 128.0 / 255.0; cr = c.r - 128.0 / 255.0;
    } else {
        y  = (c.g * 255.0 -  16.0) / 219.0;
        cb = (c.b * 255.0 - 128.0) / 224.0;
        cr = (c.r * 255.0 - 128.0) / 224.0;
    }
    float3 rgb;
    if (u.matrixKind == 0) {
        rgb = float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb);
    } else {
        rgb = float3(y + 1.4746 * cr, y - 0.16455 * cb - 0.57135 * cr, y + 1.8814 * cb);
    }
    return saturate(rgb);
}

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv  = float2(p.x, 1.0 - p.y);
    return o;
}

// Monitor utama: LUT + Zebra + Focus Peaking
fragment float4 fs_monitor(VOut in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           texture3d<float> lut [[texture(1)]],
                           constant Uniforms& u [[buffer(0)]]) {
    float3 rgb  = decodeSource(src, in.uv, u);
    float  luma = dot(rgb, kLuma709);
    float3 outc = rgb;

    // LUT hanya untuk tampilan; TIDAK pernah menyentuh file ProRes
    if (u.lutEnabled != 0) {
        constexpr sampler ls(filter::linear, address::clamp_to_edge);
        float n = float(lut.get_width());
        float3 coord = rgb * ((n - 1.0) / n) + 0.5 / n;
        outc = lut.sample(ls, coord).rgb;
    }

    // Zebra dievaluasi pada sinyal asli (log/HLG), bukan hasil LUT
    if (u.zebraEnabled != 0) {
        float2 p = in.pos.xy;
        float s1 = step(0.5, fract((p.x + p.y + u.time * 20.0) / 14.0));
        float s2 = step(0.5, fract((p.x - p.y - u.time * 20.0) / 14.0));
        if (luma >= u.zebraHigh) {
            outc = mix(outc, float3(1.0, 0.1, 0.1), s1 * 0.8);
        } else if (luma >= u.zebraLow && luma < u.zebraLow + 0.06) {
            outc = mix(outc, float3(0.95, 0.85, 0.1), s2 * 0.7);
        }
    }

    // Focus peaking: Laplacian luma pada resolusi asli
    if (u.peakingEnabled != 0) {
        float2 t = float2(u.texelX, u.texelY);
        float l = dot(decodeSource(src, in.uv + float2(-t.x, 0), u), kLuma709);
        float r = dot(decodeSource(src, in.uv + float2( t.x, 0), u), kLuma709);
        float a = dot(decodeSource(src, in.uv + float2(0, -t.y), u), kLuma709);
        float b = dot(decodeSource(src, in.uv + float2(0,  t.y), u), kLuma709);
        float lap = fabs(4.0 * luma - l - r - a - b);
        float m = smoothstep(u.peakingThreshold, u.peakingThreshold * 2.0, lap);
        outc = mix(outc, float3(1.0, 0.15, 0.1), m);
    }
    return float4(outc, 1.0);
}

fragment float4 fs_texture(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(t.sample(s, in.uv).rgb, 1.0);
}

// Akumulasi scope (grid sampel 960x540)
kernel void scopes_accumulate(texture2d<float> src [[texture(0)]],
                              device atomic_uint* hist [[buffer(0)]],   // 4 x 256: R,G,B,Y
                              device atomic_uint* wave [[buffer(1)]],   // 512 x 256
                              device atomic_uint* vec  [[buffer(2)]],   // 256 x 256 (Cb,Cr)
                              constant Uniforms& u [[buffer(3)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.gridW || gid.y >= u.gridH) return;
    float2 uv = (float2(gid) + 0.5) / float2(u.gridW, u.gridH);
    float3 rgb = decodeSource(src, uv, u);
    float  y   = dot(rgb, kLuma709);

    uint rb = uint(rgb.r * 255.0 + 0.5), gb = uint(rgb.g * 255.0 + 0.5);
    uint bb = uint(rgb.b * 255.0 + 0.5), yb = uint(saturate(y) * 255.0 + 0.5);
    atomic_fetch_add_explicit(&hist[rb],        1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[256u + gb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[512u + bb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[768u + yb], 1u, memory_order_relaxed);

    uint col = min(uint(uv.x * 512.0), 511u);
    atomic_fetch_add_explicit(&wave[yb * 512u + col], 1u, memory_order_relaxed);

    float cb = (rgb.b - y) / 1.8556;
    float cr = (rgb.r - y) / 1.5748;
    uint cbi = uint(clamp(cb + 0.5, 0.0, 1.0) * 255.0 + 0.5);
    uint cri = uint(clamp(cr + 0.5, 0.0, 1.0) * 255.0 + 0.5);
    atomic_fetch_add_explicit(&vec[cri * 256u + cbi], 1u, memory_order_relaxed);
}

kernel void render_waveform(device const uint* buf [[buffer(0)]],
                            texture2d<float, access::write> out [[texture(0)]],
                            constant Uniforms& u [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint W = out.get_width(), H = out.get_height();
    if (gid.x >= W || gid.y >= H) return;
    uint row = (H - 1u) - gid.y;
    float count = float(buf[row * W + gid.x]);
    float i = 1.0 - exp(-count * u.waveGain);
    out.write(float4(float3(0.25, 1.0, 0.35) * i, 1.0), gid);
}

kernel void render_histogram(device const uint* buf [[buffer(0)]],
                             texture2d<float, access::write> out [[texture(0)]],
                             constant Uniforms& u [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint W = out.get_width(), H = out.get_height();
    if (gid.x >= W || gid.y >= H) return;
    uint bin = min(gid.x * 256u / W, 255u);
    float fy = 1.0 - (float(gid.y) + 0.5) / float(H);
    float norm = log(1.0 + u.histScale);
    float3 col = float3(0.0);
    for (uint c = 0; c < 3; ++c) {
        float h = log(1.0 + float(buf[c * 256u + bin])) / norm;
        if (fy <= h) col += kChan[c] * 0.55;
    }
    float hl = log(1.0 + float(buf[768u + bin])) / norm;
    if (fy <= hl) col += float3(0.22);
    out.write(float4(saturate(col), 1.0), gid);
}

kernel void render_vectorscope(device const uint* buf [[buffer(0)]],
                               texture2d<float, access::write> out [[texture(0)]],
                               constant Uniforms& u [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint W = out.get_width(), H = out.get_height();
    if (gid.x >= W || gid.y >= H) return;
    uint cri = (H - 1u) - gid.y;
    float count = float(buf[cri * W + gid.x]);
    float i = 1.0 - exp(-count * u.vecGain);
    out.write(float4(float3(0.6, 0.9, 1.0) * i, 1.0), gid);
}
