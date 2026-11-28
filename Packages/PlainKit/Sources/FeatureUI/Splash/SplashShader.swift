/// Metal source for the launch dive, compiled at runtime with `makeLibrary(source:)` so the build
/// needs no Metal toolchain.
///
/// The splash is one sheet: the icon's field with the mark on it. It is a ring-shaped mesh around
/// the window in the P (`SplashMesh`), in UIKit points (y down, z toward the viewer), with every
/// vertex given as its distance and angle from the ring's centre. Two things move it:
///
/// - the window's cut edge rolls back. A roll of radius R travels outward from the window's
///   edge: paper inside the fold line wraps up and round it, and past `phiMax` it leaves the roll
///   as a straight tail lying back over the sheet, underside up. Under the icon's own fold the
///   edge stays down (the fold already holds it); on either side the roll grows from nothing
///   to its full size over thirty-four degrees, a smaller roll nearer the edge, never a torn one.
/// - the camera goes through: everything scales about the opening's pivot, and the lifted rim,
///   being nearer, grows a little faster (perspective about the screen's centre).
///
/// The opening's edge (the window's circle and the fold's two edges) is worked out per pixel from
/// the shapes themselves, so it stays sharp however far the camera has gone in; the pictures are
/// only sampled for their colors. On the still first frame the pictures' own edges are used
/// instead, so that frame is the Core Animation splash to the pixel.
///
/// Under the sheet, `hole_*` draws what is in the opening: the dawn, clearing, and the sheet's
/// shadow on whatever is behind it.
///
/// `Uniforms` must match `SplashUniforms` in SplashTimeline.swift, field for field.
nonisolated let splashShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 view;       // screen centre.xy, size.wh (points)
    float4 hole;       // ring centre.xy, window radius, unused
    float4 cam;        // pivot.xy, zoom, eye distance
    float4 curl;       // fold line radius p, roll radius R, max wrap angle, amount lifted (0...1)
    float4 flap;       // crease normal.xy, crease distance, ring outer radius (points)
    float4 tile;       // mark picture origin.xy, size.wh
    float4 vtile;      // dawn picture origin.xy, size.wh
    float4 shade;      // dawn opacity, dawn zoom, depth strength, 1 on the still first frame
    float4 depth;      // shadow offset.xy, shadow blur, opening radius
    float4 lip;        // rim's outer reach, its shadow's strength, how far it has rolled, unused
    float4 back0;      // the paper's underside, crease to free edge
    float4 back1;
    float4 back2;
    float4 back3;
    float4 shadeColor; // the rim's shadow on the sheet
};

// How much of a pixel `px` wide the folded flap covers at q (from the ring's centre): q is on the
// flap when its mirror image over the crease is inside the ring's outer circle.
static float flapCover(float2 q, constant Uniforms &u, float px) {
    float2 n = u.flap.xy;
    float a = dot(q, n);
    float2 m = q + 2.0 * (u.flap.z - a) * n;
    return saturate((u.flap.w - length(m)) / px + 0.5) * saturate((u.flap.z - a) / px + 0.5);
}

// The camera: scale about the pivot, then perspective about the screen's centre with the eye D
// points away. z = 0 maps 1:1 onto points at zoom 1; w carries the depth.
static float4 project(float3 pos, constant Uniforms &u) {
    float zoom = u.cam.z, D = u.cam.w;
    float3 p = float3(u.cam.xy + (pos.xy - u.cam.xy) * zoom, pos.z * zoom);
    float w = (D - p.z) / D;
    float2 ndc = (p.xy - u.view.xy) * 2.0 / u.view.zw;
    return float4(ndc.x, -ndc.y, (0.5 - p.z / 4000.0) * w, w);
}

struct SheetOut {
    float4 position [[position]];
    float2 at;      // where this bit of the sheet lies when flat (screen points)
    float3 n;
    float behind;   // how far inside the fold line (> 0: in the roll)
    float lifted;   // how much this angle lifts (0 under the icon's fold)
};

vertex SheetOut sheet_vertex(uint vid [[vertex_id]], const device float2 *mesh [[buffer(1)]],
                             constant Uniforms &u [[buffer(0)]]) {
    float rho = mesh[vid].x, theta = mesh[vid].y;
    float2 dir = float2(cos(theta), sin(theta));
    float2 c = u.hole.xy;
    float2 at = c + dir * rho;
    // Flat within 56 degrees of the crease's normal, where the icon's fold lies; fully lifted from 90.
    float lifted = (1.0 - smoothstep(0.0, 0.559, dot(dir, u.flap.xy))) * u.curl.w;
    // Where the edge lifts less, the same roll is smaller: its fold line stays nearer the
    // window's edge and its radius shrinks with it, down to nothing under the icon's fold.
    float r0 = u.hole.z, phiMax = u.curl.z;
    float p = r0 + (u.curl.x - r0) * lifted;
    float R = max(u.curl.y * lifted, 0.05);
    float s = p - rho;
    float3 pos = float3(at, 0.0);
    float3 n = float3(0.0, 0.0, 1.0);
    if (s > 0.0 && lifted > 0.002) {
        float phi = min(s / R, phiMax);
        float e = s - R * phi;                        // straight tail past the roll
        float along = R * sin(phi) + e * cos(phi);
        pos = float3(c + dir * (p - along), R * (1.0 - cos(phi)) + e * sin(phi));
        n = float3(dir * sin(phi), cos(phi));
    }
    return { project(pos, u), at, n, s, lifted };
}

