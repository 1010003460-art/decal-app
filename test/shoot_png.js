// 独立基准：用 numpy 的最小二乘 DLT 解单应（与页面里的 8×8 高斯消元是两套算法），
// 自己做逆采样 + 双线性，合成一张参考图；再和页面导出的 PNG 逐像素比。
// 一致 ⇒ 着色器的坐标、y 方向、uv 顺序、宽高比修正都是对的。

const http = require('http'), { spawn } = require('child_process'), fs = require('fs');
const CHROME = 'C:\\Users\\93044\\AppData\\Local\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9367, BASE = 'http://127.0.0.1:8801', OUT = 'D:\\wbtmp\\ios_decal\\test';
const getJSON = p => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(JSON.parse(b)));
  }).on('error', rej);
});

const CASES = [
  { tag: 'chk_building', img: 'building.png', corners: [[150, 205], [700, 150], [745, 520], [95, 560]], decal: { center: [0.5, 0.5], hu: 0.34, rot: -3 } },
  { tag: 'chk_bottle',   img: 'bottle.png',   corners: [[70, 120], [415, 130], [420, 620], [60, 610]],  decal: { center: [0.42, 0.62], hu: 0.30, rot: 2 } },
  { tag: 'chk_face',     img: 'face.png',     corners: [[90, 240], [560, 250], [575, 900], [75, 890]],  decal: { center: [0.50, 0.42], hu: 0.26, rot: 0 } },
];

(async () => {
  const child = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`, '--headless=new', '--window-size=430,932',
    '--no-first-run', '--enable-unsafe-swiftshader',
    '--user-data-dir=D:\\wbtmp\\ios_decal\\cdp_' + Date.now(), 'about:blank',
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

  await send('Page.navigate', { url: BASE + '/Decal/decal.html' });
  for (let i = 0; i < 80; i++) { if (await ev('window.__ready===true')) break; await wait(200); }
  await wait(500);

  for (const cs of CASES) {
    await ev(`window.__dbg.load(${JSON.stringify(BASE + '/test/' + cs.img)})`);
    await wait(400);
    await ev(`window.__dbg.corners(${JSON.stringify(cs.corners)})`);
    await ev(`window.__dbg.decal(${JSON.stringify({ ...cs.decal, shade: 0, contact: 0 })})`);
    await ev(`window.__dbg.setDecalURL(${JSON.stringify(BASE + '/test/grid.png')})`);
    await wait(250);
    const url = await ev(`window.__dbg.export('png')`);
    fs.writeFileSync(`${OUT}\\${cs.tag}.png`, Buffer.from(url.split(',')[1], 'base64'));
    const st = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
    fs.writeFileSync(`${OUT}\\${cs.tag}.json`, JSON.stringify({
      corners: cs.corners, center: st.center, half: st.half, rot: cs.decal.rot, img: cs.img,
    }));
    console.log(`${cs.tag}  half=[${st.half.map(v => v.toFixed(4))}]`);
  }
  ws.close(); child.kill(); process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
