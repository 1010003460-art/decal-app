# 独立基准比对：numpy DLT(SVD) 解单应 + 逐像素逆采样，与页面导出的 PNG 比。
# 页面用的是 8x8 高斯消元、GPU 光栅化；这里是 SVD + CPU 双线性。两套实现一致
# 才说明"着色器里的坐标没搞错"（y 方向、uv 顺序、宽高比修正）。
import json, sys
import numpy as np
from PIL import Image

def dlt(quad_img):
    # 单位方 (0,0)(1,0)(1,1)(0,1) -> 图像四角
    src = [(0, 0), (1, 0), (1, 1), (0, 1)]
    A = []
    for (u, v), (x, y) in zip(src, quad_img):
        A.append([u, v, 1, 0, 0, 0, -x * u, -x * v, -x])
        A.append([0, 0, 0, u, v, 1, -y * u, -y * v, -y])
    _, _, Vt = np.linalg.svd(np.array(A, dtype=np.float64))
    h = Vt[-1]
    return (h / h[-1]).reshape(3, 3)

def grid_decal():
    # 与页面共用同一张 PNG，避免"两端各自画方格"带来的抗锯齿差异
    return np.asarray(Image.open('grid.png').convert('RGBA'), dtype=np.float32) / 255.0

def bilinear(tex, u, v):
    h, w = tex.shape[:2]
    x = np.clip(u * (w - 1), 0, w - 1.001)
    y = np.clip(v * (h - 1), 0, h - 1.001)
    x0 = np.floor(x).astype(np.int32); y0 = np.floor(y).astype(np.int32)
    tx = (x - x0)[..., None]; ty = (y - y0)[..., None]
    x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
    a = tex[y0, x0] * (1 - tx) + tex[y0, x1] * tx
    b = tex[y1, x0] * (1 - tx) + tex[y1, x1] * tx
    return a * (1 - ty) + b * ty

def run(tag):
    info = json.load(open(f'{tag}.json'))
    base = np.asarray(Image.open(info['img']).convert('RGB'), dtype=np.float32) / 255.0
    got = np.asarray(Image.open(f'{tag}.png').convert('RGB'), dtype=np.float32) / 255.0
    H, W = base.shape[:2]
    assert got.shape[:2] == (H, W), (got.shape, base.shape)

    M = dlt(info['corners'])
    Minv = np.linalg.inv(M)
    tex = grid_decal()
    c = [info['center']['x'], info['center']['y']]; hw, hh = info['half']; rot = np.radians(-info['rot'])

    ys, xs = np.mgrid[0:H, 0:W]
    P = np.stack([xs + 0.5, ys + 0.5, np.ones_like(xs)], -1).reshape(-1, 3).T
    Q = Minv @ P
    uv = (Q[:2] / Q[2]).T.reshape(H, W, 2)

    d = uv - np.array(c)
    ca, sa = np.cos(rot), np.sin(rot)
    e = np.stack([ca * d[..., 0] - sa * d[..., 1], sa * d[..., 0] + ca * d[..., 1]], -1)
    n = e / np.array([hw, hh])

    inside_plane = (uv[..., 0] > 0.02) & (uv[..., 0] < 0.98) & (uv[..., 1] > 0.02) & (uv[..., 1] < 0.98)
    inside_decal = (np.abs(n[..., 0]) < 0.98) & (np.abs(n[..., 1]) < 0.98)
    m = np.maximum(np.abs(n[..., 0]), np.abs(n[..., 1]))
    band = (m > 0.9) & (m < 1.08)      # 边缘 AA 带不参与比对
    mask = inside_plane & inside_decal & ~band

    t = bilinear(tex, np.clip(n[..., 0] * 0.5 + 0.5, 0, 1), np.clip(n[..., 1] * 0.5 + 0.5, 0, 1))
    # 贴花框外 alpha 必须是 0（页面靠 smoothstep 做到这一点，这里显式置零）
    a = t[..., 3:4] * (np.maximum(np.abs(n[..., 0]), np.abs(n[..., 1])) < 1.0)[..., None]
    ref = base * (1 - a) + t[..., :3] * a

    diff_full = np.abs(ref - got).max(-1)
    # 方格线附近 3 texel 内是高对比边缘，硬件双线性与 CPU 浮点双线性必然差一点，
    # 只报不判；真正的判据是"远离边缘的区域必须几乎一致"。
    tu = (n[..., 0] * 0.5 + 0.5) * 1023
    tv = (n[..., 1] * 0.5 + 0.5) * 339
    du = np.minimum(tu % 64, 64 - (tu % 64))
    dv = np.minimum(tv % 68, 68 - (tv % 68))
    edge = (du < 4.5) | (dv < 4.5)
    inner = mask & ~edge
    e_band = mask & edge

    def stat(m):
        d = diff_full[m]
        return (d.max(), d.mean(), np.percentile(d, 99)) if d.size else (0, 0, 0)

    mx_i, mean_i, p99_i = stat(inner)
    mx_e, mean_e, _ = stat(e_band)
    print(f'{tag:14} 内部 {inner.sum():>7}px  最大 {mx_i*255:5.2f}/255  平均 {mean_i*255:.3f}  p99 {p99_i*255:5.2f}')
    print(f'{"":14} 边缘 {e_band.sum():>7}px  最大 {mx_e*255:5.2f}/255  平均 {mean_e*255:.3f}   （只报告，高对比边缘的亚纹素差）')
    return mx_i


worst = 0
for tag in ['chk_building', 'chk_bottle', 'chk_face']:
    r = run(tag)
    if r is not None:
        worst = max(worst, r)
print()
print('判定：内部区域最大差 < 2/255 ⇒ 着色器坐标与独立实现一致')
print('结论：', 'PASS' if worst < 2 / 255 else f'FAIL (worst {worst*255:.1f}/255)')
sys.exit(0 if worst < 2 / 255 else 1)
