// 真机以外的最近一档验证：headless Chrome 里跑 decal.html，用真实照片驱动，
// 读回导出的 JPEG 落盘，肉眼 + 数值双验。
const http = require('http'), { spawn } = require('child_process'), fs = require('fs');
const CHROME = 'C:\\Users\\93044\\AppData\\Local\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9366, BASE = 'http://127.0.0.1:8801', OUT = 'D:\\wbtmp\\ios_decal\\test';
const getJSON = p => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(JSON.parse(b)));
  }).on('error', rej);
});

(async () => {
  const child = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`, '--headless=new', '--window-size=430,932',
    '--no-first-run', '--no-default-browser-check', '--enable-unsafe-swiftshader',
    '--user-data-dir=D:\\wbtmp\\ios_decal\\cdp_' + Date.now(), 'about:blank',
  ], { stdio: 'ignore' });

  let tabs;
  for (let i = 0; i < 50; i++) { try { tabs = await getJSON('/json'); break; } catch (e) { await new Promise(r => setTimeout(r, 250)); } }
  const ws = new WebSocket(tabs.find(x => x.type === 'page').webSocketDebuggerUrl);
  let id = 0; const pend = new Map();
  const send = (m, p = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
  const logs = [];
  ws.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result); pend.delete(m.id); return; }
    if (m.method === 'Runtime.exceptionThrown') logs.push('EXC ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error')
      logs.push('ERR ' + m.params.args.map(a => a.value ?? a.description).join(' '));
  };
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
    fs.writeFileSync(`${OUT}\\ui_${n}.png`, Buffer.from(r.data, 'base64'));
  };
  const saveDataURL = (name, url) => {
    const b64 = url.split(',')[1];
    fs.writeFileSync(`${OUT}\\${name}`, Buffer.from(b64, 'base64'));
    return Math.round(Buffer.from(b64, 'base64').length / 1024);
  };

  await send('Page.navigate', { url: BASE + '/Decal/decal.html' });
  let ready = false;
  for (let i = 0; i < 80; i++) { if (await ev('window.__ready===true')) { ready = true; break; } await wait(200); }
  console.log('ready =', ready);
  console.log('webgl2 =', await ev(`(function(){try{const c=document.createElement('canvas');return !!c.getContext('webgl2');}catch(e){return 'ex:'+e.message}})()`));
  await wait(600);

  // ---- 场景：建筑墙面（真透视）。四角是照片里那面墙的角 ----
  const CASES = [
    { tag: 'building', img: '/test/building.png', corners: [[150, 205], [700, 150], [745, 520], [95, 560]], decal: { center: [0.5, 0.5], hu: 0.34, rot: -3 } },
    { tag: 'bottle',   img: '/test/bottle.png',   corners: [[70, 120], [415, 130], [420, 620], [60, 610]], decal: { center: [0.42, 0.62], hu: 0.30, rot: 2 } },
    { tag: 'face',     img: '/test/face.png',     corners: [[90, 240], [560, 250], [575, 900], [75, 890]], decal: { center: [0.50, 0.42], hu: 0.26, rot: 0 } },
  ];

  for (const cs of CASES) {
    const dim = await ev(`window.__dbg.load(${JSON.stringify(BASE + cs.img)})`);
    await wait(500);
    await ev(`window.__dbg.corners(${JSON.stringify(cs.corners)})`);
    await wait(200);
    await ev(`window.__dbg.decal(${JSON.stringify(cs.decal)})`);
    await wait(350);
    const st = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
    await shot(cs.tag);

    // 换方格贴图，看方格是否接近正方形（这是判定"有没有变形"的直接证据）
    await ev('window.__dbg.grid()');
    await wait(250);
    await shot(cs.tag + '_grid');

    // 导出全分辨率
    const url = await ev('window.__dbg.export(0.95)');
    const kb = saveDataURL(cs.tag + '_out.jpg', url);
    console.log(`  ${cs.tag.padEnd(9)} 图像 ${dim[0]}x${dim[1]}  k=${st.k.toFixed(3)} half=[${st.half.map(v => v.toFixed(3))}] anchor=${st.anchor.toFixed(3)} 导出 ${kb}KB`);

    // 恢复默认贴图
    await ev(`(function(){var c=document.createElement('canvas');c.width=1024;c.height=340;var x=c.getContext('2d');x.fillStyle='rgba(13,150,175,0.96)';x.fillRect(0,0,1024,340);x.fillStyle='#fff';x.font='700 152px sans-serif';x.textAlign='center';x.textBaseline='middle';x.fillText('MAX',512,178);document.getElementById('fDecal')._canvas=c;window.__dbg.grid&&0;})()`);
  }

  // ---- 退化输入：三点共线必须不崩 ----
  const degen = await ev(`(function(){
    window.__dbg.corners([[0,0],[400,0],[800,0],[1200,0]]);
    return JSON.stringify(window.__dbg.state().half);
  })()`);
  console.log('退化四点 half =', degen, '（不崩即可）');

  // ---- 导出耗时（1200 万像素级别的基线） ----
  const t = await ev(`(async function(){
    window.__dbg.corners([[150,205],[700,150],[745,520],[95,560]]);
    const t0=performance.now(); await window.__dbg.export(0.92);
    return Math.round(performance.now()-t0);
  })()`);
  console.log('单次导出（含 readPixels + JPEG 编码）=', t, 'ms');

  console.log(logs.length ? logs.join('\n') : '--- 0 异常 ---');
  ws.close(); child.kill(); process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
