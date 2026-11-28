"""光照层的性质检查。纯标准库，1 秒跑完，进 CI（macOS runner 没装 numpy）。

⚠️ 这里的公式必须和 Decal/Shaders.metal 的 `if (a > 0.002)` 段逐字对应。
改 shader 不改这里 → 门禁失效；改这里不改 shader → 自欺欺人。

检的是三条物理性质，不是「算出来的数值好看」：
  1. 亮度守恒：贴花的亮度由 kk 决定，色度处理不能偷偷改亮度
  2. 饱和度只降不升：印刷品在明处过曝趋白、暗处被散射光冲淡，两头都掉饱和
  3. shade=0 时完整退化成「原样贴上去」，不留任何残影

两条被否决的方案，记在这里免得以后再走一遍：
  · 色温跟随 tint = base/surf —— 白面上 tint 恒为 1（白白相乘还是白，物理对但零收益），
    彩色面上会把贴花刷成表面固有色（砖墙染红、草地染绿），那是表面颜色不是光照颜色。
  · 逐像素亮度做 kk —— 贴花会透出底下的砖缝/手写字，是半透明叠加不是印刷。
    现方案改用 32px 低频光照场（texture(3)，见 Editor.buildLightTex）。
"""
LUMA = (0.2126, 0.7152, 0.0722)


def kk_of(surf, anchor, shade):
    """mix(1, clamp(surf/anchor, .25, 2.5), shade)"""
    return 1.0 + (min(max(surf / max(anchor, 0.02), 0.25), 2.5) - 1.0) * shade


def paint_of(dt, surf, base, anchor, shade):
    """dt/base: RGB 三元组；surf: 表面亮度。与 shader 同序。"""
    kk = kk_of(surf, anchor, shade)
    L = sum(c * w for c, w in zip(dt, LUMA))
    cs = min(kk, 1.0 / max(kk, 1e-3))
    g = cs ** (0.4 * shade)
    paint = [L * kk + (c - L) * g for c in dt]
    haze = min(max(1.0 - kk, 0.0), 1.0) * 0.35 * shade
    return [p * (1 - haze) + b * haze for p, b in zip(paint, base)], kk


def main():
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
        ok = ok and bool(cond)

    print("1. 亮度守恒（色度处理不许偷偷改亮度）")
    colors = [(1, 1, 1), (0, 0, 0), (0, 0.75, 0.86), (0.9, 0.2, 0.1), (0.05, 0.05, 0.4)]
    anchor, shade = 0.4, 0.75
    worst = 0.0
    for c in colors:
        for s in (0.02, 0.1, 0.3, 0.6, 0.95):
            kk = kk_of(s, anchor, shade)
            L = sum(v * w for v, w in zip(c, LUMA))
            g = min(kk, 1.0 / kk) ** (0.4 * shade)
            p = [L * kk + (v - L) * g for v in c]        # 不含 haze 的那一项
            worst = max(worst, abs(sum(v * w for v, w in zip(p, LUMA)) - L * kk))
    check("色度项零亮度贡献", worst < 1e-9, f"最大偏差 {worst:.2e}")

    print("2. 饱和度只降不升（旧公式 pow(kk,0.42) 在暗处抬饱和，这条锁死）")
    dark = [0.25 + i * (0.75 / 59) for i in range(59)]     # 0.25 → 1
    light = [1.0 + i * (1.5 / 60) for i in range(61)]      # 1 → 2.5
    gd = [min(k, 1.0 / k) ** (0.4 * shade) for k in dark]
    gl = [min(k, 1.0 / k) ** (0.4 * shade) for k in light]
    check("增益处处 <= 1", max(gd + gl) <= 1 + 1e-9, f"最大 {max(gd + gl):.4f}")
    # 离中性越远降得越多：向 kk=1 走是升高，离开 kk=1 是降低
    up = all(gd[i + 1] >= gd[i] - 1e-9 for i in range(len(gd) - 1))
    dn = all(gl[i + 1] <= gl[i] + 1e-9 for i in range(len(gl) - 1))
    check("向 kk=1 单调增、离开 kk=1 单调减", up and dn,
          f"kk=0.25 → {gd[0]:.3f}，kk=1 → {gl[0]:.3f}，kk=2.5 → {gl[-1]:.3f}")
    old = 0.5 ** 0.42
    check("对照：旧公式在 kk=0.5 的增益", old > 0.5, f"{old:.3f} > 0.5（这就是被换掉的原因）")

    print("3. shade=0 退化成原样贴上去")
    bad = None
    for s in (0.05, 0.5, 1.0):
        for c in colors[:3]:
            p, _ = paint_of(c, s, (0.3, 0.3, 0.3), 0.4, 0.0)
            if max(abs(p[i] - c[i]) for i in range(3)) > 1e-6:
                bad = (s, c, [round(v, 6) for v in p])
    check("shade=0 时 paint == dt（贴花原样）", bad is None, str(bad or ""))

    print("4. 真实照片上的实际降饱和幅度（有 numpy/PIL 才跑，CI 上跳过）")
    try:
        import numpy as np
        from PIL import Image
        for path, box in (("test/building.png", (490, 210, 392, 197)),
                          ("test/bottle.png", (238, 206, 190, 193)),
                          ("test/face.png", (329, 313, 263, 294))):
            im = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
            x, y, w, h = box
            s = (im[y:y + h, x:x + w] @ np.array(LUMA, dtype=np.float32))
            a = max(float(s.mean()), 0.02)
            kk = 1.0 + (np.clip(s / a, 0.25, 2.5) - 1.0) * 0.75
            g = np.minimum(kk, 1.0 / np.maximum(kk, 1e-3)) ** 0.3
            print(f"     {path:20s} anchor={a:.3f}  kk={kk.min():.2f}..{kk.max():.2f}"
                  f"  色度增益={g.min():.3f}..{g.max():.3f}")
    except ImportError:
        print("     跳过（没有 numpy/PIL）")

    print("\n判定：" + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
