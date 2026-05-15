// console-launcher.js — Quick-connect panel injected into SSHwifty
// Automates the 5-click connect flow into a single button press.
// Injected into SSHwifty's HTML by console-proxy.js.
(function () {
  'use strict';

  const PRESETS = [
    { group: 'WSL',         sub: 'Persistent', title: 'WSL Terminal (Persistent)' },
    { group: 'WSL',         sub: 'Fresh',      title: 'WSL Shell (Fresh)'         },
    { group: 'Candystore',  sub: 'Persistent', title: 'Candystore (Persistent)'   },
    { group: 'Candystore',  sub: 'Fresh',      title: 'Candystore (Fresh)'        },
    { group: 'Eclipse-con', sub: 'Persistent', title: 'Eclipse-con (Persistent)'  },
    { group: 'Eclipse-con', sub: 'Fresh',      title: 'Eclipse-con (Fresh)'       },
  ];

  const GROUP_COLORS = {
    'WSL':         '#4caf82',
    'Candystore':  '#c47f3a',
    'Eclipse-con': '#7b6fcf',
  };

  function sleep(ms) {
    return new Promise(r => setTimeout(r, ms));
  }

  function waitFor(selector, timeout) {
    timeout = timeout || 5000;
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function check() {
        var el = document.querySelector(selector);
        if (el) return resolve(el);
        if (Date.now() - start > timeout) return reject(new Error('Timeout: ' + selector));
        setTimeout(check, 80);
      })();
    });
  }

  // Automate: open dialog → Known remotes tab → click preset → Connect → Login
  async function connectPreset(title) {
    const plusBtn = await waitFor('#home-hd-plus', 10000);

    const connectEl = document.querySelector('#connect');
    const isHidden = !connectEl || getComputedStyle(connectEl).display === 'none';
    if (isHidden) {
      plusBtn.click();
      await sleep(400);
    }

    const connectSwitch = await waitFor('#connect-switch', 4000);
    let knownTab = null;
    for (const li of connectSwitch.querySelectorAll('li')) {
      if (li.textContent.includes('Known remotes')) { knownTab = li; break; }
    }
    if (!knownTab) throw new Error('"Known remotes" tab not found');

    if (!knownTab.classList.contains('active')) {
      knownTab.click();
      await sleep(300);
    }

    const presetContainer = await waitFor('#connect-known-list-presets', 4000);
    let found = false;
    for (const wrap of presetContainer.querySelectorAll('.lst-wrap')) {
      const h4 = wrap.querySelector('h4');
      if (h4 && h4.textContent.trim() === title) {
        wrap.click();
        found = true;
        break;
      }
    }
    if (!found) throw new Error('Preset "' + title + '" not found');

    await new Promise(function (resolve, reject) {
      var start = Date.now();
      (function check() {
        var form = document.querySelector('#connector');
        if (form) {
          var submitBtn = form.querySelector('[type=submit]');
          if (submitBtn && !submitBtn.disabled) { submitBtn.click(); return resolve(); }
        }
        if (Date.now() - start > 5000) return reject(new Error('Connector form not ready'));
        setTimeout(check, 80);
      })();
    });

    await new Promise(function (resolve, reject) {
      var start = Date.now();
      (function check() {
        var loginBtn = Array.from(document.querySelectorAll('button'))
          .find(function(b) { return b.textContent.trim() === 'Login' && !b.disabled; });
        if (loginBtn) { loginBtn.click(); return resolve(); }
        if (Date.now() - start > 5000) return reject(new Error('Login button not found'));
        setTimeout(check, 80);
      })();
    });
  }

  function buildPanel() {
    if (document.getElementById('ql-fab')) return;

    const popup = document.createElement('div');
    popup.id = 'ql-popup';
    popup.style.cssText = [
      'position:fixed',
      'top:40px',
      'left:0',
      'z-index:9998',
      'background:rgba(16,18,28,0.95)',
      'border:1px solid rgba(120,140,200,0.35)',
      'border-radius:0 0 10px 10px',
      'padding:10px 12px 12px',
      'font:11px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",monospace',
      'color:#bbc',
      'box-shadow:0 8px 32px rgba(0,0,0,0.6)',
      'min-width:160px',
      'user-select:none',
      'backdrop-filter:blur(6px)',
      'display:none',
    ].join(';');

    const popupTitle = document.createElement('div');
    popupTitle.textContent = 'QUICK CONNECT';
    popupTitle.style.cssText = [
      'font-size:9px',
      'font-weight:700',
      'letter-spacing:.1em',
      'color:#8899bb',
      'margin-bottom:8px',
      'padding-bottom:6px',
      'border-bottom:1px solid rgba(120,140,200,0.25)',
    ].join(';');
    popup.appendChild(popupTitle);

    const groups = {};
    PRESETS.forEach(p => {
      if (!groups[p.group]) groups[p.group] = [];
      groups[p.group].push(p);
    });

    for (const [groupName, items] of Object.entries(groups)) {
      const groupEl = document.createElement('div');
      groupEl.style.marginBottom = '6px';

      const label = document.createElement('div');
      label.textContent = groupName;
      label.style.cssText = [
        'font-size:9px',
        'font-weight:700',
        'letter-spacing:.07em',
        'text-transform:uppercase',
        'margin-bottom:3px',
        'color:' + (GROUP_COLORS[groupName] || '#aab'),
      ].join(';');
      groupEl.appendChild(label);

      const row = document.createElement('div');
      row.style.cssText = 'display:flex;gap:4px';

      items.forEach(preset => {
        const isPersist = preset.sub === 'Persistent';
        const btn = document.createElement('button');
        btn.textContent = isPersist ? 'Persist' : 'Fresh';
        btn.title = preset.title;
        btn.style.cssText = [
          'flex:1',
          'background:' + (isPersist ? 'rgba(50,90,65,0.45)' : 'rgba(50,60,110,0.45)'),
          'border:1px solid ' + (isPersist ? 'rgba(76,175,130,0.45)' : 'rgba(100,110,200,0.45)'),
          'border-radius:4px',
          'color:' + (isPersist ? '#7dbb99' : '#9099cc'),
          'padding:4px 5px',
          'cursor:pointer',
          'font:10px/1 -apple-system,BlinkMacSystemFont,"Segoe UI",monospace',
          'white-space:nowrap',
          'transition:background .12s,border-color .12s',
        ].join(';');

        const bgHover  = isPersist ? 'rgba(70,130,95,0.65)'  : 'rgba(70,85,150,0.65)';
        const bgNormal = isPersist ? 'rgba(50,90,65,0.45)'   : 'rgba(50,60,110,0.45)';
        btn.addEventListener('mouseenter', () => { btn.style.background = bgHover; });
        btn.addEventListener('mouseleave', () => { btn.style.background = bgNormal; });

        btn.addEventListener('click', async () => {
          closePopup();
          try {
            await connectPreset(preset.title);
          } catch (e) {
            console.error('[launcher]', e);
            alert('Connect failed:\n' + e.message);
          }
        });

        row.appendChild(btn);
      });

      groupEl.appendChild(row);
      popup.appendChild(groupEl);
    }

    document.body.appendChild(popup);

    const logo = document.getElementById('home-hd-title');
    if (!logo) return;

    logo.title = 'Quick Connect';
    logo.style.cursor = 'pointer';
    logo.style.transition = 'opacity .15s';
    logo.addEventListener('mouseenter', () => { logo.style.opacity = '0.7'; });
    logo.addEventListener('mouseleave', () => { logo.style.opacity = '1'; });

    let open = false;

    function openPopup() {
      open = true;
      popup.style.display = 'block';
      logo.style.opacity = '0.5';
    }

    function closePopup() {
      open = false;
      popup.style.display = 'none';
      logo.style.opacity = '1';
    }

    logo.addEventListener('click', e => {
      e.stopPropagation();
      open ? closePopup() : openPopup();
    });

    document.addEventListener('click', e => {
      if (open && !popup.contains(e.target) && e.target !== logo) {
        closePopup();
      }
    });
  }

  (function waitForApp() {
    if (document.getElementById('home-hd-title')) {
      buildPanel();
    } else if (document.body) {
      setTimeout(waitForApp, 200);
    } else {
      document.addEventListener('DOMContentLoaded', waitForApp);
    }
  })();

})();
