#!/usr/bin/env python3
"""Generate Plain's app icon, Brand/AppIcon.icon (an Icon Composer document).

The mark: a thick cream paper ring around a dawn (violet sky, coral sun,
night-lagoon planet with a mint rim). Its top-right edge is folded in along a
straight crease, coral side up, and a short paper stem drops from its left
side, so a P hides in the ring. See Brand/identity.md.

The fold is a real fold of a flat paper ring: the crease crosses only the
band, and the flap is the exact mirror of the removed paper about the crease,
so the flap and the notch it leaves share their end points.

Every part is its own SVG layer: the curl, the ring (with the stem), the view
and the background bloom. Each has light, dark and tinted versions.

Usage: gen_icon.py [output.icon]          (default: Brand/AppIcon.icon)
Env:   ICON='{"DC": 220}'                 override any value in P
       SILHOUETTE=path.svg                also write the mark as a black silhouette
"""
import json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "AppIcon.icon")

P = dict(
    CX=540, CY=488,          # ring centre
    RO=300, RI=212,          # ring outer and inner radius
    ANG=-45, DC=222,         # fold: direction of the crease's normal, crease distance from the centre
    SW=88, DROP=20,          # stem width (the band's width) and how far it drops below the ring
    RBL=14, RBR=14,          # stem foot corners: nearly square, a stem rather than a tail
    WEB=14,                  # fillet where the stem's inner edge meets the ring
    HY=0.26, SX=-0.14, SUN=58,   # horizon height, sun position and radius in the view
)
P.update(json.loads(os.environ.get("ICON", "{}")))

# ---------------------------------------------------------------- geometry

def v(a, b): return (b[0]-a[0], b[1]-a[1])
def n(a):
    l = math.hypot(*a); return (a[0]/l, a[1]/l)
def add(a, b, k=1): return (a[0]+b[0]*k, a[1]+b[1]*k)
def unit(deg):
    a = math.radians(deg); return (math.cos(a), math.sin(a))

def fillet(pts, radii, seg=28):
    """Polygon with rounded corners (radius per vertex) as a point list."""
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
        c = add(p, n((u[0]+w[0], u[1]+w[1])), r/math.sin(ang/2))
        a1 = math.atan2(t1[1]-c[1], t1[0]-c[0]); a2 = math.atan2(t2[1]-c[1], t2[0]-c[0])
        da = (a2 - a1 + math.pi) % (2*math.pi) - math.pi
        out += [(c[0]+r*math.cos(a1+da*k/seg), c[1]+r*math.sin(a1+da*k/seg)) for k in range(seg+1)]
    return out

def path(pts):
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"

def circle_pts(cx, cy, r, seg=720):
    return [(cx + r*math.cos(2*math.pi*k/seg), cy + r*math.sin(2*math.pi*k/seg)) for k in range(seg)]

def area(pts):
    return sum(a[0]*b[1] - b[0]*a[1] for a, b in zip(pts, pts[1:] + pts[:1])) / 2

def oriented(pts, sign):
    return pts if area(pts)*sign > 0 else pts[::-1]

def clip_halfplane(pts, p0, nrm, keep_positive):
    """Sutherland-Hodgman clip by the line through p0 with normal nrm."""
    def side(p): return (p[0]-p0[0])*nrm[0] + (p[1]-p0[1])*nrm[1]
    out = []
    for i in range(len(pts)):
        a, b = pts[i], pts[(i+1) % len(pts)]
        sa, sb = side(a), side(b)
        ina, inb = (sa >= 0) == keep_positive, (sb >= 0) == keep_positive
        if ina: out.append(a)
        if ina != inb:
            t = sa/(sa - sb); out.append((a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t))
    return out

def reflect(pts, p0, d):
    """Mirror points across the line through p0 with unit direction d."""
    out = []
    for x, y in pts:
        t = (x-p0[0])*d[0] + (y-p0[1])*d[1]
        px, py = p0[0] + d[0]*t, p0[1] + d[1]*t
        out.append((2*px - x, 2*py - y))
    return out

# ---------------------------------------------------------------- the mark

CX, CY, RO, RI = P["CX"], P["CY"], P["RO"], P["RI"]

