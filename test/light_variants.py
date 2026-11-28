"""光照层：新旧公式在真实照片上的目视对比。

复刻 Shaders.metal 的完整融合链（单应/uv/贴花框全用 ref_check.py 的同一套 DLT），
只把最后一段 paint 换成旧公式，用来判断「新公式到底改了什么、有没有更好」。

人工看这张图，不是自动判定。数值性质由 light_check.py 锁。
"""
import json
import pathlib

import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).parent
_src = (HERE / "ref_check.py").read_text(encoding="utf-8")
exec(_src.split("def run(")[0])          # 只取 dlt / grid_decal / bilinear，避开它的顶层测试

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
SHADE = 0.75


def kk_of(surf, anchor, shade):
    return 1.0 + (np.clip(surf / max(anchor, 0.02), 0.25, 2.5) - 1.0) * shade


def paint_new(dt, surf, base, anchor, shade):
    """与 Shaders.metal 当前实现逐字对应"""
    kk = kk_of(surf, anchor, shade)
    L = dt @ LUMA
    cs = np.minimum(kk, 1.0 / np.maximum(kk, 1e-3))
    g = cs ** (0.4 * shade)
    p = (L * kk)[..., None] + (dt - L[..., None]) * g[..., None]
    hz = (np.clip(1.0 - kk, 0.0, 1.0) * 0.35 * shade)[..., None]
    return p * (1.0 - hz) + base * hz


def lowfreq_lum(photo, w=32):
    """模拟 Editor.buildLowLum + 双线性采样：32px 宽的亮度场再放回原尺寸。
    这就是「光照场」的近似 —— 极低频，不含砖缝/文字这种高频。"""
    H, W = photo.shape[:2]
    h = max(1, round(w * H / W))
    small = np.asarray(Image.fromarray((photo * 255).astype(np.uint8))
                       .resize((w, h), Image.BILINEAR), dtype=np.float32) / 255.0
    lum = small @ LUMA
    return np.asarray(Image.fromarray((lum * 255).astype(np.uint8))
                      .resize((W, H), Image.BILINEAR), dtype=np.float32) / 255.0


def paint_lowfreq(dt, surf, base, anchor, shade):
    """新公式 + 光照场（用低频亮度代替逐像素亮度）"""
    return paint_new(dt, surf, base, anchor, shade)


def paint_old(dt, surf, base, anchor, shade):
    """改之前的公式：pow(kk, 0.42)，暗处会抬饱和"""
    kk = kk_of(surf, anchor, shade)
    L = dt @ LUMA
    return (L * kk)[..., None] + (dt - L[..., None]) * (kk ** 0.42)[..., None]


def render(tag, fn, lowfreq=False):
    info = json.load(open(HERE / f"{tag}.json"))
    photo = np.asarray(Image.open(HERE / info["img"]).convert("RGB"), dtype=np.float32) / 255.0
    decal = np.asarray(Image.open(HERE / "decal.png").convert("RGBA"), dtype=np.float32) / 255.0
    H, W = photo.shape[:2]

    M = dlt(info["corners"])
    Minv = np.linalg.inv(M)
    ys, xs = np.mgrid[0:H, 0:W]
    P = np.stack([xs + 0.5, ys + 0.5, np.ones_like(xs)], -1).reshape(-1, 3).T
    Q = Minv @ P
    uv = (Q[:2] / Q[2]).T.reshape(H, W, 2)

    c = np.array([info["center"]["x"], info["center"]["y"]])
    hw, hh = info["half"]
    rot = np.radians(info["rot"])
    d = uv - c
    ca, sa = np.cos(rot), np.sin(rot)
    e = np.stack([ca * d[..., 0] + sa * d[..., 1], -sa * d[..., 0] + ca * d[..., 1]], -1)
    n = e / np.array([hw, hh])
    m = np.maximum(np.abs(n[..., 0]), np.abs(n[..., 1]))
    cov = (m <= 1.0).astype(np.float32)

    surf_raw = photo @ LUMA
    surf = lowfreq_lum(photo) if lowfreq else surf_raw
    anchor = float(surf[cov > 0].mean())
    vt = np.clip(n * 0.5 + 0.5, 0, 1)
    dt = bilinear(decal[..., :3], vt[..., 0], vt[..., 1])
    da = bilinear(decal[..., 3:4], vt[..., 0], vt[..., 1])[..., 0]
    a = (da * cov)[..., None]

    p = np.clip(fn(dt, surf, photo, anchor, SHADE), 0, 1)
    out = photo * (1 - a) + p * a
    print(f"{tag}: anchor={anchor:.3f}")
    return (np.clip(out, 0, 1) * 255).astype(np.uint8)


if __name__ == "__main__":
    for tag in ["chk_bottle", "chk_face"]:
        a = render(tag, paint_new)                 # 逐像素亮度
        b = render(tag, paint_new, lowfreq=True)   # 低频光照场
        sep = np.full((a.shape[0], 4, 3), 255, dtype=np.uint8)
        row = np.concatenate([a, sep, b], 1)
        out = HERE / f"light_{tag.replace('chk_', '')}.png"
        Image.fromarray(row).save(out)
        print("  已写", out.name)
    print("左＝逐像素亮度(现状)  右＝低频光照场")
