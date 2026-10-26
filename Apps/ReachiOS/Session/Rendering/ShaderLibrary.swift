import Metal
import os

/// The renderer's Metal shaders, compiled at runtime from source.
///
/// Why not a `.metal` file: building one requires Xcode's separately-downloaded Metal Toolchain, which
/// would make the whole project fail to build on machines without it. Runtime compilation of these few
/// small functions takes a few tens of milliseconds; `prewarm()` does it on a background queue at
/// launch so a session never waits for it.
enum ShaderLibrary {
    private static let lock = NSLock()
    private static var cached: MTLLibrary?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "reach", category: "render")

    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            if let device = MTLCreateSystemDefaultDevice() { _ = library(for: device) }
        }
    }

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.withLock {
            if let cached, cached.device === device { return cached }
            do {
                let options = MTLCompileOptions()
                options.mathMode = .fast
                let lib = try device.makeLibrary(source: source, options: options)
                cached = lib
                return lib
            } catch {
                logger.error("shader compile failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Shared by every pass: a quad described by its NDC rectangle and UV rectangle, drawn as a 4-vertex
// triangle strip with no vertex buffer.
struct QuadUniforms {
    float4 rect;    // left, top, right, bottom in NDC (top = +1)
    float4 uvRect;  // u0, v0, u1, v1
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1)); // (0,0) (1,0) (0,1) (1,1)
    VOut o;
    o.position = float4(mix(u.rect.x, u.rect.z, corner.x), mix(u.rect.y, u.rect.w, corner.y), 0.0, 1.0);
    o.uv = float2(mix(u.uvRect.x, u.uvRect.z, corner.x), mix(u.uvRect.y, u.uvRect.w, corner.y));
    return o;
}

// MARK: - Decode pass: NV12 → RGB (into a mipmapped intermediate texture, once per video frame)

struct YUVUniforms {
    float4 r;       // rows of the Y'CbCr → R'G'B' matrix, range scaling folded in
    float4 g;
    float4 b;
    float4 offset;  // Y', Cb, Cr offsets (16/255 for video range Y', 128/255 for chroma)
};

fragment float4 nv12_fragment(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> cTex [[texture(1)]],
                              constant YUVUniforms &u [[buffer(0)]]) {
    constexpr sampler chroma(filter::linear, address::clamp_to_edge);
    // The target has exactly the luma plane's size, so read luma 1:1 and interpolate chroma.
    float y = yTex.read(uint2(in.position.xy)).r;
    float2 c = cTex.sample(chroma, in.uv).rg;
    float3 yuv = float3(y, c) - u.offset.xyz;
    float3 rgb = float3(dot(u.r.xyz, yuv), dot(u.g.xyz, yuv), dot(u.b.xyz, yuv));
    return float4(saturate(rgb), 1.0);
}

fragment float4 bgra_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    return float4(tex.read(uint2(in.position.xy)).rgb, 1.0);
}

// MARK: - Display pass

struct DisplayUniforms {
    float4 params;  // x: source texels per destination pixel, y: dim amount (0…1)
    float4 texel;   // 1/width, 1/height, width, height
};

fragment float4 display_fragment(VOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant DisplayUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float ratio = u.params.x;
    float3 c;
    if (ratio <= 1.0) {
        // Magnifying: plain bilinear.
        c = tex.sample(s, in.uv, level(0.0)).rgb;
    } else {
        // Minifying (the usual case — a Retina Mac screen on a phone). Four bilinear taps spread over the
        // pixel's footprint, each from a mip level half the footprint wide: an approximate box filter
        // that keeps thin text strokes instead of aliasing them away, without trilinear's mush.
        float lod = max(log2(ratio) - 1.0, 0.0);
        float2 d = u.texel.xy * (ratio * 0.25);
        c  = tex.sample(s, in.uv + float2(-d.x, -d.y), level(lod)).rgb;
        c += tex.sample(s, in.uv + float2( d.x, -d.y), level(lod)).rgb;
        c += tex.sample(s, in.uv + float2(-d.x,  d.y), level(lod)).rgb;
        c += tex.sample(s, in.uv + float2( d.x,  d.y), level(lod)).rgb;
        c *= 0.25;
    }
    // "Frozen" look while reconnecting: desaturate and darken the last frame.
    float dim = u.params.y;
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(c, float3(luma), dim * 0.8) * (1.0 - dim * 0.55);
    return float4(c, 1.0);
}

// MARK: - Cursor sprite (premultiplied alpha)

fragment float4 sprite_fragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                constant float4 &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv) * params.x;
}

// MARK: - Held-button halo around the cursor

struct RingUniforms {
    float4 color;   // rgb + alpha
    float4 params;  // x: quad size in pixels, y: rim thickness (fraction of radius)
};

fragment float4 ring_fragment(VOut in [[stage_in]], constant RingUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * 2.0 - 1.0;
    float r = length(p);
    float aa = 2.5 / max(u.params.x, 1.0);
    float disc = 1.0 - smoothstep(1.0 - aa, 1.0, r);
    float rim = disc * smoothstep(1.0 - u.params.y - aa, 1.0 - u.params.y, r);
    float a = (disc * 0.22 + rim * 0.7) * u.color.a;
    return float4(u.color.rgb * a, a);
}

// MARK: - Minimap

struct MinimapUniforms {
    float4 visible; // visible region in uv: x0, y0, x1, y1
    float4 size;    // width px, height px, corner radius px, alpha
    float4 cursor;  // u, v, radius px, show
    float4 params;  // x: mip level
};

static float sdRoundRect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 minimap_fragment(VOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant MinimapUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 size = u.size.xy;
    float2 p = in.uv * size;
    float outer = sdRoundRect(p - size * 0.5, size * 0.5, u.size.z);
    float shape = clamp(0.5 - outer, 0.0, 1.0);
    if (shape <= 0.0) { discard_fragment(); }

    float3 c = tex.sample(s, in.uv, level(u.params.x)).rgb;

    // Dim what's outside the visible region and outline the region itself.
    float2 vmin = u.visible.xy * size;
    float2 vmax = u.visible.zw * size;
    float inner = sdRoundRect(p - (vmin + vmax) * 0.5, max((vmax - vmin) * 0.5, float2(1.5)), 2.5);
    float inside = clamp(0.5 - inner, 0.0, 1.0);
    c *= mix(0.4, 1.0, inside);
    float border = 1.0 - smoothstep(0.7, 1.7, abs(inner));
    c = mix(c, float3(1.0), border * 0.95);

    // Hairline rim so the map separates from the screen behind it.
    float rim = 1.0 - smoothstep(0.4, 1.4, abs(outer));
    c = mix(c, float3(1.0), rim * 0.3);

    if (u.cursor.w > 0.5) {
        float d = length(p - u.cursor.xy * size);
        float core = 1.0 - smoothstep(u.cursor.z - 0.8, u.cursor.z + 0.6, d);
        float halo = 1.0 - smoothstep(u.cursor.z + 0.6, u.cursor.z + 2.0, d);
        c = mix(c, float3(0.0), halo * 0.55);
        c = mix(c, float3(0.302, 0.584, 1.0), core);
    }

    float a = shape * u.size.w;
    return float4(c * a, a);
}
"""#
}