# the fold: crease at distance DC from the centre (RI < DC < RO, so it
# crosses only the band); the flap is the cut-off segment mirrored over it
u = unit(P["ANG"]); d = (-u[1], u[0])
C0 = add((CX, CY), u, P["DC"])
assert RI < P["DC"] < RO, "the crease must cross only the band"
removed = clip_halfplane(circle_pts(CX, CY, RO), C0, u, True)
flap = reflect(removed, C0, d)
flap_g = (C0, add(C0, u, -(RO - P["DC"])))         # shading runs across the crease

# the stem: hangs from the ring's left tangent, a band's width wide
x0, x1 = CX - RO, CX - RO + P["SW"]
stem = fillet([(x0, CY), (x1, CY), (x1, CY + RO + P["DROP"]), (x0, CY + RO + P["DROP"])],
              [0, 0, P["RBR"], P["RBL"]], seg=20)
# a small fillet of paper in the inside corner between the stem and the ring
yj = CY + math.sqrt(RO*RO - (x1 - CX)**2)
tj = math.atan2(yj - CY, x1 - CX)
A, J = (x1, yj + P["WEB"]), (x1, yj)
B = (CX + RO*math.cos(tj - P["WEB"]/RO), CY + RO*math.sin(tj - P["WEB"]/RO))
web = [((1-t)**2*A[0] + 2*(1-t)*t*J[0] + t*t*B[0], (1-t)**2*A[1] + 2*(1-t)*t*J[1] + t*t*B[1])
       for t in [k/16 for k in range(17)]] + [(x1 - 6, yj - 6)]

ring_out = clip_halfplane(circle_pts(CX, CY, RO), C0, u, False)
shapes = [oriented(ring_out, 1), oriented(stem, 1), oriented(web, 1)]
hole = oriented(circle_pts(CX, CY, RI), -1)
paper_d = " ".join(path(s) for s in shapes) + " " + path(hole)

# ---------------------------------------------------------------- art

def svg(inner, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}</defs>{inner}</svg>')

def blur(fid, sd):
    return (f'<filter id="{fid}" x="-50%" y="-50%" width="200%" height="200%">'
            f'<feGaussianBlur stdDeviation="{sd}"/></filter>')

def stops(st):
    return "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in st)

PAPER = {"light": ("#FFFDF8", "#FFF6E6", "#FFE6D2", "#FFC9B0", "#7A2E22"),
         "dark": ("#FFF8EE", "#F7EAD8", "#EED8C2", "#E8B9A4", "#2A0E10"),
         # tinted: the system tints by brightness, so the paper is plain bright
         "tinted": ("#FFFFFF", "#FFFFFF", "#F2F2F2", "#E0E0E0", "#000000")}

def ring_svg(mode):
    """Cream paper: soft top-left light, warm lower right, the flap's contact
    shadow (tight at the hinge, softer under the lift)."""
    top, mid, low, warm, shade = PAPER[mode]
    x0b, y0b, x1b, y1b = CX - RO, CY - RO, CX + RO, CY + RO + P["DROP"]
    sh = [(3, 10, 12, 0.28), (1, 3, 2.5, 0.36)] if mode != "tinted" else [(1, 3, 3, 0.35)]
    defs = (f'<linearGradient id="p" gradientUnits="userSpaceOnUse" x1="{x0b}" y1="{y0b}" x2="{x0b+(x1b-x0b)*0.35:.0f}" y2="{y1b}">'
            f'{stops([(0, top), (0.5, mid), (1, low)])}</linearGradient>'
            f'<radialGradient id="hl" gradientUnits="userSpaceOnUse" cx="{x0b+60}" cy="{y0b+40}" r="{RO*1.2:.0f}">'
            f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>'
            f'<radialGradient id="wm" gradientUnits="userSpaceOnUse" cx="{x1b}" cy="{y1b}" r="{RO*1.6:.0f}">'
            f'<stop offset="0" stop-color="{warm}" stop-opacity="0.38"/><stop offset="1" stop-color="{warm}" stop-opacity="0"/></radialGradient>'
            f'<clipPath id="c"><path d="{paper_d}"/></clipPath>')
    body = ""
    for i, (dx, dy, b, op) in enumerate(sh):
        defs += blur(f"s{i}", b)
        body += f'<path d="{path([(x+dx, y+dy) for x, y in flap])}" fill="{shade}" opacity="{op}" filter="url(#s{i})"/>'
    return svg(f'<path d="{paper_d}" fill="url(#p)"/><g clip-path="url(#c)">'
               f'<rect width="1024" height="1024" fill="url(#hl)"/><rect width="1024" height="1024" fill="url(#wm)"/>{body}</g>', defs)

