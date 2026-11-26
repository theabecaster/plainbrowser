#!/usr/bin/env python3
"""Generate C2-final Plain icon assets. Params via env/JSON for iteration."""
import json, math, os, sys

OUT = sys.argv[1]  # AppIcon.icon dir
P = dict(
    L=236, T=150, R=806, SX=456, BB=650, B=872,
    CX0=482, CY0=352, CX1=628, CY1=498, CR=50,
    S=262, DEPTH=104, BULGE=16, APEX_R=26,
    TL_R=78, BR_R=210, STEM_R=110, INNER_R=46, CUT_R=22,
    SHADOW_OP=0.42, SHADOW_BLUR=20,
)
P.update(json.loads(os.environ.get("PARAMS", "{}")))

def v(a, b): return (b[0]-a[0], b[1]-a[1])
def n(a):
    l = math.hypot(*a); return (a[0]/l, a[1]/l)
def add(a, b, k=1): return (a[0]+b[0]*k, a[1]+b[1]*k)

def fillet(pts, radii, seg=28):
    out = []
    N = len(pts)
    for i in range(N):
        p = pts[i]; a = pts[i-1]; b = pts[(i+1) % N]; r = radii[i]
        if r <= 0:
            out.append(p); continue
        u = n(v(p, a)); w = n(v(p, b))
        ang = math.acos(max(-1, min(1, u[0]*w[0]+u[1]*w[1])))
        d = r / math.tan(ang/2)
        t1 = add(p, u, d); t2 = add(p, w, d)
        bis = n((u[0]+w[0], u[1]+w[1]))
        c = add(p, bis, r/math.sin(ang/2))
        a1 = math.atan2(t1[1]-c[1], t1[0]-c[0]); a2 = math.atan2(t2[1]-c[1], t2[0]-c[0])
        da = (a2 - a1 + math.pi) % (2*math.pi) - math.pi
        for k in range(seg+1):
            t = a1 + da*k/seg
            out.append((c[0]+r*math.cos(t), c[1]+r*math.sin(t)))
    return out

def path(pts):
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"

L, T, R, SX, BB, B = P["L"], P["T"], P["R"], P["SX"], P["BB"], P["B"]
S = P["S"]
F1 = (R - S, T); F2 = (R, T + S)
outer = [(L, T), F1, F2, (R, BB), (SX, BB), (SX, B), (L, B)]
outer_r = [P["TL_R"], P["CUT_R"], P["CUT_R"], P["BR_R"], P["INNER_R"], P["STEM_R"], P["STEM_R"]]
body_pts = fillet(outer, outer_r)
cx0, cy0, cx1, cy1, cr = P["CX0"], P["CY0"], P["CX1"], P["CY1"], P["CR"]
counter = [(cx0, cy0), (cx1, cy0), (cx1, cy1), (cx0, cy1)]
counter_pts = fillet(counter, [cr]*4)[::-1]
body_d = path(body_pts) + " " + path(counter_pts)
counter_d = path(fillet(counter, [cr]*4))

# Flap: hinge slightly beyond cut line so no seam, apex toward interior
inset = P["CUT_R"] * 0.6
hd = n(v(F1, F2))
H1 = add(F1, hd, inset); H2 = add(F2, hd, -inset)
nrm = (-1/math.sqrt(2), 1/math.sqrt(2))  # into the page
out_n = (-nrm[0], -nrm[1])
H1o = add(H1, out_n, 3); H2o = add(H2, out_n, 3)
mid = ((F1[0]+F2[0])/2, (F1[1]+F2[1])/2)
Q = add(mid, nrm, P["DEPTH"])
def bulge_pt(a, b):
    m = ((a[0]+b[0])/2, (a[1]+b[1])/2)
    e = n(v(a, b)); perp = (e[1], -e[0])
    # pick perp pointing away from hinge midpoint
    if (m[0]-mid[0])*perp[0] + (m[1]-mid[1])*perp[1] < 0:
        perp = (-perp[0], -perp[1])
    return add(m, perp, P["BULGE"])
M1 = bulge_pt(H1, Q); M2 = bulge_pt(Q, H2)
flap_pts = fillet([H1o, H1, M1, Q, M2, H2, H2o], [0, 6, 160, P["APEX_R"], 160, 6, 0], seg=24)
flap_d = path(flap_pts)

# gradient axis: hinge mid -> apex
g0 = mid; g1 = Q

def svg(inner, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}</defs>{inner}</svg>')

A = os.path.join(OUT, "Assets")
os.makedirs(A, exist_ok=True)
for f in os.listdir(A):
    os.remove(os.path.join(A, f))

def write(name, s):
    open(os.path.join(A, name), "w").write(s)

