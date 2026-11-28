#include <metal_stdlib>
using namespace metal;

// 与 Editor.swift 的 `struct Uniforms` 逐字段同序、同类型。
// 对齐检查：5 个 float2 = 40，6 个 float = 24 → 64，float3x3 (align 16) = 48 → 112。
struct Uniforms {
    float2 canvas;
    float2 img;
    float2 offset;
    float2 center;
    float2 halfSize;
    float scale;
    float rot;
    float shade;
    float contact;
    float contactPx;
    float anchor;
    float3x3 hinv;
};

struct VOut {
    float4 pos [[position]];
};

// 一个覆盖全屏的大三角，不用顶点缓冲
vertex VOut vs_main(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    return o;
}

// MSL 没有 GLSL 的 fwidth：屏幕导数绝对值之和。
// 直接内联而不用辅助函数 —— 部分 MSL 版本会拒绝在非 fragment 上下文里出现 dfdx。
#define FW(v) (fabs(dfdx(v)) + fabs(dfdy(v)))

fragment float4 fs_main(VOut in [[stage_in]],
                        constant Uniforms &u [[buffer(0)]],
                        texture2d<float> photo [[texture(0)]],
                        texture2d<float> dtex  [[texture(1)]],
                        // 遮挡 mask（前景物体分割）。走独立纹理而不是 uniform 字段：
                        // Uniforms 是 112 字节的硬约束，加字段要两侧同时改、漏一个整屏错位。
                        texture2d<float> ocl   [[texture(2)]],
                        // 光照场：32px 宽的低频亮度图。同样走纹理，零 uniform 字段。
                        texture2d<float> lit   [[texture(3)]],
                        sampler smp [[sampler(0)]]) {
    const float3 BG   = float3(0.043, 0.047, 0.055);
    const float3 LUMA = float3(0.2126, 0.7152, 0.0722);

    // Metal 的 position 已经是「左上原点 + 像素坐标」，不用像 GL 那样翻 y
    float2 sp = in.pos.xy;
    float2 ip = (sp - u.offset) / u.scale;
    float2 t  = ip / u.img;

    // 照片外的 letterbox 区域：填背景色（GL 版这里会拉出边缘色带）
    if (t.x < 0.0 || t.x > 1.0 || t.y < 0.0 || t.y > 1.0) return float4(BG, 1.0);

    float3 base = photo.sample(smp, t).rgb;

    // ---- 光照场 ----
    // 不透明贴纸不会透出底下的砖缝、手写字、毛孔，只跟随这块表面的整体受光。
    // 用逐像素亮度做融合 = 半透明叠加，看着就是「一张有透明度的图贴上去」。
    // 实测贴花区内的高频残差 std ≈ 0.10~0.13，浅色贴花上一眼能看出来。
    // 这张 32px 的低频图由 Editor.buildLightTex 生成（含 3×3 模糊，防稀疏采样噪点）。
    float surf = lit.sample(smp, t).r;

    // ---- 平面坐标 ----
    float3 hq = u.hinv * float3(ip, 1.0);
    if (fabs(hq.z) < 1e-7) return float4(base, 1.0);
    float2 uv = hq.xy / hq.z;

    // 到平面边界的距离（uv 单位），平面外自动不画
    float2 qd = min(uv, 1.0 - uv);
    float2 fa = max(float2(FW(uv.x), FW(uv.y)), float2(1e-5));
    float planeFade = smoothstep(0.0, fa.x, qd.x) * smoothstep(0.0, fa.y, qd.y);

    // ---- 遮挡：前景物体挡在平面之前时，贴花不该画上去。
    // 没开遮挡时绑的是 1×1 全白纹理，采样恒为 1，这一乘等于不做事 ——
    // 所以开关状态完全由绑哪张纹理决定，shader 里不需要分支，也不需要 uniform 字段。
    float occ = smoothstep(0.35, 0.65, ocl.sample(smp, t).r);
    planeFade *= occ;

    // ---- 贴花局部坐标（-1..1 为贴花框）----
    float2 d = uv - u.center;
    float c = cos(u.rot), s = sin(u.rot);
    float2 e = float2(c * d.x + s * d.y, -s * d.x + c * d.y);
    float2 n = e / u.halfSize;
    float m = max(fabs(n.x), fabs(n.y));

    float aa = max(FW(n.x), FW(n.y));
    float cov = (1.0 - smoothstep(1.0 - aa, 1.0 + aa, m)) * planeFade;

    // ---- 接触阴影：贴花外侧一圈极窄的暗带 ----
    float wN = u.contactPx * aa;
    float dd = m - 1.0;
    float ring = (1.0 - smoothstep(0.0, max(wN, 1e-6), dd)) * smoothstep(-aa * 2.0, aa, dd);
    base *= 1.0 - u.contact * ring * occ;   // 被前景挡住的地方不该有接触阴影

    // ---- 贴花 + 表面融合 ----
    float4 dt = dtex.sample(smp, clamp(n * 0.5 + 0.5, 0.0, 1.0));
    // CoreGraphics 解码出来的位图是预乘 alpha 的，还原成直通再算
    if (dt.a > 0.002) dt.rgb /= dt.a;

    float a = dt.a * cov;
    if (a > 0.002) {
        float kk = mix(1.0, clamp(surf / max(u.anchor, 0.02), 0.25, 2.5), u.shade);
        float L  = dot(dt.rgb, LUMA);

        // ---- 光照层：印刷品在明暗两端都会掉饱和 ----
        // 亮处过曝趋于白，暗处被环境散射光冲淡趋于灰。
        // cs = min(kk, 1/kk) 是「离中性有多远」，对两端对称，只降不升。
        // 旧版 pow(kk, 0.42) 在 kk<1 时反而抬饱和（0.5^0.42 = 0.75 > 0.5），
        // 暗部贴花的颜色比源图还纯，跟物理相反 —— 这是换掉它的原因，不是调参。
        float cs = min(kk, 1.0 / max(kk, 1e-3));
        float chromaGain = pow(cs, 0.4 * u.shade);

        float3 paint = float3(L * kk) + (dt.rgb - float3(L)) * chromaGain;

        // ---- 阴影混环境色 ----
        // 只降饱和会变灰发脏（污渍感）。阴影里真实发生的是周围表面的散射光渗进来，
        // 所以往当前表面的颜色 base 上靠，而不是往灰上靠。
        float haze = clamp(1.0 - kk, 0.0, 1.0) * 0.35 * u.shade;
        paint = mix(paint, base, haze);

        base = mix(base, clamp(paint, 0.0, 1.0), a);
    }

    return float4(base, 1.0);
}
