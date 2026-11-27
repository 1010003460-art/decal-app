// 真机以外的交互验证：用真实指针事件拖四个角、拖贴花、点保存。
// 只信"输入事件 → 状态变化"，不看代码。
const http = require('http'), { spawn } = require('child_process'), fs = require('fs');
const CHROME = 'C:\\Users\\93044\\AppData\\Local\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9368, BASE = 'http://127.0.0.1:8801', OUT = 'D:\\wbtmp\\ios_decal\\test';
const getJSON = p => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(JSON.parse(b)));
  }).on('error', rej);
});

(async () => {
  const child = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`, '--headless=new', '--window-size=430,932',
    '--no-first-run', '--enable-unsafe-swiftshader',
    `--user-data-dir=D:\\wbtmp\\ios_decal\\cdp_${Date.now()}`, 'about:blank',
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
    fs.writeFileSync(`${OUT}\\drag_${n}.png`, Buffer.from(r.data, 'base64'));
  };
  const mouse = (type, x, y, buttons) => send('Input.dispatchMouseEvent', {
    type, x, y, button: 'left', buttons, clickCount: type === 'mouseMoved' ? 0 : 1,
    pointerType: 'mouse',
  });

  await send('Page.navigate', { url: BASE + '/Decal/decal.html' });
  for (let i = 0; i < 80; i++) { if (await ev('window.__ready===true')) break; await wait(200); }
  await wait(400);

  await ev(`window.__dbg.load(${JSON.stringify(BASE + '/test/building.png')})`);
  await wait(600);
  await shot('0_loaded');

  const rect = JSON.parse(await ev(`JSON.stringify((function(){const r=document.getElementById('ui').getBoundingClientRect();return {l:r.left,t:r.top,w:r.width,h:r.height};})())`));
  const st0 = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
  const toScreen = p => [p[0] * st0.k + (st0.W * 0 + 0) + 0, 0]; // 占位，真正换算在下面
  // 图像像素 → 视口 CSS 坐标（页面自己算 offset，这里读出来用）
  const view = JSON.parse(await ev(`JSON.stringify((function(){
    const r=document.getElementById('ui').getBoundingClientRect();
    const s=window.__dbg.state();
    return {l:r.left,t:r.top,w:r.width,h:r.height,k:s.k};
  })())`));
  const imgToView = p => {
    // ox,oy = (画布尺寸 - 图像*k)/2
    const ox = (view.w - st0.W * view.k) / 2, oy = (view.h - st0.H * view.k) / 2;
    return [view.l + p[0] * view.k + ox, view.t + p[1] * view.k + oy];
  };

  // ---------- 1. 拖第一个角（TL） ----------
  const c0 = st0.corners[0];
  const from = imgToView(c0);
  const target = [c0[0] + 120, c0[1] + 60];
  const to = imgToView(target);
  await mouse('mousePressed', from[0], from[1], 1);
  for (let s = 1; s <= 12; s++) {
    await mouse('mouseMoved', from[0] + (to[0] - from[0]) * s / 12, from[1] + (to[1] - from[1]) * s / 12, 1);
    await wait(16);
  }
  await mouse('mouseReleased', to[0], to[1], 0);
  await wait(200);
  const st1 = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
  const moved = Math.hypot(st1.corners[0][0] - c0[0], st1.corners[0][1] - c0[1]);
  const wantMoved = Math.hypot(target[0] - c0[0], target[1] - c0[1]);
  console.log(`1) 拖左上角：期望移动 ${wantMoved.toFixed(1)}px，实际 ${moved.toFixed(1)}px，其余角是否未动 = ${JSON.stringify(st1.corners.slice(1)) === JSON.stringify(st0.corners.slice(1))}`);
  await shot('1_corner');

  // ---------- 2. 切到贴花模式，拖贴花 ----------
  await ev(`document.getElementById('bDecalMode').click()`);
  await wait(200);
  const st2 = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
  const ivToScreen = uv => {
    // uv → 图像像素 通过页面内部 H（借用 export 时同一条链路：直接用 decalQuadScreen 的思路）
    // 这里简化：贴花中心在 uv=(0.5,0.5)，取它此刻在屏幕上的位置由页面提供
    return null;
  };
  const centerScreen = JSON.parse(await ev(`JSON.stringify((function(){
    const s = window.__dbg.state();
    // 用四点做双线性近似求 uv=(cx,cy) 的屏幕位置
    const q = s.corners; // TL,TR,BR,BL
    const cx = s.center.x, cy = s.center.y;
    const top = [q[0][0]+(q[1][0]-q[0][0])*cx, q[0][1]+(q[1][1]-q[0][1])*cx];
    const bot = [q[3][0]+(q[2][0]-q[3][0])*cx, q[3][1]+(q[2][1]-q[3][1])*cx];
    return [top[0]+(bot[0]-top[0])*cy, top[1]+(bot[1]-top[1])*cy];
  })())`));
  const cs = imgToView(centerScreen);
  await mouse('mousePressed', cs[0], cs[1], 1);
  for (let s = 1; s <= 10; s++) {
    await mouse('mouseMoved', cs[0] + s * 6, cs[1] + s * 3, 1);
    await wait(16);
  }
  await mouse('mouseReleased', cs[0] + 60, cs[1] + 30, 0);
  await wait(200);
  const st3 = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
  const dUv = [st3.center.x - st2.center.x, st3.center.y - st2.center.y];
  console.log(`2) 拖贴花（屏幕 +60,+30）：uv 变化 = [${dUv.map(v => v.toFixed(4))}]，方向是否一致 = ${dUv[0] > 0 && dUv[1] > 0}`);
  await shot('2_decal');

  // ---------- 3. 贴花模式点空白处不应移动 ----------
  await mouse('mousePressed', view.l + 8, view.t + 8, 1);
  await mouse('mouseMoved', view.l + 40, view.t + 40, 1);
  await mouse('mouseReleased', view.l + 40, view.t + 40, 0);
  await wait(150);
  const st4 = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
  console.log(`3) 贴花模式点画布空白：贴花是否不动 = ${Math.hypot(st4.center.x - st3.center.x, st4.center.y - st3.center.y) < 1e-6}`);

  // ---------- 4. 点保存（无原生桥时会走下载分支，只验不崩 + 有提示） ----------
  await ev(`document.getElementById('bSave').click()`);
  await wait(1500);
  const toast = await ev(`document.getElementById('toast').textContent`);
  const shown = await ev(`document.getElementById('toast').classList.contains('show')`);
  console.log(`4) 保存按钮：toast = "${toast}"（显示中=${shown}）`);
  await shot('3_saved');

  // ---------- 5. 滑杆 ----------
  await ev(`(function(){const r=document.getElementById('rSize');r.value=60;r.dispatchEvent(new Event('input'));})()`);
  await wait(150);
  const st5 = JSON.parse(await ev('JSON.stringify(window.__dbg.state())'));
  console.log(`5) 大小滑杆 30→60：hu 实际 ${st5.half[0].toFixed(3)}（应约 0.30，被上限 0.46 夹住则另说）`);
  await shot('4_size');

  console.log(logs.length ? logs.join('\n') : '--- 0 异常 ---');
  ws.close(); child.kill(); process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
