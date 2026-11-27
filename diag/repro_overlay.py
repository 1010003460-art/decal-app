# -*- coding: utf-8 -*-
"""复现 iOS 版「展平 → 贴花 → 反贴回原图」整条链路，量化贴花到底能看见多少。

严格照抄 Decal/Perspective.swift + ContentView.swift::compose 的算法：
  solve(flatCorners -> quad)  ->  inverted()  ->  逐像素反向映射采样
只把 Swift 换成 numpy 向量化，算法顺序一字不改。
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

# ---------- 照抄 Homography.swift ----------
def solve(src, dst):
    a = np.zeros((8, 9))
    for i in range(4):
        x, y = src[i]
        u, v = dst[i]
        a[i*2]     = [x, y, 1, 0, 0, 0, -u*x, -u*y, u]
        a[i*2 + 1] = [0, 0, 0, x, y, 1, -v*x, -v*y, v]
    for col in range(8):
        piv = col + int(np.argmax(np.abs(a[col:, col])))
        if abs(a[piv, col]) < 1e-12:
            return None
        if piv != col:
            a[[piv, col]] = a[[col, piv]]
        a[col] /= a[col, col]
        for r in range(8):
            if r != col and a[r, col] != 0:
                a[r] -= a[r, col] * a[col]
    h = np.zeros(9)
    h[:8] = a[:, 8]
    h[8] = 1.0
    return h.reshape(3, 3)

def inverted(m):
    return np.linalg.inv(m)

# ---------- 造一张有透视的"照片" ----------
W, H = 900, 675
rng = np.random.default_rng(7)
base = np.zeros((H, W, 3), np.uint8)
# 背景：天空渐变
for y in range(H):
    t = y / H
    base[y, :] = (int(150 - 60*t), int(180 - 70*t), int(215 - 60*t))
# 一面带砖纹的墙（四边形，占画面一部分）—— 用透视四边形画上去当"真实平面"
def fill_quad(img, quad, color, seed=0):
    r = np.random.default_rng(seed)
    poly = Image.new('L', (img.shape[1], img.shape[0]), 0)
    ImageDraw.Draw(poly).polygon(quad, fill=255)
    mask = np.array(poly, bool)
    noise = (r.normal(0, 12, img.shape[:2])).astype(np.int16)
    for c in range(3):
        ch = img[:, :, c].astype(np.int16)
        ch[mask] = np.clip(color[c] + noise[mask], 0, 255)
        img[:, :, c] = ch.astype(np.uint8)
    return img

# 绘制按顺时针，算法按 TL,TR,BL,BR —— 两者顺序要求不同，必须分开
WALL_POLY = [(120, 140), (780, 110), (820, 600), (90, 620)]
WALL = [(120, 140), (780, 110), (90, 620), (820, 600)]   # TL,TR,BL,BR
base = fill_quad(base, WALL_POLY, (196, 168, 132), 3)

# ---------- 贴纸（照抄 Decal.make 的比例：640x200 圆角块 + MAX）----------
def make_decal():
    d = Image.new('RGBA', (640, 200), (0, 0, 0, 0))
    dr = ImageDraw.Draw(d)
    dr.rounded_rectangle([6, 6, 634, 194], 34, fill=(13, 158, 184, 242))
    dr.rounded_rectangle([6, 6, 634, 194], 34, outline=(255, 255, 255, 217), width=6)
    try:
        f = ImageFont.truetype("arialbd.ttf", 126)
    except Exception:
        f = ImageFont.load_default()
    bb = dr.textbbox((0, 0), "MAX", font=f)
    dr.text(((640 - (bb[2]-bb[0]))/2 - bb[0], (200 - (bb[3]-bb[1]))/2 - bb[1]),
            "MAX", font=f, fill=(255, 255, 255, 255))
    return d

DECAL = make_decal()

# ---------- 照抄 compose 的合成顺序 ----------
def compose(orig_np, quad_down):
    """orig_np: HxWx3 uint8; quad_down: [TL,TR,BL,BR] 像素坐标 y 向下"""
    ow, oh = orig_np.shape[1], orig_np.shape[0]
    # 1) flatten：CIPerspectiveCorrection 等价物 —— 输出尺寸取四边形上下边长的较大值
    q = np.array(quad_down, float)
    fw = int(round(max(np.linalg.norm(q[1]-q[0]), np.linalg.norm(q[3]-q[2]))))
    fh = int(round(max(np.linalg.norm(q[2]-q[0]), np.linalg.norm(q[3]-q[1]))))
    flat_corners = np.array([[0,0], [fw,0], [0,fh], [fw,fh]], float)
    h_flat_to_quad = solve(flat_corners, q)          # 输出(flat) -> 输入(原图)
    coeffs = h_flat_to_quad.flatten()[:8]
    flat = Image.fromarray(orig_np).transform((fw, fh), Image.PERSPECTIVE,
                                              tuple(coeffs), resample=Image.BICUBIC)
    # 2) 在展平图上贴花：宽 0.30*fw，居中（照抄 compose 的 dw/cx/cy）
    dw = fw * 0.30
    dh = dw * DECAL.size[1] / DECAL.size[0]
    cx, cy = fw*0.5, fh*0.5
    merged = flat.convert('RGBA')
    dec = DECAL.resize((max(1,int(dw)), max(1,int(dh))), Image.LANCZOS)
    merged.alpha_composite(dec, (int(cx - dw/2), int(cy - dh/2)))
    merged = merged.convert('RGB')            # opaque=true 的效果
    merged_np = np.array(merged)
    decal_mask = np.zeros((fh, fw), bool)     # 记录贴花像素，供统计
    a = np.array(dec)[:, :, 3] > 8
    x0, y0 = int(cx - dw/2), int(cy - dh/2)
    x1, y1 = min(fw, x0 + a.shape[1]), min(fh, y0 + a.shape[0])
    if x1 > x0 and y1 > y0:
        decal_mask[max(0,y0):y1, max(0,x0):x1] = a[max(0,-y0):max(0,-y0)+(y1-max(0,y0)),
                                                   max(0,-x0):max(0,-x0)+(x1-max(0,x0))]
    # 3) overlay：照抄 Perspective.overlay 的反向映射
    inv = inverted(h_flat_to_quad)            # quad -> flat 坐标
    ys, xs = np.mgrid[0:oh, 0:ow]
    px = xs + 0.5
    py = ys + 0.5
    w = inv[2,0]*px + inv[2,1]*py + inv[2,2]
    with np.errstate(divide='ignore', invalid='ignore'):
        u = (inv[0,0]*px + inv[0,1]*py + inv[0,2]) / w
        v = (inv[1,0]*px + inv[1,1]*py + inv[1,2]) / w
    ok = np.isfinite(u) & np.isfinite(v) & (u >= -1) & (u <= fw+1) & (v >= -1) & (v <= fh+1)
    out = orig_np.copy()
    ui = np.clip(np.round(u).astype(int), 0, fw-1)
    vi = np.clip(np.round(v).astype(int), 0, fh-1)
    out[ok] = merged_np[vi[ok], ui[ok]]
    # 4) 统计：贴花在最终图上可见多少像素
    decal_in_out = ok & decal_mask[vi, ui]
    return out, flat, merged_np, int(ok.sum()), int(decal_in_out.sum())

def run(name, quad):
    out, flat, merged, cov, decal_px = compose(np.array(Image.fromarray(base)), quad)
    total = W*H
    print(f"{name}")
    print(f"  quad 覆盖画面    {cov/total*100:5.1f}%  ({cov} px)")
    print(f"  贴花可见像素    {decal_px} px  = 画面 {decal_px/total*100:.3f}%")
    Image.fromarray(out).save(f"diag/{name}_out.png")
    flat.save(f"diag/{name}_flat.png")
    return decal_px, total

if __name__ == "__main__":
    import os
    os.makedirs("diag", exist_ok=True)
    Image.fromarray(base).save("diag/00_orig.png")

    # A: 没找到矩形 → 默认"整张照片"（5%~95%）
    A = [(0.05*W, 0.05*H), (0.95*W, 0.05*H), (0.05*W, 0.95*H), (0.95*W, 0.95*H)]
    a_px, total = run("A_整张照片", A)

    # B: 检测到画面里那面墙（约 75% 画面）
    B = WALL
    b_px, _ = run("B_检测到墙面", B)

    # C: 检测到一个小标牌（约 12% 画面）
    C = [(300, 250), (520, 240), (300, 370), (520, 360)]
    c_px, _ = run("C_检测到小矩形", C)

    print("\n=== 贴花相对原图的可见面积 ===")
    for n, p in [("A 整张照片", a_px), ("B 检测到墙面", b_px), ("C 小矩形", c_px)]:
        print(f"  {n:12s} {p:7d} px   {p/total*100:6.3f}%")
