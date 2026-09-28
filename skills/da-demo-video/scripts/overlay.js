// 画面の上に重ねる演出（カーソル・ハイライト・テロップ・ズーム・タイトルカード）
// Shadow DOM に閉じ込める。撮る側のページが `div { ... }` のような要素セレクタを持つと、
// 素の div で作った演出にも効いて、カードが半透明になったり枠がずれたりする（実際に起きた）。
(() => {
  if (window.__ov) return;
  const css = `
  #ov-root{position:fixed;inset:0;pointer-events:none;font-family:"Hiragino Sans","Noto Sans JP",sans-serif}
  #ov-cursor{position:absolute;left:0;top:0;width:28px;height:28px;transition:transform .55s cubic-bezier(.4,.1,.2,1);filter:drop-shadow(0 2px 3px rgba(0,0,0,.35))}
  .ov-ripple{position:absolute;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;border:3px solid #ff4d4f;animation:ovr .6s ease-out forwards}
  @keyframes ovr{from{transform:scale(.3);opacity:1}to{transform:scale(1.4);opacity:0}}
  #ov-hl{position:absolute;border:3px solid #ff4d4f;border-radius:10px;box-shadow:0 0 0 9999px rgba(15,23,42,.38),0 0 18px rgba(255,77,79,.7);opacity:0;transition:all .45s ease}
  #ov-cap{position:absolute;left:50%;bottom:44px;transform:translate(-50%,20px);max-width:88%;padding:14px 30px;border-radius:14px;background:rgba(15,23,42,.9);color:#fff;font-size:26px;font-weight:700;letter-spacing:.02em;opacity:0;transition:all .4s ease;white-space:nowrap}
  #ov-cap.on{opacity:1;transform:translate(-50%,0)}
  #ov-card{position:absolute;inset:0;background:linear-gradient(135deg,#0f1b3d,#1d3a8a);color:#fff;display:flex;flex-direction:column;justify-content:center;padding:0 110px;opacity:0;transition:opacity .6s ease}
  #ov-card.on{opacity:1}
  #ov-card h1{font-size:54px;margin:0 0 22px;line-height:1.35}
  #ov-card .sub{font-size:28px;opacity:.85;line-height:1.6}
  #ov-card .tag{display:inline-block;font-size:20px;padding:6px 16px;border:1px solid rgba(255,255,255,.5);border-radius:999px;margin-bottom:28px;opacity:.9}
  #ov-card .cols{display:flex;gap:40px;margin-top:10px}
  #ov-card .col{flex:1;border-radius:18px;padding:30px 36px;background:rgba(255,255,255,.08);font-size:26px;line-height:1.9;opacity:0;transform:translateY(16px);transition:all .6s ease}
  #ov-card .col.on{opacity:1;transform:none}
  #ov-card .col h2{font-size:30px;margin:0 0 12px}
  #ov-card .after{background:rgba(255,255,255,.16);outline:3px solid #7dd3fc}
  #ov-card li{margin-left:1em}
  `;
  const host = document.createElement('ov-host'); // 独自タグなので、ページの div セレクタに当たらない
  host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;display:block';
  const shadow = host.attachShadow({ mode: 'open' });
  const st = document.createElement('style'); st.textContent = css; shadow.appendChild(st);
  const root = document.createElement('div'); root.id = 'ov-root';
  root.innerHTML = `<div id="ov-card"></div><div id="ov-hl"></div><div id="ov-cap"></div>
  <svg id="ov-cursor" viewBox="0 0 24 24"><path d="M4 2l16 9.5-7 1.6 4.2 7.4-2.8 1.5-4.2-7.4L5 19.5z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
  shadow.appendChild(root);
  document.documentElement.appendChild(host);
  const $ = (id) => root.querySelector('#' + id);
  let cx = 720, cy = 450;
  $('ov-cursor').style.transform = `translate(${cx}px,${cy}px)`;
  window.__ov = {
    cursorTo(x, y, ms = 550) { const c = $('ov-cursor'); c.style.transitionDuration = ms + 'ms'; c.style.transform = `translate(${x - 4}px,${y - 2}px)`; cx = x; cy = y; },
    ripple() { const r = document.createElement('div'); r.className = 'ov-ripple'; r.style.left = cx + 'px'; r.style.top = cy + 'px'; root.appendChild(r); setTimeout(() => r.remove(), 700); },
    hl(r, pad = 8) { const h = $('ov-hl'); Object.assign(h.style, { left: r.x - pad + 'px', top: r.y - pad + 'px', width: r.width + pad * 2 + 'px', height: r.height + pad * 2 + 'px', opacity: 1 }); },
    hlOff() { $('ov-hl').style.opacity = 0; },
    cap(t) { const c = $('ov-cap'); if (!t) { c.classList.remove('on'); return; } c.textContent = t; c.classList.add('on'); },
    card(html) { const c = $('ov-card'); c.innerHTML = html; c.classList.add('on'); },
    cardShowCols() { root.querySelectorAll('.col').forEach((e, i) => setTimeout(() => e.classList.add('on'), i * 900)); },
    cardOff() { $('ov-card').classList.remove('on'); },
    zoom(r, s) {
      const b = document.body; b.style.transition = 'transform .7s cubic-bezier(.4,.1,.2,1)'; b.style.transformOrigin = `${scrollX}px ${scrollY}px`;
      const tx = innerWidth / 2 - (r.x + r.width / 2) * s, ty = innerHeight / 2 - (r.y + r.height / 2) * s;
      b.style.transform = `translate(${Math.min(0, Math.max(innerWidth - innerWidth * s, tx))}px,${Math.min(0, Math.max(innerHeight - innerHeight * s, ty))}px) scale(${s})`;
    },
    unzoom() { document.body.style.transform = ''; },
  };
})();
