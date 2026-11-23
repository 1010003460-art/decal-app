// 在 Windows 上验证 Swift 里那套单应矩阵的数学（Swift 本身编不了，数学可以）
// 算法逐行对应 Decal/Homography.swift，不另写一套
function solve(src, dst) {
  const a = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = src[i], [u, v] = dst[i];
    a[i * 2]     = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
    a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
  }
  for (let col = 0; col < 8; col++) {
    let piv = col;
    for (let r = col + 1; r < 8; r++) if (Math.abs(a[r][col]) > Math.abs(a[piv][col])) piv = r;
    if (Math.abs(a[piv][col]) < 1e-12) return null;
    if (piv !== col) { const t = a[piv]; a[piv] = a[col]; a[col] = t; }
    const d = a[col][col];
    for (let c = col; c <= 8; c++) a[col][c] /= d;
    for (let r = 0; r < 8; r++) {
      if (r === col) continue;
      const f = a[r][col];
      if (f === 0) continue;
      for (let c = col; c <= 8; c++) a[r][c] -= f * a[col][c];
    }
  }
  const h = [];
  for (let i = 0; i < 8; i++) h.push(a[i][8]);
  h.push(1);
  return h;
}

function map(m, p) {
  const [x, y] = p;
  const w = m[6] * x + m[7] * y + m[8];
  if (Math.abs(w) < 1e-12) return null;
  return [(m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w];
}

function inverted(m) {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h, B = f * g - d * i, C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-12) return null;
  return [
     A / det, (c * h - b * i) / det, (b * f - c * e) / det,
     B / det, (a * i - c * g) / det, (c * d - a * f) / det,
     C / det, (b * g - a * h) / det, (a * e - b * d) / det,
  ];
}

const near = (p, q, eps = 1e-6) => Math.abs(p[0] - q[0]) < eps && Math.abs(p[1] - q[1]) < eps;
let fail = 0;
const check = (name, ok, extra = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!ok) fail++;
};

// 1. Swift 里 selfCheck 用的同一组数据
{
  const src = [[0, 0], [100, 0], [0, 60], [100, 60]];
  const dst = [[12, 30], [210, 18], [30, 190], [240, 205]];
  const H = solve(src, dst), Hi = inverted(H);
  let ok = !!H && !!Hi;
  for (let k = 0; k < 4 && ok; k++) {
    const p = map(H, src[k]), q = map(Hi, p);
    ok = near(p, dst[k]) && near(q, src[k]);
  }
  check('往返：解 → 正映射 → 逆映射回到原点', ok);
}

// 2. 恒等：src == dst 应该得到单位矩阵
{
  const s = [[0, 0], [100, 0], [0, 60], [100, 60]];
  const H = solve(s, s);
  check('恒等映射 ≈ 单位矩阵',
    H && Math.abs(H[0] - 1) < 1e-9 && Math.abs(H[4] - 1) < 1e-9 &&
    Math.abs(H[2]) < 1e-9 && Math.abs(H[5]) < 1e-9,
    `h=[${H.map(v => v.toFixed(6)).join(',')}]`);
}

// 3. 真透视（矩形 → 梯形），四个角必须精确命中
{
  const src = [[0, 0], [400, 0], [0, 300], [400, 300]];
  const dst = [[80, 40], [520, 10], [20, 380], [610, 350]];
  const H = solve(src, dst);
  let maxErr = 0;
  for (let k = 0; k < 4; k++) {
    const p = map(H, src[k]);
    maxErr = Math.max(maxErr, Math.abs(p[0] - dst[k][0]), Math.abs(p[1] - dst[k][1]));
  }
  check('矩形→梯形，四角误差 < 1e-9 px', maxErr < 1e-9, `maxErr=${maxErr.toExponential(2)}`);
}

// 4. 中心点应落在目标四边形的凸包内（防止解出翻转/镜像）
{
  const src = [[0, 0], [400, 0], [0, 300], [400, 300]];
  const dst = [[80, 40], [520, 10], [20, 380], [610, 350]];
  const H = solve(src, dst);
  const c = map(H, [200, 150]);
  const xs = dst.map(p => p[0]), ys = dst.map(p => p[1]);
  const inside = c[0] > Math.min(...xs) && c[0] < Math.max(...xs) &&
                 c[1] > Math.min(...ys) && c[1] < Math.max(...ys);
  check('中心点落在目标四边形包围盒内（无翻转）', inside, `c=[${c.map(v => v.toFixed(1))}]`);
}

// 5. 退化输入（三点共线）必须返回 null，而不是给出垃圾矩阵
{
  const H = solve([[0, 0], [10, 0], [20, 0], [30, 0]],
                  [[0, 0], [10, 0], [20, 0], [30, 0]]);
  check('共线四点 → 返回 null', H === null);
}

// 6. 模拟 overlay 的反向采样：把坐标送出去再收回来，误差应 < 0.01 px
{
  const flatQuad = [[40, 60], [700, 25], [10, 500], [740, 470]];  // 展平图四角在原图上的位置
  const fw = 660, fh = 440;
  const H = solve([[0, 0], [fw, 0], [0, fh], [fw, fh]], flatQuad);
  const Hi = inverted(H);
  let maxErr = 0;
  for (let n = 0; n < 200; n++) {
    const x = Math.random() * fw, y = Math.random() * fh;      // 展平图内一点
    const back = map(Hi, map(H, [x, y]));                       // → 原图 → 再回来
    maxErr = Math.max(maxErr, Math.hypot(back[0] - x, back[1] - y));
  }
  check('反采样 200 次随机点，误差 < 0.01 px', maxErr < 0.01, `maxErr=${maxErr.toExponential(2)}`);
}

console.log(fail === 0 ? '\n全部通过' : `\n${fail} 项失败`);
process.exit(fail === 0 ? 0 : 1);