# ---- body (paper) + cast shadow of flap, clipped to paper
sh_off = (-P["SHADOW_BLUR"]*0.9, P["SHADOW_BLUR"]*1.1)
sh_pts = [(x+sh_off[0], y+sh_off[1]) for x, y in flap_pts]
def body_svg(paper, shadow_col, shadow_op):
    defs = (f'<linearGradient id="p" gradientUnits="userSpaceOnUse" x1="{L}" y1="{T}" x2="{L+200}" y2="{B}">'
            f'<stop offset="0" stop-color="{paper[0]}"/><stop offset="0.5" stop-color="{paper[1]}"/>'
            f'<stop offset="1" stop-color="{paper[2]}"/></linearGradient>'
            f'<radialGradient id="hl" gradientUnits="userSpaceOnUse" cx="{L+60}" cy="{T+40}" r="420">'
            f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>'
            f'<radialGradient id="wm" gradientUnits="userSpaceOnUse" cx="{R}" cy="{B}" r="560">'
            f'<stop offset="0" stop-color="{paper[3]}" stop-opacity="0.38"/><stop offset="1" stop-color="{paper[3]}" stop-opacity="0"/></radialGradient>'
            f'<clipPath id="c"><path clip-rule="evenodd" d="{body_d}"/></clipPath>'
            f'<filter id="s1" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="{P["SHADOW_BLUR"]}"/></filter>'
            f'<filter id="s2" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>')
    inner = (f'<path fill-rule="evenodd" d="{body_d}" fill="url(#p)"/>'
             f'<g clip-path="url(#c)">'
             f'<rect width="1024" height="1024" fill="url(#hl)"/>'
             f'<rect width="1024" height="1024" fill="url(#wm)"/>'
             f'<path d="{path(sh_pts)}" fill="{shadow_col}" opacity="{shadow_op}" filter="url(#s1)"/>'
             f'<path d="{path([(x-5, y+6) for x, y in flap_pts])}" fill="{shadow_col}" opacity="{shadow_op*0.8}" filter="url(#s2)"/>'
             f'</g>')
    return svg(inner, defs)

write("body.svg", body_svg(("#FFFDF8", "#FFF6E6", "#FFE6D2", "#FFC9B0"), "#7A2E22", P["SHADOW_OP"]))
write("body-dark.svg", body_svg(("#FFF8EE", "#F7EAD8", "#EED8C2", "#E8B9A4"), "#2A0E10", P["SHADOW_OP"]+0.08))

# ---- flap (coral underside)
def flap_svg(stops):
    st = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    defs = (f'<linearGradient id="f" gradientUnits="userSpaceOnUse" x1="{g0[0]:.1f}" y1="{g0[1]:.1f}" '
            f'x2="{g1[0]:.1f}" y2="{g1[1]:.1f}">{st}</linearGradient>')
    return svg(f'<path d="{flap_d}" fill="url(#f)"/>', defs)

write("flap.svg", flap_svg([(0, "#FFD9B8"), (0.16, "#FF9F80"), (0.5, "#FF6E5E"), (1, "#F04E58")]))
write("flap-tinted.svg", flap_svg([(0, "#C8C8C8"), (0.22, "#8A8A8A"), (1, "#545454")]))

# ---- window: view through the counter (sky, horizon, rising sun)
pad = 14
wx0, wy0, wx1, wy1 = cx0-pad, cy0-pad, cx1+pad, cy1+pad
hy = cy0 + (cy1-cy0)*P.get("HORIZON", 0.66)
sx = cx0 + (cx1-cx0)*0.5
def window_svg(sky, planet, rim, sun, glow_op):
    win = path(fillet([(wx0, wy0), (wx1, wy0), (wx1, wy1), (wx0, wy1)], [cr+pad]*4))
    pr = P.get("PLANET_R", 260)
    pcy = hy + pr
    defs = (f'<clipPath id="w"><path d="{win}"/></clipPath>'
            f'<linearGradient id="sky" gradientUnits="userSpaceOnUse" x1="0" y1="{wy0}" x2="0" y2="{hy}">'
            f'<stop offset="0" stop-color="{sky[0]}"/><stop offset="0.6" stop-color="{sky[1]}"/><stop offset="1" stop-color="{sky[2]}"/></linearGradient>'
            f'<radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{hy}" r="{P.get("GLOW_R",110)}">'
            f'<stop offset="0" stop-color="{sun[0]}" stop-opacity="{glow_op}"/><stop offset="1" stop-color="{sun[0]}" stop-opacity="0"/></radialGradient>'
            f'<radialGradient id="pl" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{hy}" r="{wy1-hy+40}">'
            f'<stop offset="0" stop-color="{planet[0]}"/><stop offset="1" stop-color="{planet[1]}"/></radialGradient>'
            f'<radialGradient id="sun" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{hy-8}" r="{P.get("SUN_R",26)+8}">'
            f'<stop offset="0" stop-color="{sun[0]}"/><stop offset="1" stop-color="{sun[1]}"/></radialGradient>'
            f'<filter id="bl" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>'
            f'<linearGradient id="ins" gradientUnits="userSpaceOnUse" x1="0" y1="{wy0+pad}" x2="0" y2="{wy0+pad+30}">'
            f'<stop offset="0" stop-color="#0A0830" stop-opacity="0.45"/><stop offset="1" stop-color="#0A0830" stop-opacity="0"/></linearGradient>')
    sun_el = (f'<circle cx="{sx}" cy="{hy}" r="{P.get("SUN_R",26)}" fill="url(#sun)"/>' if P.get("SUN", 1) else "")
    inner = (f'<g clip-path="url(#w)">'
             f'<rect x="{wx0}" y="{wy0}" width="{wx1-wx0}" height="{wy1-wy0}" fill="url(#sky)"/>'
             f'<rect x="{wx0}" y="{wy0}" width="{wx1-wx0}" height="{wy1-wy0}" fill="url(#glow)"/>'
             f'{sun_el}'
             f'<circle cx="{sx}" cy="{pcy}" r="{pr+5}" fill="{rim}" opacity="0.9" filter="url(#bl)"/>'
             f'<circle cx="{sx}" cy="{pcy}" r="{pr}" fill="url(#pl)"/>'
             f'<rect x="{wx0}" y="{wy0}" width="{wx1-wx0}" height="{pad+30}" fill="url(#ins)"/>'
             f'</g>')
    return svg(inner, defs)