fragment float4 sheet_fragment(SheetOut in [[stage_in]], bool front [[front_facing]],
                               texture2d<float> mark [[texture(0)]], texture2d<float> field [[texture(1)]],
                               sampler smooth [[sampler(0)]], sampler exact [[sampler(1)]], sampler stretch [[sampler(2)]],
                               constant Uniforms &u [[buffer(0)]]) {
    float2 q = in.at - u.hole.xy;
    float rho = length(q), r0 = u.hole.z;
    float2 muv = (in.at - u.tile.xy) / u.tile.zw;
    float3 f = field.sample(stretch, in.at / u.view.zw).rgb;
    if (u.shade.w > 0.5) {
        // Nothing has moved: the pictures' own texels and edges, as Core Animation composes them.
        float4 m = mark.sample(exact, muv);
        if (rho < r0 + 1.5) {
            if (m.a <= 0.002) { discard_fragment(); }
            return m;
        }
        return float4(m.rgb + f * (1.0 - m.a), 1.0);
    }
    // Sheet points per pixel here, for an edge one pixel soft at any zoom.
    float px = max(0.5 * (length(dfdx(in.at)) + length(dfdy(in.at))), 1e-4);
    float open = saturate((r0 - rho) / px + 0.5) * (1.0 - flapCover(q, u, px));
    float cover = 1.0 - open;
    if (cover <= 0.002) { discard_fragment(); }           // no depth from the opening
    float4 m = mark.sample(smooth, muv, level(0.0));
    // At the opening's edge the picture's texels are part clear: take their color alone, the
    // coverage comes from the shapes.
    float3 c = rho < r0 + 1.5 ? saturate(m.rgb / max(m.a, 0.004)) : m.rgb + f * (1.0 - m.a);

    float3 n = in.n;
    float len = length(n);
    n = len > 1e-3 ? n / len : float3(0.0, 0.0, 1.0);
    if (!front) { n = -n; }
    float3 L = normalize(float3(-0.35, -0.55, 0.75));     // top left, in front
    const float ka = 0.55, kd = 0.45;
    // Normalized so the flat sheet gets exactly 1.
    float lit = (ka + kd * max(dot(n, L), 0.0)) / (ka + kd * L.z);
    if (front) {
        c *= lit;
        if (in.behind <= 0.0 && u.lip.y > 0.0 && in.lifted > 0.002) {
            // The rolled rim's shadow on the sheet beside it: tight on the lit side, longer away
            // from the light.
            float2 dir = q / max(rho, 1e-3);
            float away = 0.5 + 0.5 * dot(dir, normalize(float2(0.35, 0.6)));
            float lift = 1.0 - smoothstep(0.0, 0.559, dot(dir, u.flap.xy));
            float reach = r0 + (u.lip.x - r0) * lift;     // the rim's outer edge at this angle
            float shadow = u.lip.y * lift * exp(-max(rho - reach, 0.0) / (1.0 + 2.6 * away));
            c = mix(c, u.shadeColor.rgb, shadow);
        }
        return float4(c * cover, cover);
    }
    // The underside: the fold's color, crease to free edge, darker deep in the roll.
    float k = saturate(in.behind / (u.lip.z * max(in.lifted, 1e-3)));
    float3 b = k < 0.18 ? mix(u.back0.rgb, u.back1.rgb, k / 0.18)
             : k < 0.6 ? mix(u.back1.rgb, u.back2.rgb, (k - 0.18) / 0.42)
             : mix(u.back2.rgb, u.back3.rgb, (k - 0.6) / 0.4);
    return float4(b * min(lit, 1.04) * cover, cover);
}

struct HoleOut {
    float4 position [[position]];
    float2 at;
};

// A square over the opening and the rim, flat on the screen under the sheet.
vertex HoleOut hole_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1)) * 2.0 - 1.0;
    float2 at = u.hole.xy + corner * (u.hole.z + 28.0);
    return { project(float3(at, 0.0), u), at };
}

fragment float4 hole_fragment(HoleOut in [[stage_in]], texture2d<float> dawn [[texture(0)]],
                              sampler smooth [[sampler(0)]], sampler exact [[sampler(1)]],
                              constant Uniforms &u [[buffer(0)]]) {
    float2 q = in.at - u.hole.xy;
    if (u.shade.w > 0.5) {
        return dawn.sample(exact, (in.at - u.vtile.xy) / u.vtile.zw);
    }
    // The dawn, a little nearer each frame, clearing.
    float2 vuv = (u.hole.xy + q / u.shade.y - u.vtile.xy) / u.vtile.zw;
    float4 v = dawn.sample(smooth, vuv, level(0.0)) * u.shade.x;
    // The sheet's shadow on what is behind it: light comes through the opening and lands down
    // and right of it, so the shade lies under the top-left edge only. No dimming elsewhere:
    // a veil over the whole opening made the page look like it sat behind dirty glass.
    float2 qs = q - u.depth.xy;
    float blur = u.depth.z;
    float lit = smoothstep(-0.5 * blur, 0.5 * blur, u.depth.w - length(qs)) * (1.0 - flapCover(qs, u, blur));
    float dim = u.shade.z * 0.42 * (1.0 - lit);
    return float4(v.rgb, v.a + (1.0 - v.a) * dim);
}
"""
