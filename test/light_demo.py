"""光照层效果演示：合成一面「有侧光 + 砖缝」的墙，贴一张白贴纸，三种融合并排。

为什么用合成图：真实素材（棚拍瓶子、建筑立面）光照都很均匀，kk 恒在 1 附近，
看不出差别 —— 那恰恰说明「均匀光下不该有明暗变化」是对的。要看效果必须造一个有
光照梯度 + 高频纹理的表面，而这种素材手头没有。

公式与 Decal/Shaders.metal 逐字对应；低频场用 32px 降采样 + 双线性还原，
和 Editor.buildLightTex 的尺度一致。
"""
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).parent
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
SHADE = 0.75
W, H = 640, 460


def make_wall(seed=7):
    """暖色砖墙，左侧暗右侧亮（模拟窗光），每块砖亮度略有抖动。"""
    rng = np.random.default_rng(seed)
    img = np.zeros((H, W, 3), dtype=np.float32)

    by, bx = 46, 92
    for row in range(H // by + 1):
        off = (row % 2) * (bx // 2)
        for col in range(-1, W // bx + 1):
            x0, y0 = col * bx + off, row * by
            tone = 0.78 + 0.22 * rng.random()
            base = np.array([0.62, 0.47, 0.38], dtype=np.float32) * tone
            img[max(0, y0):min(H, y0 + by - 4), max(0, x0):min(W, x0 + bx - 4)] = base

    # 砖缝本来就空着（0）→ 补成砂浆色，再整体加一点噪声当颗粒
    img[img.sum(-1) == 0] = np.array([0.40, 0.38, 0.36], dtype=np.float32)
    img += rng.normal(0, 0.012, img.shape).astype(np.float32)
    img = np.clip(img, 0, 1)

    # 侧光：左 0.30 → 右 1.05，再压一点顶部（天花板不在画面里，越往下越亮）
    gx = np.linspace(0.30, 1.05, W, dtype=np.float32)[None, :]
    gy = np.linspace(0.92, 1.04, H, dtype=np.float32)[:, None]
    return np.clip(img * (gx * gy)[..., None], 0, 1)


def make_decal(w=420, h=210):
    """白底贴纸 + 深灰字。白底最能暴露「透出底下砖缝」这个毛病。"""
    c = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(c)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=18, fill=(246, 246, 242, 255))
    d.rounded_rectangle([10, 10, w - 11, h - 11], radius=12, outline=(60, 60, 62, 120), width=3)
    try:
        f = ImageFont.truetype("arialbd.ttf", 86)
    except OSError:
        f = ImageFont.load_default()
    d.text((w // 2, h // 2), "DECAL", font=f, fill=(38, 38, 42, 255), anchor="mm")
    return np.asarray(c, dtype=np.float32) / 255.0


def lowfreq_lum(photo, w=32):
    h = max(1, round(w * photo.shape[0] / photo.shape[1]))
    small = np.asarray(Image.fromarray((photo * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR),
                       dtype=np.float32) / 255.0
    lum = (small @ LUMA)
    # 3×3 模糊，和 Editor.buildLightTex 对齐
    pad = np.pad(lum, 1, mode="edge")
    blur = sum(pad[dy:dy + lum.shape[0], dx:dx + lum.shape[1]]
               for dy in range(3) for dx in range(3)) / 9.0
    big = Image.fromarray((blur * 255).astype(np.uint8)).resize((photo.shape[1], photo.shape[0]), Image.BILINEAR)
    return np.asarray(big, dtype=np.float32) / 255.0


def render(wall, decal, mode):
    """mode: 'off' | 'old' | 'new'"""
    surf_raw = wall @ LUMA
    surf_lf = lowfreq_lum(wall)

    # 贴花框（uv），故意跨过明暗交界
    cx, cy, hw, hh = 0.50, 0.50, 0.40, 0.22
    ys, xs = np.mgrid[0:H, 0:W]
    u = (xs + 0.5) / W
    v = (ys + 0.5) / H
    n = np.stack([(u - cx) / hw, (v - cy) / hh], -1)
    m = np.maximum(np.abs(n[..., 0]), np.abs(n[..., 1]))
    cov = (m <= 1.0).astype(np.float32)

    dh, dw = decal.shape[:2]
    px = np.clip(((n[..., 0] * 0.5 + 0.5) * (dw - 1)), 0, dw - 1).astype(np.int32)
    py = np.clip(((n[..., 1] * 0.5 + 0.5) * (dh - 1)), 0, dh - 1).astype(np.int32)
    dt = decal[py, px, :3]
    a = (decal[py, px, 3] * cov)[..., None]

    if mode == "off":
        paint = dt
    else:
        surf = surf_lf if mode == "new" else surf_raw
        anchor = float((surf[cov > 0]).mean())
        kk = 1.0 + (np.clip(surf / max(anchor, 0.02), 0.25, 2.5) - 1.0) * SHADE
        L = dt @ LUMA
        chroma = dt - L[..., None]
        if mode == "old":
            paint = (L * kk)[..., None] + chroma * (kk ** 0.42)[..., None]
        else:
            cs = np.minimum(kk, 1.0 / np.maximum(kk, 1e-3))
            paint = (L * kk)[..., None] + chroma * (cs ** (0.4 * SHADE))[..., None]
            hz = (np.clip(1.0 - kk, 0, 1) * 0.35 * SHADE)[..., None]
            paint = paint * (1 - hz) + wall * hz
        paint = np.clip(paint, 0, 1)

    return np.clip(wall * (1 - a) + paint * a, 0, 1)


if __name__ == "__main__":
    wall = make_wall()
    decal = make_decal()
    titles = [("off", "① 关融合"), ("old", "② 旧：逐像素亮度"), ("new", "③ 新：光照场")]
    tiles = []
    for mode, _ in titles:
        tiles.append((render(wall, decal, mode) * 255).astype(np.uint8))
    sep = np.full((H, 4, 3), 255, dtype=np.uint8)
    row = tiles[0]
    for t in tiles[1:]:
        row = np.concatenate([row, sep, t], 1)
    Image.fromarray(row).save(HERE / "light_demo.png")
    print("已写 test/light_demo.png：", " | ".join(t for _, t in titles))