write("window.svg", window_svg(("#3A2FCF", "#3F86FF", "#FFC08E"), ("#1B2A8F", "#121552"), "#9CFFE8", ("#FFF8E8", "#FF5A4C"), 1.0))
write("window-tinted.svg", window_svg(("#1A1A1A", "#4A4A4A", "#F0F0F0"), ("#141414", "#050505"), "#FFFFFF", ("#FFFFFF", "#CFCFCF"), 1.0))
write("window-dark.svg", window_svg(("#1E1A80", "#2F6FE8", "#FFBA8E"), ("#141F70", "#0B0D3A"), "#7CFFE0", ("#FFF6E4", "#FF5A4C"), 1.0))

# ---- bloom (background light)
def bloom(c1, o1, c2, o2):
    defs = (f'<radialGradient id="a" gradientUnits="userSpaceOnUse" cx="150" cy="120" r="640">'
            f'<stop offset="0" stop-color="{c1}" stop-opacity="{o1}"/><stop offset="1" stop-color="{c1}" stop-opacity="0"/></radialGradient>'
            f'<radialGradient id="b" gradientUnits="userSpaceOnUse" cx="960" cy="980" r="660">'
            f'<stop offset="0" stop-color="{c2}" stop-opacity="{o2}"/><stop offset="1" stop-color="{c2}" stop-opacity="0"/></radialGradient>')
    return svg('<rect width="1024" height="1024" fill="url(#a)"/><rect width="1024" height="1024" fill="url(#b)"/>', defs)
write("bloom.svg", bloom("#B8FFE0", 0.9, "#6B4BFF", 0.85))
write("bloom-dark.svg", bloom("#1FB5A0", 0.5, "#5B3BFF", 0.6))

grad = lambda a, b: {"linear-gradient": [a, b], "orientation": {"start": {"x": 0.2, "y": 0}, "stop": {"x": 0.8, "y": 1}}}
icon = {
    "groups": [
        {"name": "Flap", "layers": [{"name": "Flap", "glass": True, "image-name-specializations": [{"value": "flap.svg"}, {"appearance": "tinted", "value": "flap-tinted.svg"}]}],
         "shadow": {"kind": "neutral", "opacity": 0.6}, "translucency": {"enabled": False, "value": 0},
         "specular": True},
        {"name": "P", "layers": [{"name": "Body", "glass": True, "image-name-specializations": [{"value": "body.svg"}, {"appearance": "dark", "value": "body-dark.svg"}]}],
         "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": P.get("TRANS", 0.08)},
         "specular": True},
        {"name": "Window", "layers": [{"name": "Window", "glass": False, "image-name-specializations": [
            {"value": "window.svg"}, {"appearance": "dark", "value": "window-dark.svg"}, {"appearance": "tinted", "value": "window-tinted.svg"}]}],
         "shadow": {"kind": "neutral", "opacity": 0.0}, "translucency": {"enabled": False, "value": 0},
         "specular": False},
        {"name": "Bloom", "layers": [{"name": "Bloom", "glass": False, "image-name-specializations": [
            {"value": "bloom.svg"}, {"appearance": "dark", "value": "bloom-dark.svg"}]}],
         "shadow": {"kind": "neutral", "opacity": 0.0}, "translucency": {"enabled": False, "value": 0.5},
         "specular": False},
    ],
    "supported-platforms": {"squares": "shared", "circles": ["watchOS"]},
    "fill-specializations": [
        {"value": grad("srgb:0.20,0.86,0.78,1.0", "srgb:0.16,0.45,1.0,1.0")},
        {"appearance": "dark", "value": grad("srgb:0.04,0.13,0.20,1.0", "srgb:0.06,0.06,0.20,1.0")},
    ],
}
json.dump(icon, open(os.path.join(OUT, "icon.json"), "w"), indent=2)
print("ok")
