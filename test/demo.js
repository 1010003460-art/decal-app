// 演示出图：把贴花放到照片里真实存在的平面上
const http = require('http'), { spawn } = require('child_process'), fs = require('fs'), os = require('os'), path = require('path');
const CHROME = 'C:\\Users\\93044\\AppData\\Local\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9369, BASE = 'http://127.0.0.1:8801', OUT = __dirname;
const getJSON = p => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(JSON.parse(b)));
  }).on('error', rej);
});
// 酒标正面（照片里量出来的四角，TL TR BR BL）
const CASES = [
  // 默认贴花（青色 MAX 卡片）先跑，避免被后面的方格贴图替换
  { tag: 'final_on',    img: 'bottle.png', corners: [[192,264],[299,261],[301,492],[190,491]], decal: { center: [0.5, 0.55], hu: 0.34, rot: -1, shade: 0.75, contact: 0.5 } },
  { tag: 'final_grid',  img: 'bottle.png', corners: [[192,264],[299,261],[301,492],[190,491]], decal: { center: [0.5, 0.55], hu: 0.34, rot: -1, shade: 0.75, contact: 0.5 }, grid: true },
  { tag: 'final_zero',  img: 'bottle.png', corners: [[192,264],[299,261],[301,492],[190,491]], decal: { center: [0.5, 0.55], hu: 0.34, rot: -1, shade: 0,    contact: 0 }, grid: true },
];
// 同一位置：不融合 / 融合，用于对比
const SHADE = [
  { tag: 'demo_noshade', img: 'bottle.png', corners: [[192, 264], [299, 261], [301, 492], [190, 491]], decal: { center: [0.5, 0.5], hu: 0.42, rot: -1, shade: 0, contact: 0 } },
];

(async () => {
  const child = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`, '--headless=new', '--window-size=430,932',
    '--no-first-run', '--enable-unsafe-swiftshader',
    `--user-data-dir=${path.join(os.tmpdir(), 'cdp_' + Date.now())}`, 'about:blank',
  ], { stdio: 'ignore' });
  let tabs;
  for (let i = 0; i < 50; i++) { try { tabs = await getJSON('/json'); break; } catch (e) { await new Promise(r => setTimeout(r, 250)); } }
  const ws = new WebSocket(tabs.find(x => x.type === 'page').webSocketDebuggerUrl);
  let id = 0; const pend = new Map();
  const send = (m, p = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
  ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result); pend.delete(m.id); } };
  await new Promise(r => ws.onopen = r);
  await send('Page.enable'); await send('Runtime.enable');
  const ev = async x => {
    const r = await send('Runtime.evaluate', { expression: x, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'eval fail');
    return r.result?.value;
  };
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const shot = async n => {
    const r = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(`${OUT}\\${n}.png`, Buffer.from(r.data, 'base64'));
  };

  await send('Page.navigate', { url: BASE + '/Decal/decal.html' });
  for (let i = 0; i < 80; i++) { if (await ev('window.__ready===true')) break; await wait(200); }
  await wait(500);

  for (const c of CASES) {
    await ev(`window.__dbg.load(${JSON.stringify(BASE + '/test/' + c.img)})`);
    await wait(400);
    await ev(`window.__dbg.corners(${JSON.stringify(c.corners)})`);
    await ev(`window.__dbg.decal(${JSON.stringify(c.decal)})`);
    if (c.grid) await ev(`window.__dbg.setDecalURL(${JSON.stringify(BASE + '/test/grid.png')})`);
    await wait(300);
    await shot(c.tag + '_ui');
    const url = await ev(`window.__dbg.export(0.95)`);
    fs.writeFileSync(`${OUT}\\${c.tag}_out.jpg`, Buffer.from(url.split(',')[1], 'base64'));
    console.log(c.tag, 'ok');
    if (c.grid) await ev(`window.__dbg.setDecalURL(${JSON.stringify(BASE + '/test/decal.png')})`);
  }
  ws.close(); child.kill(); process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