CURL = {"light": [(0, "#FFB096"), (0.18, "#FF9174"), (0.6, "#FF6E5E"), (1, "#EC4A57")],
        # tinted: a clear step darker than the paper so the fold still reads
        "tinted": [(0, "#B8B8B8"), (0.5, "#8C8C8C"), (1, "#6E6E6E")]}

def curl_svg(mode):
    g0, g1 = flap_g
    defs = (f'<linearGradient id="f" gradientUnits="userSpaceOnUse" x1="{g0[0]:.1f}" y1="{g0[1]:.1f}" '
            f'x2="{g1[0]:.1f}" y2="{g1[1]:.1f}">{stops(CURL[mode])}</linearGradient>')
    return svg(f'<path d="{path(flap)}" fill="url(#f)"/>', defs)

SCENE = {
    "light": dict(sky=("#3A2FCF", "#3F86FF", "#FFC08E"), planet=("#1B2A8F", "#121552"),
                  rim="#9CFFE8", sun=("#FFF8E8", "#FF9A78", "#FF5A4C"), glow=1.0),
    "dark": dict(sky=("#1E1A80", "#2F6FE8", "#FFBA8E"), planet=("#141F70", "#0B0D3A"),
                 rim="#7CFFE0", sun=("#FFF6E4", "#FF9474", "#FF5A4C"), glow=1.0),
    # tinted: the system tints the ring at full strength, so the view stays
    # dark to keep the ring crisp; a thin bright band, rim and sun mark the horizon
    "tinted": dict(sky=("#0E0E0E", "#161616", "#7A7A7A"), planet=("#000000", "#000000"),
                   rim="#FFFFFF", sun=("#FFFFFF", "#F4F4F4", "#D8D8D8"), glow=0.3),
}

def view_svg(mode):
    """The dawn seen through the ring."""
    c = SCENE[mode]
    r = RI + 10
    x0b, y0b, x1b, y1b = CX - r, CY - r, CX + r, CY + r
    hy = CY + RI*P["HY"]; sx = CX + RI*P["SX"]; sr = P["SUN"]; pr = 520
    defs = (f'<clipPath id="w"><path d="{path(circle_pts(CX, CY, r))}"/></clipPath>'
            f'<linearGradient id="sky" gradientUnits="userSpaceOnUse" x1="0" y1="{y0b}" x2="0" y2="{hy}">'
            f'{stops([(0, c["sky"][0]), (0.6, c["sky"][1]), (1, c["sky"][2])])}</linearGradient>'
            f'<radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{hy}" r="200">'
            f'<stop offset="0" stop-color="{c["sun"][0]}" stop-opacity="{c["glow"]}"/><stop offset="1" stop-color="{c["sun"][0]}" stop-opacity="0"/></radialGradient>'
            f'<radialGradient id="pl" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{hy}" r="{y1b-hy+40}">'
            f'<stop offset="0" stop-color="{c["planet"][0]}"/><stop offset="1" stop-color="{c["planet"][1]}"/></radialGradient>'
            f'<radialGradient id="sun" gradientUnits="userSpaceOnUse" cx="{sx}" cy="{hy-sr*0.25:.1f}" r="{sr*1.25:.1f}">'
            f'{stops([(0, c["sun"][0]), (0.42, c["sun"][1]), (1, c["sun"][2])])}</radialGradient>'
            f'{blur("bl", 6)}'
            f'<linearGradient id="ins" gradientUnits="userSpaceOnUse" x1="0" y1="{y0b}" x2="0" y2="{y0b+60}">'
            f'<stop offset="0" stop-color="#0A0830" stop-opacity="0.45"/><stop offset="1" stop-color="#0A0830" stop-opacity="0"/></linearGradient>')
    return svg(f'<g clip-path="url(#w)">'
               f'<rect x="{x0b}" y="{y0b}" width="{2*r}" height="{2*r}" fill="url(#sky)"/>'
               f'<rect x="{x0b}" y="{y0b}" width="{2*r}" height="{2*r}" fill="url(#glow)"/>'
               f'<circle cx="{sx}" cy="{hy}" r="{sr}" fill="url(#sun)"/>'
               f'<circle cx="{sx}" cy="{hy+pr}" r="{pr+5}" fill="{c["rim"]}" opacity="0.9" filter="url(#bl)"/>'
               f'<circle cx="{sx}" cy="{hy+pr}" r="{pr}" fill="url(#pl)"/>'
               f'<rect x="{x0b}" y="{y0b}" width="{2*r}" height="60" fill="url(#ins)"/></g>', defs)

