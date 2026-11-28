"""光照层的性质检查。纯标准库，1 秒跑完，进 CI（macOS runner 没装 numpy）。

⚠️ 这里的公式必须和 Decal/Shaders.metal 的 `if (a > 0.002)` 段逐字对应。
改 shader 不改这里 → 门禁失效；改这里不改 shader → 自欺欺人。

检的是四条物理性质，不是「算出来的数值好看」：
  1. 亮度守恒：亮部未滚降时，贴花亮度严格 = 原亮度 × kk；降饱和不许偷偷改亮度
  2. 饱和度只降不升：印刷品在明处过曝趋白、暗处被散射光冲淡，两头都掉饱和
  3. 色相守恒：整体系数 + 滚降都不许改变色相（旧公式毁在这条，见下）
  4. shade=0 时完整退化成「原样贴上去」，不留任何残影

两条被否决的方案，记在这里免得以后再走一遍：
  · 色温跟随 tint = base/surf —— 白面上 tint 恒为 1（白白相乘还是白，物理对但零收益），
    彩色面上会把贴花刷成表面固有色（砖墙染红、草地染绿），那是表面颜色不是光照颜色。
  · 逐像素亮度做 kk —— 贴花会透出底下的砖缝/手写字，是半透明叠加不是印刷。
    现方案改用 32px 低频光照场（texture(3)，见 Editor.buildLightTex）。

第 3 条锁的是一个真 bug：旧公式先算 float3(L*kk) 再和色度相加、最后 clamp 到 [0,1]。
kk 大时亮通道先撞顶被削，暗通道还在加，色相就漂了 —— kk=2.5 时绿 (0.15,0.65,0.25)
被削成纯白（Δhue -132°）、洋红 -20.5°。顺序改成「整体乘 → 按最大分量滚降 → 降饱和」后，
色相严格不变，且结果自然落在 [0,1]，不再依赖 clamp 兜底。
"""
import colorsys

LUMA = (0.2126, 0.7152, 0.0722)


def kk_of(surf, anchor, shade):
    """mix(1, clamp(surf/anchor, .25, 2.5), shade)"""
    return 1.0 + (min(max(surf / max(anchor, 0.02), 0.25), 2.5) - 1.0) * shade


def paint_of(dt, surf, base, anchor, shade):
    """dt/base: RGB 三元组；surf: 表面亮度。与 shader 同序，逐字对应。"""
    kk = kk_of(surf, anchor, shade)

    paint = [c * kk for c in dt]                     # 整体乘：色相不变
    mx = max(paint)
    if mx > 1.0:
        paint = [v / mx for v in paint]              # 过曝整体滚降

    cs = min(kk, 1.0 / max(kk, 1e-3))
    g = cs ** (0.4 * shade)
    lx = sum(c * w for c, w in zip(paint, LUMA))
    paint = [lx + (c - lx) * g for c in paint]       # 两端降饱和

    haze = min(max(1.0 - kk, 0.0), 1.0) * 0.35 * shade
    return [p * (1 - haze) + b * haze for p, b in zip(paint, base)], kk


def legacy_paint_of(dt, surf, anchor, shade):
    """被换掉的旧公式，只用来做对照，证明第 3 条不是空话。"""
    kk = kk_of(surf, anchor, shade)
    L = sum(c * w for c, w in zip(dt, LUMA))
    g = min(kk, 1.0 / kk) ** (0.4 * shade)
    return [min(max(L * kk + (c - L) * g, 0.0), 1.0) for c in dt]


def main():
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
        ok = ok and bool(cond)

    colors = [(1, 1, 1), (0, 0, 0), (0, 0.75, 0.86), (0.9, 0.2, 0.1),
              (0.05, 0.05, 0.4), (0.15, 0.65, 0.25), (0.85, 0.15, 0.55)]
    anchor, shade = 0.4, 0.75

    print("1. 亮度守恒（未滚降区间，亮度严格 = L×kk；降饱和不许改亮度）")
    worst = 0.0
    for c in colors:
        for s in (0.02, 0.1, 0.3, 0.6, 0.95):
            kk = kk_of(s, anchor, shade)
            L = sum(v * w for v, w in zip(c, LUMA))
            if L * kk > 1.0:
                continue                              # 滚降区间另算，见第 3 条
            p, _ = paint_of(c, s, (0.3, 0.3, 0.3), anchor, shade)
            # paint_of 含 haze，这里只验不含 haze 的那一段
            paint = [v * kk for v in c]
            mx = max(paint)
            if mx > 1.0:
                paint = [v / mx for v in paint]
            g = min(kk, 1.0 / kk) ** (0.4 * shade)
            lx = sum(v * w for v, w in zip(paint, LUMA))
            after = [lx + (v - lx) * g for v in paint]
            worst = max(worst, abs(sum(v * w for v, w in zip(after, LUMA)) - lx))
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

    print("3. 色相守恒 + 不越界（旧公式在这里翻车）")
    def hue(c):
        return colorsys.rgb_to_hsv(*[min(max(v, 0.0), 1.0) for v in c])[0] * 360.0

    worst_h, worst_out, worst_legacy = 0.0, 0.0, 0.0
    for c in colors:
        for kk in (0.25, 0.4, 0.7, 1.0, 1.6, 2.0, 2.5):
            surf = anchor * kk
            # 用 shade=1 关掉 mix 的软化，直接打满 kk
            paint = [v * kk for v in c]
            mx = max(paint)
            if mx > 1.0:
                paint = [v / mx for v in paint]
            g = min(kk, 1.0 / kk) ** 0.4
            lx = sum(v * w for v, w in zip(paint, LUMA))
            after = [lx + (v - lx) * g for v in paint]
            if max(c) - min(c) > 0.02:                # 纯灰没有色相可言
                d = abs(hue(after) - hue(c))
                worst_h = max(worst_h, min(d, 360 - d))
            worst_out = max(worst_out, max(after) - 1.0, -min(after))
            lg = legacy_paint_of(c, surf, anchor, 1.0)
            if max(c) - min(c) > 0.02:
                d = abs(hue(lg) - hue(c))
                worst_legacy = max(worst_legacy, min(d, 360 - d))
    check("色相漂移 < 0.5°（含滚降区间）", worst_h < 0.5, f"最大 {worst_h:.3f}°")
    check("结果天然落在 [0,1]，不靠 clamp 兜底", worst_out < 1e-9, f"越界 {worst_out:.2e}")
    check("对照：旧公式最大色相漂移", worst_legacy > 20.0,
          f"{worst_legacy:.1f}°（绿被削成纯白），这就是本轮的 bug")

    print("4. shade=0 退化成原样贴上去")
    bad = None
    for s in (0.05, 0.5, 1.0):
        for c in colors[:3]:
            p, _ = paint_of(c, s, (0.3, 0.3, 0.3), 0.4, 0.0)
            if max(abs(p[i] - c[i]) for i in range(3)) > 1e-6:
                bad = (s, c, [round(v, 6) for v in p])
    check("shade=0 时 paint == dt（贴花原样）", bad is None, str(bad or ""))

    print("5. 真实照片上的实际降饱和幅度（有 numpy/PIL 才跑，CI 上跳过）")
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
