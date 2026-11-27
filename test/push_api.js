// github.com:443 当前不通（api 正常），走 Git Data API 直接落一个提交。
// 不打印令牌；所有请求都带 Authorization。
const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const REPO = '1010003460-art/decal-app';
const ROOT = path.resolve(__dirname, '..');

const TOK = execSync(
  `printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill`,
  { encoding: 'utf8', shell: 'C:\\Program Files\\Git\\bin\\bash.exe' }
).split('\n').find(l => l.startsWith('password=')).slice(9).trim();

function api(method, p, body) {
  return new Promise((res, rej) => {
    const data = body ? JSON.stringify(body) : null;
    const req = https.request({
      host: 'api.github.com', path: p, method,
      headers: {
        Authorization: `Bearer ${TOK}`,
        'User-Agent': 'decal-ci',
        Accept: 'application/vnd.github+json',
        ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}),
      },
    }, r => {
      let b = '';
      r.on('data', d => b += d);
      r.on('end', () => {
        let j = null;
        try { j = JSON.parse(b); } catch (_) {}
        if (r.statusCode >= 400) rej(new Error(`${method} ${p} -> ${r.statusCode} ${b.slice(0, 300)}`));
        else res(j);
      });
    });
    req.on('error', rej);
    if (data) req.write(data);
    req.end();
  });
}

const ARGV = process.argv.slice(2);
const MODIFIED = ARGV.length ? ARGV : ['.gitignore', 'Decal/ContentView.swift', 'Decal/DecalApp.swift', 'README.md', 'project.yml'];
const ADDED = ARGV.length ? [] : ['Decal/decal.html', 'test/drag.js', 'test/ref_check.py', 'test/run.js', 'test/shoot_png.js', 'diag/repro_overlay.py'];
const DELETED = ARGV.length ? [] : ['Decal/Homography.swift', 'Decal/Perspective.swift', 'Decal/PhotoPicker.swift', 'Decal/RectDetector.swift'];

const MSG = process.env.CI_MSG || (ARGV.length ? `fix: 表面融合改用原像素亮度（模糊版把纹理抹平，看着像没生效）

- 着色器不再采样低频模糊图，直接用该像素亮度；省掉一张纹理和一次采样
- 三档实测：贴花区域平均亮度 0.479(0%) / 0.427(75%) / 0.409(100%)` : `feat: 换成四点单应的 WebGL 着色器渲染（WKWebView 外壳）

- 新增 Decal/decal.html：全屏着色器做逐像素逆采样，四点单应精确贴合平面
  · 只覆盖贴花自身像素，原图其余部分不再被重采样
  · 表面融合（低频亮度）+ 接触阴影，默认 75% / 50%
  · 导出走离屏缓冲，4096 上限，单张约 21ms
- ContentView 改为 WKWebView + 存相册桥，删掉 Vision/CoreImage 那套 CPU 管线
- 与 numpy SVD-DLT 独立实现逐像素比对：内部区域最大差 0.49/255
- 真实指针拖拽验证：拖角 134.2 期望 / 134.0 实际`);

(async () => {
  const ref = await api('GET', `/repos/${REPO}/git/ref/heads/main`);
  const baseSha = ref.object.sha;
  const baseCommit = await api('GET', `/repos/${REPO}/git/commits/${baseSha}`);
  console.log('base =', baseSha.slice(0, 7));

  const tree = [];
  for (const f of [...MODIFIED, ...ADDED]) {
    const full = path.join(ROOT, f.replace(/\//g, '\\'));
    const buf = fs.readFileSync(full);
    const blob = await api('POST', `/repos/${REPO}/git/blobs`, {
      content: buf.toString('base64'), encoding: 'base64',
    });
    tree.push({ path: f, mode: '100644', type: 'blob', sha: blob.sha });
    console.log(`  blob ${f}  ${buf.length}B`);
  }
  for (const f of DELETED) {
    tree.push({ path: f, mode: '100644', type: 'blob', sha: null });
    console.log(`  del  ${f}`);
  }

  const newTree = await api('POST', `/repos/${REPO}/git/trees`, {
    base_tree: baseCommit.tree.sha, tree,
  });
  console.log('tree =', newTree.sha.slice(0, 7));

  const commit = await api('POST', `/repos/${REPO}/git/commits`, {
    message: MSG, tree: newTree.sha, parents: [baseSha],
  });
  console.log('commit =', commit.sha.slice(0, 7));

  await api('PATCH', `/repos/${REPO}/git/refs/heads/main`, { sha: commit.sha, force: false });
  console.log('main 已更新 ->', commit.sha);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