def bloom_svg(dark):
    c1, o1, c2, o2 = ("#1FB5A0", 0.5, "#5B3BFF", 0.6) if dark else ("#B8FFE0", 0.9, "#6B4BFF", 0.85)
    defs = (f'<radialGradient id="a" gradientUnits="userSpaceOnUse" cx="150" cy="120" r="640">'
            f'<stop offset="0" stop-color="{c1}" stop-opacity="{o1}"/><stop offset="1" stop-color="{c1}" stop-opacity="0"/></radialGradient>'
            f'<radialGradient id="b" gradientUnits="userSpaceOnUse" cx="960" cy="980" r="660">'
            f'<stop offset="0" stop-color="{c2}" stop-opacity="{o2}"/><stop offset="1" stop-color="{c2}" stop-opacity="0"/></radialGradient>')
    return svg('<rect width="1024" height="1024" fill="url(#a)"/><rect width="1024" height="1024" fill="url(#b)"/>', defs)

# ---------------------------------------------------------------- document

def layer(name, files, glass):
    """files: {"": default, "dark": ..., "tinted": ...}"""
    specs = [{"value": files[""]}] + [{"appearance": k, "value": f} for k, f in files.items() if k]
    return {"name": name, "glass": glass, "image-name-specializations": specs}

def group(name, layers, shadow=0.0, trans=None, specular=False):
    return {"name": name, "layers": layers,
            "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": trans is not None, "value": trans or 0},
            "specular": specular}

assets = os.path.join(OUT, "Assets")
os.makedirs(assets, exist_ok=True)
for f in os.listdir(assets):
    os.remove(os.path.join(assets, f))
files = {
    "curl.svg": curl_svg("light"), "curl-tinted.svg": curl_svg("tinted"),
    "ring.svg": ring_svg("light"), "ring-dark.svg": ring_svg("dark"), "ring-tinted.svg": ring_svg("tinted"),
    "view.svg": view_svg("light"), "view-dark.svg": view_svg("dark"), "view-tinted.svg": view_svg("tinted"),
    "bloom.svg": bloom_svg(False), "bloom-dark.svg": bloom_svg(True),
}
for name, s in files.items():
    with open(os.path.join(assets, name), "w") as fh:
        fh.write(s)

grad = lambda a, b: {"linear-gradient": [a, b], "orientation": {"start": {"x": 0.2, "y": 0}, "stop": {"x": 0.8, "y": 1}}}
doc = {
    "groups": [
        group("Curl", [layer("Curl", {"": "curl.svg", "tinted": "curl-tinted.svg"}, True)],
              # no specular: the glass ridge made the flat flap look inflated
              shadow=0.45, specular=False),
        group("Ring", [layer("Ring", {"": "ring.svg", "dark": "ring-dark.svg", "tinted": "ring-tinted.svg"}, True)],
              shadow=0.5, trans=0.12, specular=True),
        group("View", [layer("View", {"": "view.svg", "dark": "view-dark.svg", "tinted": "view-tinted.svg"}, False)]),
        # no bloom in tinted: a dark field keeps the tinted mark crisp
        group("Bloom", [dict(layer("Bloom", {"": "bloom.svg", "dark": "bloom-dark.svg"}, False),
                             **{"hidden-specializations": [{"appearance": "tinted", "value": True}]})]),
    ],
    "supported-platforms": {"squares": "shared", "circles": ["watchOS"]},
    "fill-specializations": [
        {"value": grad("srgb:0.20,0.86,0.78,1.0", "srgb:0.16,0.45,1.0,1.0")},
        {"appearance": "dark", "value": grad("srgb:0.04,0.13,0.20,1.0", "srgb:0.06,0.06,0.20,1.0")},
    ],
}
with open(os.path.join(OUT, "icon.json"), "w") as fh:
    json.dump(doc, fh, indent=2)

if os.environ.get("SILHOUETTE"):
    body = "".join(f'<path d="{path(s)}" fill="#000000"/>' for s in shapes + [flap])
    with open(os.environ["SILHOUETTE"], "w") as fh:
        fh.write(svg(f'<rect width="1024" height="1024" fill="#FFFFFF"/>{body}'))
print("wrote", os.path.normpath(OUT))
