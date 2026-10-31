/* ============================================================
   Android Nakedcore WebUI
   - 三页布局：主页 / 核心 / 配置
   - 与 nakedcore CLI 通过 JSON + 异步 task 通信
   ============================================================ */
(function () {
  'use strict';

  // ----------------------------------------------------------
  // 常量与工具
  // ----------------------------------------------------------
  var MODULE_PATH_FALLBACK = '/data/adb/modules/Android_Nakedcore';
  var DATA_DIR = '/data/adb/nakedcore';
  var THEME_KEY = 'nc.theme';
  var STATUS_CACHE_KEY = 'nc.status.v3';
  var TASK_POLL_MS = 700;
  var STATUS_POLL_MS = 12000;

  var CORE_META = {
    'sing-box': { name: 'sing-box', icon: 'cube', tagline: '通用代理内核 · 规则与 DNS 一体' },
    mihomo: { name: 'mihomo', icon: 'cat', tagline: 'Clash.Meta 兼容内核 · 面板生态丰富' }
  };

  var CONN_CATEGORIES = [
    ['all', '全部'],
    ['ai', 'AI'],
    ['stream', '流媒体'],
    ['cn', '国内直连'],
    ['community', '社区平台'],
    ['dev', '开发者']
  ];

  var CONN_CATEGORY_LABELS = {
    ai: 'AI',
    stream: '流媒体',
    cn: '国内直连',
    community: '社区平台',
    dev: '开发者'
  };

  var TARGET_META = {
    singbox: { label: 'sing-box', path: DATA_DIR + '/sing-box/config.json', file: 'config.json' },
    mihomo: { label: 'mihomo', path: DATA_DIR + '/mihomo/config.yaml', file: 'config.yaml' },
    substore: { label: 'Sub-Store', path: DATA_DIR + '/sub-store/sub_store.env', file: 'sub_store.env' }
  };

  var UI_META = {
    dashboard: { name: 'Dashboard', core: 'sing-box', rel: 'sing-box/ui/dashboard', icon: 'activity', tone: 'accent' },
    zashboard: { name: 'Zashboard', core: 'mihomo', rel: 'mihomo/ui/zashboard', icon: 'grid', tone: 'mint' }
  };

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function escapeHTML(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function firstLine(value) {
    var s = String(value == null ? '' : value).trim();
    if (!s) return '';
    var line = s.split('\n')[0].trim();
    return line.length > 180 ? line.slice(0, 180) + '…' : line;
  }

  function normVer(value) {
    return String(value == null ? '' : value).trim().replace(/^v/i, '');
  }

  function sameVer(a, b) {
    return !!a && !!b && normVer(a) === normVer(b);
  }

  function verLabel(value) {
    var s = String(value == null ? '' : value).trim();
    if (!s) return '—';
    if (/^v/i.test(s) || /^alpha-/i.test(s)) return s;
    return 'v' + s;
  }

  function channelLabel(channel) {
    return channel === 'alpha' ? '预览版' : '稳定版';
  }

  function humanSize(n) {
    n = Number(n) || 0;
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
    if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
    return n + ' B';
  }

  function fmtElapsed(seconds) {
    seconds = Math.max(0, Number(seconds) || 0);
    if (seconds < 60) return seconds + 's';
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    return m + 'm ' + s + 's';
  }

  function fmtTime(ts) {
    if (!ts) return '';
    var d = new Date(Number(ts) * 1000);
    if (isNaN(d.getTime())) return '';
    return d.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  }

  function shq(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
  }

  function bytesToB64(bytes) {
    var bin = '';
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + chunk, bytes.length)));
    }
    return btoa(bin);
  }

  function textToB64(text) {
    if (window.TextEncoder) return bytesToB64(new TextEncoder().encode(String(text)));
    return btoa(unescape(encodeURIComponent(String(text))));
  }

  function b64ToText(b64) {
    var raw;
    try { raw = atob(String(b64 || '').replace(/\s+/g, '')); }
    catch (e) { return ''; }
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i) & 0xff;
    try { return new TextDecoder('utf-8').decode(bytes); }
    catch (e2) { return raw; }
  }

  function utf8Length(text) {
    if (window.TextEncoder) return new TextEncoder().encode(String(text)).length;
    return unescape(encodeURIComponent(String(text))).length;
  }

  function parseJSON(raw) {
    var s = String(raw == null ? '' : raw).trim();
    try { return JSON.parse(s); } catch (e) { /* fall through */ }
    var a = s.indexOf('{');
    var b = s.lastIndexOf('}');
    if (a >= 0 && b > a) {
      try { return JSON.parse(s.slice(a, b + 1)); } catch (e2) { /* ignore */ }
    }
    throw new Error('无法解析返回数据');
  }

  function copyText(text) {
    var value = String(text == null ? '' : text);
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(value).catch(function () { return fallbackCopy(value); });
    }
    return Promise.resolve(fallbackCopy(value));
  }

  function fallbackCopy(value) {
    try {
      var ta = document.createElement('textarea');
      ta.value = value;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      ta.style.left = '-9999px';
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, ta.value.length);
      document.execCommand('copy');
      document.body.removeChild(ta);
    } catch (e) { /* ignore */ }
  }

  // ----------------------------------------------------------
  // 图标
  // ----------------------------------------------------------
  var ICONS = {
    home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/><path d="M9 21v-6h6v6"/>',
    core: '<path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/><path d="m4 7.5 8 4.5 8-4.5"/><path d="M12 12v9"/>',
    sliders: '<path d="M4 7h9"/><path d="M17 7h3"/><circle cx="15" cy="7" r="2"/><path d="M4 17h3"/><path d="M11 17h9"/><circle cx="9" cy="17" r="2"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.9 4.9 1.4 1.4"/><path d="m17.7 17.7 1.4 1.4"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m4.9 19.1 1.4-1.4"/><path d="m17.7 6.3 1.4-1.4"/>',
    moon: '<path d="M21 12.7A8.5 8.5 0 1 1 11.3 3 7 7 0 0 0 21 12.7z"/>',
    monitor: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8"/><path d="M12 16v4"/>',
    play: '<path d="m8 5 11 7-11 7z"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    restart: '<path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/>',
    switch: '<path d="M7 7h12l-3-3"/><path d="M17 17H5l3 3"/>',
    power: '<path d="M12 2v9"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>',
    copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    external: '<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5"/>',
    chevron: '<path d="m9 18 6-6-6-6"/>',
    down: '<path d="m6 9 6 6 6-6"/>',
    terminal: '<path d="m4 17 6-6-6-6"/><path d="M12 19h8"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/>',
    download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>',
    upload: '<path d="M12 21V9"/><path d="m7 14 5-5 5 5"/><path d="M5 3h14"/>',
    trash: '<path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 15H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/>',
    save: '<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><path d="M7 3v6h8V3"/><path d="M7 21v-8h10v8"/>',
    check: '<path d="m4 12 5 5L20 6"/>',
    x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    alert: '<path d="M12 3 2 21h20z"/><path d="M12 9v5"/><path d="M12 17h.01"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 8h.01"/><path d="M11 12h1v5h1"/>',
    shield: '<path d="M12 3 5 6v6c0 5 3.5 8 7 9 3.5-1 7-4 7-9V6z"/><path d="m9 12 2 2 4-4"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18z"/>',
    plus: '<path d="M12 5v14"/><path d="M5 12h14"/>',
    wifi: '<path d="M5 12.5a10 10 0 0 1 14 0"/><path d="M8.5 16a5.5 5.5 0 0 1 7 0"/><path d="M12 19h.01"/>',
    hotspot: '<circle cx="12" cy="12" r="2"/><path d="M8.5 8.5a5 5 0 0 0 0 7"/><path d="M5 5a10 10 0 0 0 0 14"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M19 5a10 10 0 0 1 0 14"/>',
    radar: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3.5"/><path d="M12 12 18.5 5.5"/><circle cx="12" cy="12" r="1"/>',
    link: '<path d="M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1 1"/><path d="M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1-1"/>',
    package: '<path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/><path d="m4 7.5 8 4.5 8-4.5"/><path d="M12 12v9"/>',
    server: '<rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7h.01"/><path d="M7 17h.01"/>',
    cat: '<path d="M4 9 6 4l4 3h4l4-3 2 5v5a6 6 0 0 1-6 6h-4a6 6 0 0 1-6-6z"/><path d="M9 13h.01"/><path d="M15 13h.01"/><path d="M10 17h4"/>',
    cube: '<path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/><path d="m4 7.5 8 4.5 8-4.5"/><path d="M12 12v9"/>',
    layers: '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/><path d="m3 18 9 5 9-5"/>',
    zap: '<path d="M13 2 3 14h8l-1 8 10-12h-8z"/>',
    activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    file: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    code: '<path d="m8 8-5 4 5 4"/><path d="m16 8 5 4-5 4"/><path d="m14 4-4 16"/>',
    lock: '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    archive: '<rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>'
  };

  function icon(name, size) {
    var body = ICONS[name] || ICONS.info;
    var s = size || 20;
    return '<svg viewBox="0 0 24 24" width="' + s + '" height="' + s + '" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + '</svg>';
  }

  // ----------------------------------------------------------
  // 运行时桥
  // ----------------------------------------------------------
  var runtime = {
    preview: false,
    cli: MODULE_PATH_FALLBACK + '/nakedcore',
    moduleDir: '',
    cbSeq: 0
  };

  function detectRuntime() {
    var q = new URLSearchParams(window.location.search || '');
    if (q.get('mock') === '1') runtime.preview = true;
    var ksu = window.ksu;
    if (!runtime.preview && ksu && typeof ksu.exec === 'function') {
      try {
        if (typeof ksu.moduleInfo === 'function') {
          var info = JSON.parse(ksu.moduleInfo());
          if (info && info.moduleDir) {
            runtime.moduleDir = String(info.moduleDir).replace(/\/+$/, '');
            runtime.cli = runtime.moduleDir + '/nakedcore';
          }
        }
      } catch (e) { /* ignore */ }
      try {
        if (typeof ksu.enableEdgeToEdge === 'function') ksu.enableEdgeToEdge(true);
        else if (typeof ksu.fullScreen === 'function') ksu.fullScreen(true);
      } catch (e2) { /* ignore */ }
    } else {
      runtime.preview = true;
    }
    var qcli = q.get('cli');
    if (qcli) runtime.cli = qcli;
  }

  function ksuExec(command, options) {
    return new Promise(function (resolve, reject) {
      var name = '__nc_cb_' + (++runtime.cbSeq);
      var timer = setTimeout(function () {
        delete window[name];
        reject(new Error('命令执行超时'));
      }, 60000);
      window[name] = function (errno, stdout, stderr) {
        clearTimeout(timer);
        delete window[name];
        resolve({
          errno: Number(errno) || 0,
          stdout: String(stdout == null ? '' : stdout),
          stderr: String(stderr == null ? '' : stderr)
        });
      };
      try {
        window.ksu.exec(command, JSON.stringify(options || {}), name);
      } catch (e) {
        clearTimeout(timer);
        delete window[name];
        reject(e);
      }
    });
  }

  async function runCli(args, opts) {
    opts = opts || {};
    if (runtime.preview) return mockExec(args, opts);
    var tail = args && args.length ? ' ' + args.map(shq).join(' ') : '';
    // 依次尝试：模块实际路径 → PATH 中的 wrapper → 持久化运行时副本
    // 覆盖“刚安装尚未重启、模块仍在 modules_update”的场景
    var commands = [
      shq(runtime.cli) + tail,
      'nakedcore' + tail,
      shq('/data/adb/nakedcore/runtime/nakedcore') + tail
    ];
    var res = null;
    var seen = {};
    for (var i = 0; i < commands.length; i++) {
      if (seen[commands[i]]) continue;
      seen[commands[i]] = true;
      try {
        res = await ksuExec(commands[i]);
      } catch (e) {
        res = { errno: 127, stdout: '', stderr: String(e && e.message ? e.message : e) };
      }
      if (!(res.errno === 127 || /not found|no such file/i.test(res.stderr || ''))) break;
    }
    res = res || { errno: 127, stdout: '', stderr: 'nakedcore 不可用' };
    return {
      ok: res.errno === 0,
      errno: res.errno,
      stdout: opts.trim === false ? res.stdout : res.stdout.trim(),
      stderr: res.stderr.trim(),
      raw: res
    };
  }

  // ----------------------------------------------------------
  // 状态
  // ----------------------------------------------------------
  var state = {
    status: null,
    loading: true,
    error: '',
    page: 'home',
    themeMode: 'system',
    preview: false,
    busy: '',
    task: null,
    taskTimer: null,
    statusTimer: null,
    refreshing: false,
    lastOutput: '',
    lastLabel: '',
    lastAt: 0,
    sheet: null,
    confirmResolve: null,
    pageScroll: {},
    config: {
      target: 'singbox',
      content: '',
      original: '',
      dirty: false,
      loading: false
    },
    conn: {
      items: [],
      results: {},
      context: null,
      region: '',
      testedAt: 0,
      loaded: false,
      loading: false,
      error: '',
      filter: 'all',
      probing: {}
    },
    forms: {
      pull: {
        singbox: { url: '', force: false },
        mihomo: { url: '', force: false }
      },
      sub: { host: '127.0.0.1', port: '3000', merge: true, frontPort: '3001', dirty: false },
      proxy: '',
      proxyDirty: false
    }
  };

  function taskRunning() {
    return !!(state.task && state.task.state === 'running');
  }

  function canAct() {
    return !state.busy && !taskRunning();
  }

  function disableAttr() {
    return canAct() ? '' : ' disabled';
  }

  function lockedClass() {
    return canAct() ? '' : ' is-locked';
  }

  // ----------------------------------------------------------
  // 主题 / 导航 / 顶栏
  // ----------------------------------------------------------
  function applyTheme(mode, silent) {
    mode = mode === 'light' || mode === 'dark' ? mode : 'system';
    state.themeMode = mode;
    var dark = mode === 'dark' || (mode === 'system' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    document.documentElement.dataset.themeMode = mode;
    try { localStorage.setItem(THEME_KEY, mode); } catch (e) { /* ignore */ }
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', dark ? '#08090b' : '#f4f6f8');
    renderThemeButton();
    if (!silent) toast('主题：' + (mode === 'system' ? '跟随系统' : mode === 'light' ? '浅色' : '深色'), 'info', 1600);
  }

  function themeIconName() {
    if (state.themeMode === 'light') return 'sun';
    if (state.themeMode === 'dark') return 'moon';
    return 'monitor';
  }

  function renderThemeButton() {
    var btn = $('#theme-btn');
    if (btn) btn.innerHTML = icon(themeIconName(), 19);
  }

  function cycleTheme() {
    var order = ['system', 'light', 'dark'];
    var idx = order.indexOf(state.themeMode);
    applyTheme(order[(idx + 1) % order.length]);
  }

  function renderNavIcons() {
    $$('[data-icon]').forEach(function (el) {
      el.innerHTML = icon(el.dataset.icon, 22);
    });
  }

  function renderTopbar() {
    var s = state.status;
    var version = s && s.module && s.module.version ? s.module.version : 'v3.0.0';
    var chip = $('#version-chip');
    if (chip) chip.textContent = version;
    var preview = $('#preview-chip');
    if (preview) preview.hidden = !runtime.preview;
    renderThemeButton();
  }

  function setPage(page) {
    if (page !== 'home' && page !== 'core' && page !== 'config' && page !== 'connectivity') page = 'home';
    state.pageScroll[state.page] = window.scrollY || 0;
    state.page = page;
    $$('.page').forEach(function (el) { el.classList.toggle('is-active', el.dataset.page === page); });
    $$('.tab').forEach(function (el) {
      var active = el.dataset.nav === page;
      el.classList.toggle('is-active', active);
      if (active) el.setAttribute('aria-current', 'page');
      else el.removeAttribute('aria-current');
    });
    try { history.replaceState(null, '', '#' + page); } catch (e) { /* ignore */ }
    renderPage();
    window.scrollTo(0, state.pageScroll[page] || 0);
    if (page === 'config' && !state.config.content && !state.config.loading) loadConfig(state.config.target);
    if (page === 'connectivity' && !state.conn.loaded && !state.conn.loading) loadConnectivity();
    if (!state.status) refreshStatus(false);
  }

  function renderPage() {
    if (state.page === 'home') renderHome();
    else if (state.page === 'core') renderCore();
    else if (state.page === 'connectivity') renderConnectivity();
    else renderConfigPage();
  }

  // ----------------------------------------------------------
  // 状态读取
  // ----------------------------------------------------------
  async function refreshStatus(initial) {
    if (state.refreshing) return;
    state.refreshing = true;
    try {
      var res = await runCli(['status']);
      if (!res.ok) throw new Error(firstLine(res.stderr || res.stdout) || '状态读取失败');
      var data = parseJSON(res.stdout);
      state.status = data;
      state.error = '';
      state.loading = false;
      if (!runtime.preview) {
        try { localStorage.setItem(STATUS_CACHE_KEY, JSON.stringify(data)); } catch (e) { /* ignore */ }
      }
      syncFormsFromStatus();
      renderTopbar();
      if (!initial) {
        if (state.page === 'home' || state.page === 'core') renderPage();
        else if (state.page === 'config') updateConfigDynamic();
      }
      if (data.task && data.task.state === 'running' && !taskRunning()) {
        state.task = { id: data.task.id, label: data.task.label || '执行任务', state: 'running', log: '', started: data.task.started || Math.floor(Date.now() / 1000) };
        pollTask(state.task.id);
      }
      renderConsole();
    } catch (e) {
      state.loading = false;
      state.error = e && e.message ? e.message : String(e);
      if (!state.status) {
        renderPage();
      } else {
        renderConsole();
        if (state.page === 'home' || state.page === 'core') renderPage();
        else if (state.page === 'config') updateConfigDynamic();
      }
    } finally {
      state.refreshing = false;
    }
  }

  function startStatusPolling() {
    if (state.statusTimer) clearInterval(state.statusTimer);
    state.statusTimer = setInterval(function () {
      if (document.hidden) return;
      if (taskRunning()) return;
      refreshStatus(false);
    }, STATUS_POLL_MS);
  }

  function syncFormsFromStatus() {
    var s = state.status;
    if (!s) return;
    if (!state.forms.sub.dirty && s.substore) {
      state.forms.sub.host = s.substore.host === '0.0.0.0' ? '0.0.0.0' : '127.0.0.1';
      state.forms.sub.port = String(s.substore.port || 3000);
      state.forms.sub.merge = !!s.substore.merge;
      state.forms.sub.frontPort = String(s.substore.front_port || 3001);
    }
    if (!state.forms.proxyDirty) state.forms.proxy = s.settings && s.settings.gh_proxy ? s.settings.gh_proxy : '';
  }

  // ----------------------------------------------------------
  // 通用片段
  // ----------------------------------------------------------
  function pill(label, tone, dot) {
    var cls = 'pill' + (tone ? ' pill--' + tone : '');
    return '<span class="' + cls + '">' + (dot === false ? '' : '<span class="pill__dot"></span>') + escapeHTML(label) + '</span>';
  }

  function versionPill(label, tone) {
    var text = String(label == null ? '' : label);
    return '<span class="pill pill--version' + (tone ? ' pill--' + tone : '') + '" title="' + escapeHTML(text) + '">' + escapeHTML(text) + '</span>';
  }

  function switchHTML(checked, action, attrs) {
    return '<button class="switch" type="button" role="switch" aria-checked="' + (checked ? 'true' : 'false') + '" data-action="' + action + '" ' + (attrs || '') + ' aria-label="开关"></button>';
  }

  function coreLogo(id, variant) {
    var meta = CORE_META[id] || CORE_META['sing-box'];
    return '<span class="corelogo' + (variant ? ' corelogo--' + variant : '') + (id === 'mihomo' ? ' corelogo--mihomo' : '') + '">' + icon(meta.icon, variant === 'light' ? 23 : 28) + '</span>';
  }

  function coreChannel(s, id) {
    if (!s || !s.settings) return 'stable';
    if (id === 'sing-box') return s.settings.singbox_channel || 'stable';
    return s.settings.mihomo_channel || 'stable';
  }

  function rowicon(name, tone) {
    return '<span class="rowicon' + (tone ? ' rowicon--' + tone : '') + '">' + icon(name, 18) + '</span>';
  }

  function configBadge(configState) {
    if (configState === 'ok') return pill('配置正常', 'ok');
    if (configState === 'fail') return pill('配置异常', 'bad');
    if (configState === 'none') return pill('无配置', 'bad');
    return pill('待校验', 'warn');
  }

  function coreStatusTone(core) {
    if (core.running) return 'ok';
    if (core.installed) return 'warn';
    return 'bad';
  }

  function coreStatusText(core) {
    if (core.running) return '运行中';
    if (core.installed) return '已停止';
    return '未安装';
  }

  function subStatusTone(sub) {
    if (sub.running) return 'ok';
    if (sub.health) return 'warn';
    return 'bad';
  }

  function subStatusText(sub) {
    if (sub.running) return '运行中';
    if (sub.health) return '已停止';
    return '未安装';
  }

  function versionState(installed, latest) {
    if (!latest) return { text: '未检查', tone: 'neutral', update: false };
    if (!installed) return { text: '可安装', tone: 'info', update: true };
    if (sameVer(installed, latest)) return { text: '已是最新', tone: 'ok', update: false };
    return { text: '有更新', tone: 'warn', update: true };
  }

  function sectionHead(title, subtitle, actionHTML) {
    return '<div class="section-head"><div><h2>' + escapeHTML(title) + '</h2>' + (subtitle ? '<p>' + escapeHTML(subtitle) + '</p>' : '') + '</div>' + (actionHTML ? '<div class="section-head__action">' + actionHTML + '</div>' : '') + '</div>';
  }

  function errorBanner() {
    if (!state.error) return '';
    return '<div class="banner banner--bad">' + icon('alert') +
      '<div class="banner__body"><div class="banner__title">状态读取失败</div><div>' + escapeHTML(state.error) + '</div>' +
      '<button class="btn btn--sm btn--soft" type="button" data-action="refresh">' + icon('refresh', 14) + '重试</button></div></div>';
  }

  function skeletonHome() {
    return '<div class="skeleton skeleton--hero"></div>' +
      '<div class="skeleton skeleton--card"></div>' +
      '<div class="skeleton skeleton--card"></div>';
  }

  function skeletonList() {
    return '<div class="skeleton skeleton--card"></div><div class="skeleton skeleton--card"></div>';
  }

  function loadingShell(message) {
    return '<div class="loading-state"><span class="spinner"></span>' + escapeHTML(message || '加载中…') + '</div>';
  }

  // ----------------------------------------------------------
  // 主页
  // ----------------------------------------------------------
  function renderHome() {
    var root = $('#home-body');
    if (!root) return;
    if (!state.status) {
      root.innerHTML = state.error ? errorBanner() : skeletonHome();
      return;
    }
    var s = state.status;
    var active = s.settings.active_core;
    var core = s.cores[active] || s.cores['sing-box'];
    var sub = s.substore;
    root.innerHTML = '<div class="stack">' + errorBanner() + renderHero(s, active, core) +
      renderSubCard(s, sub) + renderQuickLinks(s) + '</div>';
  }

  function renderHero(s, active, core) {
    var meta = CORE_META[active] || CORE_META['sing-box'];
    var running = !!core.running;
    var canStart = core.installed && core.config_state !== 'fail' && core.config_state !== 'none';
    var hotspot = s.hotspot || { enabled: false, active: false, usb: true, ifaces: [], subnet: '' };
    var actions;
    if (running) {
      actions = '<button class="btn btn--primary" type="button" data-action="core.stop"' + disableAttr() + '>' + icon('stop') + '停止</button>' +
        '<button class="btn btn--soft" type="button" data-action="core.restart"' + disableAttr() + '>' + icon('restart') + '重启</button>' +
        '<button class="btn btn--soft" type="button" data-action="core.switch"' + disableAttr() + '>' + icon('switch') + '切换</button>' +
        '<button class="btn btn--soft" type="button" data-action="core.log" data-core="' + active + '">' + icon('terminal') + '日志</button>';
    } else {
      actions = '<button class="btn btn--primary" type="button" data-action="core.start"' + (!canStart ? ' disabled' : disableAttr()) + '>' + icon('play') + (core.installed ? (core.config_state === 'none' ? '无配置' : '启动') : '未安装') + '</button>' +
        '<button class="btn btn--soft" type="button" data-action="core.switch"' + disableAttr() + '>' + icon('switch') + '切换</button>' +
        '<button class="btn btn--soft" type="button" data-action="core.check">' + icon('shield') + '校验</button>' +
        '<button class="btn btn--soft" type="button" data-action="core.log" data-core="' + active + '">' + icon('terminal') + '日志</button>';
    }

    var warn = '';
    if (!core.installed) {
      warn = '<div class="hero__warn">' + icon('alert', 16) + '<span>尚未安装 ' + escapeHTML(meta.name) + '，去核心页安装后即可启动。</span></div>';
    } else if (core.config_state === 'fail') {
      warn = '<div class="hero__warn">' + icon('alert', 16) + '<span>配置校验未通过，内核不会启动。请到配置页修复。</span></div>';
    } else if (core.config_state === 'none') {
      warn = '<div class="hero__warn">' + icon('info', 16) + '<span>尚未导入配置。请到配置页粘贴订阅链接或导入配置文件。</span></div>';
    } else if (core.config_dirty) {
      warn = '<div class="hero__warn">' + icon('info', 16) + '<span>配置已修改，重启内核后生效。</span></div>';
    }

    return '<section class="hero">' +
      '<div class="hero__top">' + coreLogo(active) +
      '<div class="hero__titlewrap">' +
      '<div class="hero__eyebrow">当前激活内核</div>' +
      '<div class="hero__name">' + escapeHTML(meta.name) + '</div>' +
      '<div class="hero__meta"><span>' + escapeHTML(verLabel(core.version)) + '</span><span class="dot"></span><span>' + escapeHTML(channelLabel(coreChannel(s, active))) + '</span><span class="dot"></span><span>' + escapeHTML(core.config_state === 'fail' ? '配置异常' : core.config_state === 'none' ? '无配置' : core.config_state === 'unknown' ? '待校验' : '配置正常') + '</span></div>' +
      '</div>' +
      '<div class="hero__status">' + pill(running ? '运行中' : '已停止', running ? 'ok' : 'neutral') + '</div>' +
      '</div>' +
      '<div class="hero__actions">' + actions + '</div>' +
      '<div class="hero__toggles">' +
      '<div class="hero__toggle"><div class="row__main"><div class="row__title">开机自启动</div><div class="row__sub">' + (s.settings.auto_start ? '已开启 · 启动前校验配置' : '已关闭 · 需要手动启动') + '</div></div>' + switchHTML(s.settings.auto_start, 'core.autostart') + '</div>' +
      '<div class="hero__toggle"><div class="row__main"><div class="row__title">热点代理共享</div><div class="row__sub">' + (hotspot.enabled ? (hotspot.active ? '已接管热点流量' : '已开启 · 等待热点/内核') : '未开启 · 局域网设备直连代理') + '</div></div>' + switchHTML(hotspot.enabled, 'hotspot.toggle') + '</div>' +
      '</div>' +
      warn +
      '</section>';
  }

  function renderSubCard(s, sub) {
    var head = '<div class="card__head"><div class="cluster">' + rowicon('layers', 'accent') +
      '<div><div class="card__title">Sub-Store</div><div class="card__sub">订阅管理 · 前后端 · HTTP API</div></div></div>' +
      '<div>' + pill(subStatusText(sub), subStatusTone(sub)) + '</div></div>';

    if (!sub.health && !sub.running) {
      return '<section class="card">' + head +
        '<div class="empty"><div class="empty__icon">' + icon('package', 26) + '</div>' +
        '<div class="empty__title">运行环境未就绪</div>' +
        '<div class="empty__text">' + escapeHTML(sub.health_reason || '需要 Node、Sub-Store 后端与前端。点击下方按钮自动下载安装。') + '</div>' +
        '<button class="btn btn--primary" type="button" data-action="sub.install"' + disableAttr() + '>' + icon('download') + '安装运行环境</button></div></section>';
    }

    var url = sub.direct_url || sub.open_url || '';
    var urlBox = url ? '<div class="urlbox"><span class="urlbox__icon">' + icon('link', 16) + '</span><code>' + escapeHTML(url) + '</code>' +
      '<button class="iconbtn" type="button" data-action="sub.copy" data-value="' + escapeHTML(url) + '" aria-label="复制地址">' + icon('copy', 16) + '</button>' +
      '<button class="iconbtn" type="button" data-action="sub.open" aria-label="打开地址">' + icon('external', 16) + '</button></div>' : '';

    var meta = '<div class="cluster" style="margin-top:10px">' +
      '<span class="inline-code">后端 ' + escapeHTML(verLabel(sub.backend && sub.backend.version)) + '</span>' +
      '<span class="inline-code">前端 ' + escapeHTML(verLabel(sub.frontend && sub.frontend.version)) + '</span>' +
      '<span class="inline-code">Node ' + escapeHTML(verLabel(sub.node && sub.node.version)) + '</span>' +
      '<span class="inline-code">:' + escapeHTML(sub.port) + '</span>' +
      '</div>';

    var actions;
    if (sub.running) {
      actions = '<button class="btn btn--primary" type="button" data-action="sub.open">' + icon('external') + '打开</button>' +
        '<button class="btn btn--soft" type="button" data-action="sub.restart"' + disableAttr() + '>' + icon('restart') + '重启</button>' +
        '<button class="btn btn--soft" type="button" data-action="sub.stop"' + disableAttr() + '>' + icon('stop') + '停止</button>' +
        '<button class="btn btn--soft" type="button" data-action="sub.log">' + icon('terminal') + '日志</button>';
    } else {
      actions = '<button class="btn btn--primary" type="button" data-action="sub.start"' + disableAttr() + '>' + icon('play') + '启动</button>' +
        '<button class="btn btn--soft" type="button" data-action="sub.log">' + icon('terminal') + '日志</button>';
    }

    var dirty = sub.dirty ? '<div class="banner banner--info" style="margin-top:12px">' + icon('info') +
      '<div class="banner__body"><div class="banner__title">环境变量已修改</div><div>重启 Sub-Store 后生效。</div>' +
      '<button class="btn btn--sm btn--soft" type="button" data-action="sub.restart"' + disableAttr() + '>立即重启</button></div></div>' : '';

    return '<section class="card">' + head + urlBox + meta + dirty +
      '<div class="cluster" style="margin-top:14px">' + actions + '</div></section>';
  }

  function renderQuickLinks(s) {
    function panelRow(title, subtitle, iconName, tone, url) {
      return '<button class="row row--tap" type="button" data-action="open.link" data-url="' + escapeHTML(url) + '" style="width:100%;text-align:left;background:none">' +
        rowicon(iconName, tone) +
        '<span class="row__main"><span class="row__title">' + escapeHTML(title) + '</span><span class="row__sub">' + escapeHTML(subtitle) + '</span></span>' +
        '<span class="chev">' + icon('chevron', 17) + '</span></button>';
    }
    return '<section class="card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('grid', 18) + '外部面板</div><div class="card__sub">Clash API 面板入口</div></div></div>' +
      '<div style="margin-top:6px">' +
      panelRow('Dashboard', 'sing-box 官方 Clash API 面板', 'activity', 'accent', 'https://sing-box-dashboard.sagernet.org/') +
      panelRow('Zashboard', 'Mihomo / Clash 通用面板', 'grid', 'mint', 'https://board.zash.run.place/') +
      '</div></section>';
  }

  // ----------------------------------------------------------
  // 核心页
  // ----------------------------------------------------------
  function renderCore() {
    var root = $('#core-body');
    if (!root) return;
    if (!state.status) {
      root.innerHTML = state.error ? errorBanner() : skeletonList();
      return;
    }
    var s = state.status;
    var coreActions = '<div class="cluster section-actions">' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="checkup"' + disableAttr() + '>' + icon('refresh', 14) + '检查更新</button>' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="all.update"' + disableAttr() + '>' + icon('zap', 14) + '一键更新</button>' +
      '</div>';
    root.innerHTML = '<div class="stack">' + errorBanner() +
      sectionHead('内核', '安装、切换通道与校验配置', coreActions) +
      ['sing-box', 'mihomo'].filter(function (id) { return !!s.cores[id]; }).map(function (id) { return coreCard(s, id); }).join('') +
      sectionHead('Sub-Store', '前端 / 后端 / Node 管理', '') +
      subUpdateCard(s) +
      sectionHead('自动化', '热点共享 · Wi-Fi 到家暂停', '') +
      hotspotCard(s) +
      wifiCard(s) +
      '</div>';
  }

  function coreCard(s, id) {
    var core = s.cores[id];
    if (!core) return '';
    var channel = coreChannel(s, id);
    var vs = versionState(core.version, core.latest);
    var active = s.settings.active_core === id;
    var meta = CORE_META[id];
    var channelSeg = '<div class="seg">' + ['stable', 'alpha'].map(function (ch) {
      return '<button type="button" class="' + (channel === ch ? 'is-active' : '') + '" data-action="core.channel" data-core="' + id + '" data-channel="' + ch + '">' + (ch === 'stable' ? '稳定版' : '预览版') + '</button>';
    }).join('') + '</div>';

    return '<section class="card core-card">' +
      '<div class="card__head"><div class="cluster">' + coreLogo(id, 'light') +
      '<div><div class="card__title">' + escapeHTML(meta.name) + (active ? ' ' + pill('激活', 'info', false) : '') + '</div><div class="card__sub">' + escapeHTML(meta.tagline) + '</div></div></div>' +
      '<div class="card__version">' + versionPill(core.installed ? verLabel(core.version) : '未安装', 'neutral') + '</div></div>' +
      '<div class="divider"></div>' +
      '<div class="row"><div class="row__main"><div class="row__title">最新版本</div><div class="row__sub">' + (core.latest ? '最新 ' + escapeHTML(verLabel(core.latest)) : '尚未检查更新') + '</div></div><span class="pill' + (vs.tone ? ' pill--' + vs.tone : '') + '">' + escapeHTML(vs.text) + '</span></div>' +
      '<div class="row"><div class="row__main"><div class="row__title">预设通道</div><div class="row__sub">更新时默认使用该通道</div></div>' + channelSeg + '</div>' +
      '<div class="row"><div class="row__main"><div class="row__title">配置文件</div><div class="row__sub">' + escapeHTML(core.config_exists ? humanSize(core.config_size) : '尚未创建') + '</div></div>' + configBadge(core.config_state) + '</div>' +
      (core.config_dirty ? '<div class="banner banner--info" style="margin-top:12px">' + icon('info') + '<div class="banner__body">配置已修改，重启内核后生效。</div></div>' : '') +
      '<div class="cluster actions-grid actions-grid--core" style="margin-top:14px">' +
      '<button class="btn ' + (core.installed ? 'btn--soft' : 'btn--primary') + ' btn--sm" type="button" data-action="core.update" data-core="' + id + '" data-channel="' + channel + '"' + disableAttr() + '>' + icon('download', 15) + (core.installed ? '更新' : '安装') + '</button>' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="core.check" data-core="' + id + '">' + icon('shield', 15) + '校验配置</button>' +
      (core.rollback ? '<button class="btn btn--ghost btn--sm" type="button" data-action="core.rollback" data-core="' + id + '"' + disableAttr() + '>' + icon('restart', 15) + '回滚</button>' : '') +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="core.log" data-core="' + id + '">' + icon('terminal', 15) + '日志</button>' +
      (core.installed ? '<button class="btn btn--danger btn--sm" type="button" data-action="core.delete" data-core="' + id + '"' + disableAttr() + '>' + icon('trash', 15) + '删除</button>' : '') +
      '</div></section>';
  }

  function subUpdateCard(s) {
    var sub = s.substore;
    var head = '<div class="card__head"><div class="cluster">' + rowicon('layers', 'accent') +
      '<div><div class="card__title">Sub-Store</div><div class="card__sub">精简运行环境 · 合并端口</div></div></div>' +
      '<div>' + pill(subStatusText(sub), subStatusTone(sub)) + '</div></div>';

    if (!sub.health && !sub.running) {
      return '<section class="card">' + head +
        '<div class="empty"><div class="empty__icon">' + icon('package', 26) + '</div>' +
        '<div class="empty__title">运行环境未安装</div><div class="empty__text">' + escapeHTML(sub.health_reason || '需要 Node、Sub-Store 后端与前端') + '</div>' +
        '<button class="btn btn--primary" type="button" data-action="sub.install"' + disableAttr() + '>' + icon('download') + '一键安装</button></div></section>';
    }

    function versionRow(label, iconName, obj, action, actionLabel) {
      var installed = obj && obj.installed;
      return '<div class="row"><div class="row__main"><div class="row__title">' + icon(iconName, 16) + escapeHTML(label) + '</div></div>' +
        '<div class="row__side"><span class="sub-version">' + escapeHTML(installed ? verLabel(obj.version) : '未安装') + '</span>' +
        '<button class="btn btn--soft btn--sm" type="button" data-action="' + action + '"' + disableAttr() + '>' + (installed ? '更新' : '安装') + '</button></div></div>';
    }

    return '<section class="card">' + head +
      versionRow('Node 运行时', 'server', sub.node, 'sub.update.node', '更新') +
      versionRow('后端 bundle', 'package', sub.backend, 'sub.update.backend', '更新') +
      versionRow('前端静态包', 'grid', sub.frontend, 'sub.update.frontend', '更新') +
      '<div class="row row--stack"><div class="row__main"><div class="row__title">' + icon('lock', 16) + '访问路径</div><div class="row__sub">随机路径用于隐藏本地 API</div></div>' +
      '<div class="row__side"><span class="inline-code">' + escapeHTML(sub.backend_path || '—') + '</span>' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="sub.regen"' + disableAttr() + '>重新生成</button></div></div>' +
      '<div class="row"><div class="row__main"><div class="row__title">' + icon('power', 16) + '开机自启</div><div class="row__sub">' + (sub.autostart ? '已开启' : '已关闭') + '</div></div>' + switchHTML(sub.autostart, 'sub.autostart') + '</div>' +
      '<div class="cluster actions-grid actions-grid--primary" style="margin-top:14px">' +
      '<button class="btn btn--primary btn--sm" type="button" data-action="sub.update.all"' + disableAttr() + '>' + icon('download', 15) + '更新前端与后端</button>' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="sub.restart"' + disableAttr() + '>' + icon('restart', 15) + '重启</button>' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="sub.settings">' + icon('sliders', 15) + '端口与模式</button>' +
      '</div>' +
      (sub.dirty ? '<div class="banner banner--info" style="margin-top:12px">' + icon('info') + '<div class="banner__body">环境变量已修改，重启后生效。</div></div>' : '') +
      '</section>';
  }

  // ----------------------------------------------------------
  // 热点代理共享
  // ----------------------------------------------------------
  function hotspotCard(s) {
    var h = s.hotspot || { enabled: false, active: false, usb: true, ifaces: [], subnet: '' };
    var ifaces = Array.isArray(h.ifaces) ? h.ifaces : [];
    var core = s.cores && s.settings ? s.cores[s.settings.active_core] : null;
    var coreRunning = !!(core && core.running);
    var active = !!h.active;
    var statusText;
    var statusTone;
    var detail;
    if (!h.enabled) {
      statusText = '未开启';
      statusTone = 'neutral';
      detail = '开启后，连接手机热点或 USB 共享的设备无需单独配置即可使用当前内核代理。';
    } else if (active) {
      statusText = '已接管';
      statusTone = 'ok';
      detail = '热点流量已接入代理';
    } else if (!coreRunning) {
      statusText = '待命';
      statusTone = 'neutral';
      detail = '内核未运行 · 启动内核后自动接管';
    } else if (ifaces.length) {
      statusText = '待命';
      statusTone = 'neutral';
      detail = '已检测到热点，等待规则同步';
    } else {
      statusText = '待命';
      statusTone = 'neutral';
      detail = '未检测到开启的热点 · 打开手机热点后自动接管';
    }
    var endpoint = h.enabled && ifaces.length
      ? ifaces.join(', ') + (h.subnet ? ' · ' + h.subnet : '')
      : '';
    return '<section class="card hotspot-card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('hotspot', 18) + '热点代理共享</div>' +
      '<div class="card__sub">接管手机热点流量 · 局域网设备直连代理</div></div>' +
      switchHTML(h.enabled, 'hotspot.toggle') + '</div>' +
      '<div class="hotspot-state ' + (active ? 'is-active' : '') + '">' +
      '<span class="hotspot-state__icon">' + icon('hotspot', 17) + '</span>' +
      '<span class="hotspot-state__body"><span class="hotspot-state__title">' + escapeHTML(detail) + '</span>' +
      (endpoint ? '<span class="hotspot-state__meta">' + escapeHTML(endpoint) + '</span>' : '') + '</span>' +
      pill(statusText, statusTone) + '</div>' +
      '<div class="hotspot-controls"><div class="hotspot-usb"><div class="row__main"><div class="row__title">同时接管 USB 共享</div><div class="row__sub">rndis / ncm 网络共享</div></div>' + switchHTML(h.usb, 'hotspot.usb') + '</div>' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="hotspot.sync"' + disableAttr() + '>' + icon('refresh', 14) + '刷新检测</button></div>' +
      '<div class="hint">热点设备和 USB 共享设备会自动走当前激活内核；关闭或停止内核时规则自动清理。</div>' +
      '</section>';
  }

  // ----------------------------------------------------------
  // Wi-Fi 自动启停
  // ----------------------------------------------------------
  function wifiCard(s) {
    var w = s.wifi || {
      guard: false,
      ssids: [],
      current_ssid: '',
      trusted: false,
      suspended: false,
      manual_stop: false,
      daemon: false,
      detect_ok: true,
      interval: 20
    };
    var ssids = Array.isArray(w.ssids) ? w.ssids : [];
    var detectOk = w.detect_ok !== false;
    var current = w.current_ssid || '';
    var currentText = !detectOk ? '无法读取 SSID' : (current || '未连接 Wi-Fi');
    var currentPill;
    if (!detectOk) currentPill = pill('跳过检测', 'bad');
    else if (!current) currentPill = pill('无线已断开', 'info');
    else if (w.trusted) currentPill = pill('信任网络', 'ok');
    else currentPill = pill('未信任', 'info');

    var chips = ssids.map(function (ssid) {
      return '<span class="wifi-chip"><span class="wifi-chip__name">' + escapeHTML(ssid) + '</span>' +
        '<button class="wifi-chip__x" type="button" data-action="wifi.remove" data-ssid="' + escapeHTML(ssid) + '" aria-label="移除 ' + escapeHTML(ssid) + '">' + icon('x', 12) + '</button></span>';
    }).join('');

    var note = '';
    if (w.manual_stop) {
      note = '<div class="wifi-note wifi-note--manual">' + icon('alert', 15) +
        '<span>手动停止优先：离开 Wi-Fi 不会自动启动内核。</span>' +
        '<button class="btn btn--ghost btn--sm" type="button" data-action="wifi.resume">' + icon('refresh', 14) + '恢复自动</button></div>';
    } else if (w.suspended) {
      note = '<div class="wifi-note">' + icon('info', 15) + '<span>已进入信任网络，内核已暂停；离开后会自动恢复。</span></div>';
    }

    return '<section class="card wifi-card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('wifi', 18) + 'Wi-Fi 自动启停</div>' +
      '<div class="card__sub">连接信任网络时停止内核，离开后恢复</div></div>' +
      switchHTML(w.guard, 'wifi.toggle') + '</div>' +
      '<div class="wifi-current ' + (w.trusted ? 'is-trusted' : '') + '">' +
      '<span class="wifi-current__icon">' + icon('wifi', 16) + '</span>' +
      '<span class="wifi-current__body"><span class="wifi-current__label">当前 Wi-Fi</span><span class="wifi-current__name">' + escapeHTML(currentText) + '</span></span>' +
      currentPill + '</div>' +
      note +
      '<div class="field"><div class="field__label"><span>信任的 Wi-Fi</span><span class="tiny dim">连接时暂停内核</span></div>' +
      '<div class="wifi-chips">' + (chips || '<span class="wifi-empty">尚未添加，先加入家里的 Wi-Fi</span>') + '</div></div>' +
      '<div class="wifi-add"><input class="input" id="wifi-ssid-input" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Wi-Fi 名称，例如 2.4G">' +
      '<button class="btn btn--soft" type="button" data-action="wifi.add">' + icon('plus', 15) + '添加</button></div>' +
      '<div class="wifi-foot"><span class="tiny dim">' + (w.guard ? (w.daemon ? '守护运行中' : '守护未运行') : '自动启停已关闭') + ' · 每 ' + escapeHTML(String(w.interval || 20)) + ' 秒检测</span>' +
      '<span class="wifi-foot__actions">' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="wifi.check">' + icon('refresh', 14) + '检测</button>' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="log.open" data-log="wifi">' + icon('terminal', 14) + '日志</button>' +
      '</span></div>' +
      '<div class="hint">手动停止优先：手动停止后离开 Wi-Fi 不会自动启动；只有未手动停止的内核才会自动恢复。</div>' +
      '</section>';
  }

  // ----------------------------------------------------------
  // 配置页
  // ----------------------------------------------------------
  function configPullInline(target, targetMeta) {
    var fileInput = '<input id="cfg-file" type="file" accept=".json,.yaml,.yml,.env,.txt,text/*,application/json" hidden>';
    if (target === 'substore') {
      return '<div class="cfg-pull cfg-pull--sub">' +
        '<div class="cfg-import-row"><span class="cfg-import-row__label">' + icon('upload', 15) + '本地导入</span>' +
        '<span class="tiny dim">导入到编辑器后保存</span>' +
        '<button class="btn btn--ghost btn--sm" type="button" data-action="cfg.import" data-target="substore"' + disableAttr() + '>选择文件</button></div>' +
        fileInput + '</div>';
    }
    var form = state.forms.pull[target] || { url: '', force: false };
    var placeholder = target === 'mihomo'
      ? 'https://gist.githubusercontent.com/…/mihomo_android'
      : 'https://gist.githubusercontent.com/…/sing-box';
    var formatHint = target === 'mihomo' ? 'YAML / Clash.Meta' : 'JSON / sing-box';
    return '<details class="cfg-pull">' +
      '<summary><span class="cfg-pull__summary">' + icon('download', 15) + '<span>远程拉取 / 本地导入</span></span>' +
      '<span class="cfg-pull__file">' + escapeHTML(targetMeta.file) + '</span></summary>' +
      '<div class="cfg-pull__body">' +
      '<div class="cfg-pull__url"><input class="input" id="cfg-pull-url" type="url" inputmode="url" placeholder="' + escapeHTML(placeholder) + '" value="' + escapeHTML(form.url || '') + '">' +
      '<button class="btn btn--primary btn--sm" type="button" data-action="cfg.pull" data-target="' + target + '"' + disableAttr() + '>' + icon('download', 14) + '拉取</button></div>' +
      '<div class="cfg-pull__actions"><label class="check"><input id="cfg-pull-force" type="checkbox"' + (form.force ? ' checked' : '') + '> <span>跳过校验</span></label>' +
      '<span class="tiny dim">' + formatHint + '</span>' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="cfg.import" data-target="' + target + '"' + disableAttr() + '>' + icon('upload', 14) + '本地导入</button></div>' +
      '<div class="hint">只写入 ' + escapeHTML(targetMeta.file) + '，不会覆盖另一个内核。</div>' +
      fileInput + '</div></details>';
  }

  function renderConfigPage() {
    var root = $('#config-body');
    if (!root) return;
    if (!state.status) {
      root.innerHTML = state.error ? errorBanner() : skeletonList();
      return;
    }
    var s = state.status;
    var target = state.config.target;
    var cfg = state.config;
    var targetMeta = TARGET_META[target];
    var locked = !canAct();

    var seg = '<div class="seg seg--fill">' + ['singbox', 'mihomo', 'substore'].map(function (t) {
      return '<button type="button" class="' + (target === t ? 'is-active' : '') + '" data-action="cfg.select" data-target="' + t + '">' + TARGET_META[t].label + '</button>';
    }).join('') + '</div>';

    var core = target === 'singbox' ? s.cores['sing-box'] : target === 'mihomo' ? s.cores.mihomo : null;
    var stateText = cfg.dirty ? pill('未保存', 'warn') : (target === 'substore' ? (s.substore.dirty ? pill('已修改', 'warn') : pill('已保存', 'ok')) : configBadge(core ? core.config_state : 'none'));
    var size = cfg.loading ? 0 : utf8Length(cfg.content);

    var editor;
    if (cfg.loading) {
      editor = '<div class="editor"><div class="loading-state"><span class="spinner"></span>读取 ' + escapeHTML(targetMeta.file) + '…</div></div>';
    } else {
      var secondary = '';
      if (target === 'singbox') {
        secondary += '<button class="iconbtn editor__icon" type="button" data-action="cfg.format" title="格式化 JSON" aria-label="格式化 JSON">' + icon('code', 16) + '</button>';
      }
      secondary += '<button class="iconbtn editor__icon" type="button" id="cfg-revert-btn" data-action="cfg.revert" title="还原" aria-label="还原"' + (cfg.dirty ? '' : ' disabled') + '>' + icon('restart', 16) + '</button>' +
        '<button class="iconbtn editor__icon" type="button" data-action="cfg.download" title="下载当前配置" aria-label="下载当前配置"' + (locked ? ' disabled' : '') + '>' + icon('download', 16) + '</button>' +
        '<button class="iconbtn editor__icon editor__icon--danger" type="button" data-action="cfg.delete" title="删除当前配置" aria-label="删除当前配置"' + (locked ? ' disabled' : '') + '>' + icon('trash', 16) + '</button>';
      editor = '<div class="editor">' +
        '<div class="editor__bar">' +
        '<div class="editor__primary">' +
        '<button class="btn btn--primary btn--sm" type="button" id="cfg-save-btn" data-action="cfg.save"' + (!cfg.dirty || locked ? ' disabled' : '') + '>' + icon('save', 14) + '保存</button>' +
        '<button class="btn btn--soft btn--sm" type="button" data-action="cfg.check"' + (locked ? ' disabled' : '') + '>' + icon('shield', 14) + '校验</button>' +
        '</div><div class="editor__secondary">' + secondary + '</div></div>' +
        '<textarea class="editor__area" id="cfg-editor" spellcheck="false" autocapitalize="off" autocomplete="off" placeholder="在这里编辑配置…">' + escapeHTML(cfg.content) + '</textarea>' +
        '<div class="editor__meta"><span><span id="cfg-lines">' + (cfg.content ? cfg.content.split('\n').length : 0) + ' 行</span> · <span id="cfg-chars">' + cfg.content.length + ' 字符</span></span>' +
        '<span id="cfg-save-state" class="' + (cfg.dirty ? 'dirty' : 'saved') + '">' + (cfg.dirty ? '已修改' : '已保存') + '</span></div>' +
        '</div>';
    }

    var configCard = '<section class="card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('file', 18) + '配置文件</div><div class="card__sub">在线编辑 · 自动校验 · .bak 备份</div></div></div>' +
      '<div style="margin-top:12px">' + seg + '</div>' +
      configPullInline(target, targetMeta) +
      '<div class="kv"><span class="kv__k">路径</span><span class="kv__v">' + escapeHTML(targetMeta.path) + '</span></div>' +
      '<div class="kv"><span class="kv__k">状态</span><span class="kv__v" id="cfg-file-state">' + stateText + ' · <span id="cfg-file-size">' + humanSize(size) + '</span></span></div>' +
      editor +
      '</section>';

    var networkCard = '<section class="card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('globe', 18) + '网络与备份</div><div class="card__sub">GitHub 加速 · 全部配置打包</div></div></div>' +
      '<div class="field" style="margin-top:10px"><div class="field__label"><span>GitHub 加速前缀</span><span class="tiny dim">留空直连</span></div>' +
      '<input class="input" id="proxy-input" type="url" inputmode="url" placeholder="https://gh-proxy.com" value="' + escapeHTML(state.forms.proxy || '') + '"></div>' +
      '<div class="cluster" style="margin-top:8px">' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="proxy.save"' + disableAttr() + '>' + icon('save', 14) + '保存</button>' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="proxy.clear"' + disableAttr() + '>' + icon('x', 14) + '直连</button>' +
      '</div>' +
      '<div class="divider"></div>' +
      '<div class="row"><div class="row__main"><div class="row__title">' + icon('archive', 16) + '全部配置</div><div class="row__sub">sing-box / mihomo / Sub-Store 数据打包</div></div>' +
      '<button class="btn btn--soft btn--sm" type="button" data-action="cfg.export"' + disableAttr() + '>导出</button></div>' +
      '<div class="hint">下载失败会自动尝试直连；单个配置的下载在编辑器工具栏。</div>' +
      '</section>';

    var about = aboutCard(s);
    root.innerHTML = '<div class="stack">' + errorBanner() + configCard + networkCard + localUiCard(s) + about + '</div>';
    bindEditorMeta();
  }

  function subSettingsInner(s, inSheet) {
    var sub = s.substore;
    var form = state.forms.sub;
    var health = sub.health ? '' : '<div class="banner banner--bad" style="margin-bottom:12px">' + icon('alert') +
      '<div class="banner__body"><div class="banner__title">运行环境未就绪</div><div>' + escapeHTML(sub.health_reason || '缺少组件') + '</div>' +
      '<button class="btn btn--sm btn--soft" type="button" data-action="sub.install"' + disableAttr() + '>一键安装</button></div></div>';

    var modeSeg = '<div class="seg seg--fill"><button type="button" class="' + (form.merge ? 'is-active' : '') + '" data-action="sub.mode" data-mode="true">合并端口</button>' +
      '<button type="button" class="' + (!form.merge ? 'is-active' : '') + '" data-action="sub.mode" data-mode="false">前后端分离</button></div>';
    var hostSeg = '<div class="seg seg--fill"><button type="button" class="' + (form.host === '127.0.0.1' ? 'is-active' : '') + '" data-action="sub.host" data-host="127.0.0.1">仅本机</button>' +
      '<button type="button" class="' + (form.host === '0.0.0.0' ? 'is-active' : '') + '" data-action="sub.host" data-host="0.0.0.0">局域网</button></div>';

    var lanWarn = form.host === '0.0.0.0' ? '<div class="banner banner--info" style="margin-top:12px">' + icon('alert') +
      '<div class="banner__body"><div class="banner__title">局域网可访问</div><div>请确保访问路径足够随机；不要在不可信网络下暴露 Sub-Store。</div></div></div>' : '';

    var head = inSheet ? '<div style="margin-bottom:10px">' + pill(subStatusText(sub), subStatusTone(sub)) + '</div>' + health
      : '<div class="card__head"><div><div class="card__title">' + icon('layers', 18) + 'Sub-Store 设置</div><div class="card__sub">修改后重启生效 · 端口与访问路径</div></div>' +
        '<div>' + pill(subStatusText(sub), subStatusTone(sub)) + '</div></div>' +
        '<div style="margin-top:12px">' + health + '</div>';
    return head +
      '<div class="field"><div class="field__label"><span>运行模式</span><span class="tiny dim">' + (form.merge ? '单端口同时提供前端与 API' : '前端 / 后端使用独立端口') + '</span></div>' + modeSeg + '</div>' +
      '<div class="field"><div class="field__label"><span>监听地址</span></div>' + hostSeg + '</div>' +
      '<div class="field-grid" style="margin-top:10px">' +
      '<div class="field"><div class="field__label"><span>后端端口</span></div><input class="input" id="sub-port" type="number" inputmode="numeric" min="1024" max="65535" value="' + escapeHTML(form.port) + '"></div>' +
      '<div class="field"><div class="field__label"><span>前端端口</span><span class="tiny dim">' + (form.merge ? '合并模式不使用' : '分离模式') + '</span></div><input class="input" id="sub-front-port" type="number" inputmode="numeric" min="1024" max="65535" value="' + escapeHTML(form.frontPort) + '"' + (form.merge ? ' disabled' : '') + '></div>' +
      '</div>' +
      '<div class="field"><div class="field__label"><span>访问路径</span><span class="tiny dim">随机隐藏 API</span></div>' +
      '<div class="urlbox"><span class="urlbox__icon">' + icon('lock', 16) + '</span><code>' + escapeHTML(sub.backend_path || '—') + '</code>' +
      '<button class="btn btn--ghost btn--sm" type="button" data-action="sub.regen"' + disableAttr() + '>重新生成</button></div></div>' +
      lanWarn +
      '<div class="cluster actions-grid actions-grid--2" style="margin-top:14px">' +
      '<button class="btn btn--primary" type="button" data-action="sub.save"' + disableAttr() + '>' + icon('save', 16) + '保存并重启</button>' +
      '<button class="btn btn--ghost" type="button" data-action="sub.open">' + icon('external', 16) + '打开 Sub-Store</button>' +
      '</div>' +
      '<div class="hint">访问路径被修改后，旧的 Sub-Store 页面会立即失效，需要重新打开。</div>';
  }

  function openSubSettingsSheet() {
    if (!state.status) return;
    openSheet({
      type: 'sub-settings',
      title: 'Sub-Store 设置',
      sub: '运行模式 · 监听地址 · 端口',
      body: '<div id="sheet-sub-settings">' + subSettingsInner(state.status, true) + '</div>',
      actions: [{ label: '关闭', action: 'sheet.close', cls: 'btn--ghost' }]
    });
  }

  function localUiCard(s) {
    var ui = s.ui || {};
    function panelRow(key) {
      var meta = UI_META[key];
      var item = ui[key] || {};
      var installed = !!item.installed;
      var path = item.path || (DATA_DIR + '/' + meta.rel);
      return '<div class="row ui-row">' +
        '<div class="row__main"><div class="row__title">' + icon(meta.icon, 16) + escapeHTML(meta.name) + '</div>' +
        '<div class="row__sub ui-row__meta"><span class="inline-code ui-row__core">' + escapeHTML(meta.core) + '</span><span class="inline-code ui-row__path">' + escapeHTML(meta.rel) + '</span></div></div>' +
        '<div class="row__side ui-row__actions">' +
        pill(installed ? '已下载' : '未下载', installed ? 'ok' : '', false) +
        '<button class="btn btn--soft btn--sm" type="button" aria-label="' + (installed ? '更新 ' : '下载 ') + escapeHTML(meta.name) + '" data-action="ui.update" data-ui="' + key + '"' + disableAttr() + '>' + icon('download', 14) + '<span class="ui-action-label">' + (installed ? '更新' : '下载') + '</span></button>' +
        (installed ? '<button class="btn btn--danger btn--sm" type="button" aria-label="删除 ' + escapeHTML(meta.name) + '" data-action="ui.delete" data-ui="' + key + '"' + disableAttr() + '>' + icon('trash', 14) + '<span class="ui-action-label">删除</span></button>' : '') +
        '</div></div>';
    }
    return '<section class="card" id="local-ui-card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('grid', 18) + '本地 UI 面板</div><div class="card__sub">下载到各内核目录 · 下载前确认</div></div></div>' +
      '<div style="margin-top:6px">' + panelRow('dashboard') + panelRow('zashboard') + '</div>' +
      '<div class="divider"></div>' +
      '<div class="row"><div class="row__main"><div class="row__title">' + icon('trash', 16) + '清空内核目录</div><div class="row__sub">只保留 config.json / config.yaml；删除 cache.db、ui/、rules/、.bak 等</div></div>' +
      '<button class="btn btn--danger btn--sm" type="button" data-action="ui.clear"' + disableAttr() + '>' + icon('trash', 14) + '清空</button></div>' +
      '<div class="hint">清空只保留 config.json / config.yaml；内核和 run 日志不受影响。</div>' +
      '</section>';
  }

  function aboutCard(s) {
    var system = 'Android ' + (s.device.android || '—') + ' · API ' + (s.device.sdk || '—');
    var items = [
      ['模块版本', s.module.version || '—'],
      ['设备', s.device.model || '未知'],
      ['系统', system],
      ['管理器', s.device.manager || 'Unknown'],
      ['ABI', s.device.abi || '—'],
      ['内核', s.device.kernel || '—']
    ];
    var grid = '<div class="about-grid">' + items.map(function (it) {
      return '<div class="about-item"><div class="about-item__k">' + escapeHTML(it[0]) + '</div><div class="about-item__v">' + escapeHTML(it[1]) + '</div></div>';
    }).join('') + '</div>';
    return '<section class="card">' +
      '<div class="card__head"><div><div class="card__title">' + icon('info', 18) + '关于</div><div class="card__sub">Android Nakedcore · 一站式裸核运行时</div></div></div>' +
      grid +
      '<div class="divider"></div>' +
      '<div class="about-links">' +
      '<button class="about-link" type="button" data-action="open.link" data-url="https://github.com/sub-store-org/Sub-Store">' + icon('layers', 14) + 'Sub-Store</button>' +
      '<button class="about-link" type="button" data-action="open.link" data-url="https://github.com/SagerNet/sing-box">' + icon('cube', 14) + 'sing-box</button>' +
      '<button class="about-link" type="button" data-action="open.link" data-url="https://github.com/MetaCubeX/mihomo">' + icon('cat', 14) + 'mihomo</button>' +
      '<button class="about-link" type="button" data-action="open.link" data-url="https://kernelsu.org/">' + icon('shield', 14) + 'KernelSU</button>' +
      '</div>' +
      '<div class="hint">配置数据保存在 <span class="inline-code">/data/adb/nakedcore</span>。卸载模块默认保留配置。</div>' +
      '<div class="hint">GPL-3.0 · 组件版权归各自作者所有。</div>' +
      '</section>';
  }

  // ----------------------------------------------------------
  // 连通性测试
  // ----------------------------------------------------------
  function connCategoryLabel(cat) {
    return CONN_CATEGORY_LABELS[cat] || cat || '其他';
  }

  function connTone(status) {
    if (status === 'available') return 'ok';
    if (status === 'restricted' || status === 'disallowed-isp' || status === 'blocked' ||
        status === 'unsupported-region' || status === 'originals-only' || status === 'coming-soon') return 'warn';
    if (status === 'unavailable' || status === 'timeout' || status === 'failed') return 'bad';
    return 'neutral';
  }

  function connStatusText(result) {
    if (!result) return '未测试';
    if (result.label) return result.label;
    var labels = {
      available: '可用',
      restricted: '访问受限',
      'disallowed-isp': '不允许的 ISP',
      blocked: '已被封禁',
      'unsupported-region': '地区不支持',
      'originals-only': '仅限自制内容',
      'coming-soon': '即将上线',
      unavailable: '不可用',
      timeout: '超时',
      failed: '检测失败'
    };
    return labels[result.status] || '检测失败';
  }

  function connColorStyle(item) {
    var color = String(item && item.color || '');
    if (!/^#[0-9a-f]{3,8}$/i.test(color)) color = '#64748b';
    return 'background:' + color + '1a;color:' + color + ';';
  }

  function connMetric(result) {
    if (!result) return '尚未测试';
    // 失败时优先给出人能看懂的诊断，而不是裸 curl 报错
    if ((result.status === 'failed' || result.status === 'timeout' || result.status === 'unavailable') && result.hint) {
      return result.hint;
    }
    var parts = [];
    if (result.region) parts.push(result.region);
    if (result.latency_ms) parts.push(result.latency_ms + ' ms');
    if (result.http) parts.push('HTTP ' + result.http);
    if (parts.length) return parts.join(' · ');
    return result.hint || result.error || '无响应';
  }

  function connCounts() {
    var counts = { done: 0, restricted: 0, bad: 0, untested: 0 };
    (state.conn.items || []).forEach(function (item) {
      var result = state.conn.results[item.id];
      if (!result) {
        counts.untested++;
      } else if (result.status === 'available') {
        counts.done++;
      } else if (result.status === 'restricted' || result.status === 'disallowed-isp' ||
                 result.status === 'blocked' || result.status === 'unsupported-region' ||
                 result.status === 'originals-only' || result.status === 'coming-soon') {
        counts.restricted++;
      } else {
        counts.bad++;
      }
    });
    return counts;
  }

  function connContextNote(c) {
    var ctx = c.context;
    if (!ctx) return '';
    if (!ctx.running) {
      return '<div class="conn-note conn-note--warn">' + icon('alert', 16) +
        '<div><strong>' + escapeHTML(ctx.core || '内核') + ' 未运行</strong>，以下是直连网络的检测结果，不代表代理可用性。</div></div>';
    }
    if (!ctx.tun) {
      return '<div class="conn-note">' + icon('info', 16) +
        '<div>内核在运行，但没有检测到 TUN 接口，部分结果可能来自直连。</div></div>';
    }
    return '';
  }

  function connRow(item) {
    var result = state.conn.results[item.id];
    var probing = !!state.conn.probing[item.id];
    var status = probing ? 'probing' : (result && result.status) || 'untested';
    var tone = probing ? 'neutral' : connTone(status);
    var label = probing ? '测试中' : connStatusText(result);
    var disabled = disableAttr();
    return '<div class="conn-row">' +
      '<span class="conn-logo" style="' + connColorStyle(item) + '"><b>' + escapeHTML(item.abbr || item.name.slice(0, 2)) + '</b></span>' +
      '<div class="conn-main"><div class="conn-name">' + escapeHTML(item.name) + '</div>' +
      '<div class="conn-metrics">' + (probing ? '<span class="spinner spinner--xs"></span> 正在探测…' : escapeHTML(connMetric(result))) + '</div></div>' +
      '<div class="conn-side"><span class="pill pill--' + tone + '">' + (probing ? '<span class="spinner spinner--xs"></span>' : '') + escapeHTML(label) + '</span>' +
      '<button class="conn-icon" type="button" data-action="conn.detail" data-id="' + escapeHTML(item.id) + '" aria-label="查看 ' + escapeHTML(item.name) + ' 详情">' + icon('info', 15) + '</button>' +
      '<button class="conn-icon" type="button" data-action="conn.refresh" data-id="' + escapeHTML(item.id) + '" aria-label="重新测试 ' + escapeHTML(item.name) + '"' + (probing ? ' disabled' : disabled) + '>' + icon('refresh', 15) + '</button></div></div>';
  }

  function renderConnectivity() {
    var root = $('#connectivity-body');
    if (!root) return;
    var c = state.conn;
    var counts = connCounts();
    var testing = taskRunning() && state.task && state.task.label === '连通性测试';
    var head = '<div class="section-head conn-head"><div><h2>连通性测试</h2><p>按真实页面内容与地区字段检测服务状态</p></div>' +
      '<div class="conn-head__actions"><button class="btn btn--soft btn--sm" type="button" data-action="conn.reload"' + disableAttr() + '>' + icon('refresh', 14) + '刷新</button>' +
      '<button class="btn btn--primary btn--sm" type="button" data-action="conn.test"' + disableAttr() + '>' + icon('play', 14) + (testing ? '测试中…' : '全部测试') + '</button></div></div>';

    var summary = '<div class="conn-summary">' +
      '<div class="conn-stat conn-stat--ok"><strong>' + counts.done + '</strong><span>可用</span></div>' +
      '<div class="conn-stat conn-stat--warn"><strong>' + counts.restricted + '</strong><span>受限</span></div>' +
      '<div class="conn-stat conn-stat--bad"><strong>' + counts.bad + '</strong><span>异常</span></div>' +
      '<div class="conn-stat conn-stat--idle"><strong>' + counts.untested + '</strong><span>未测</span></div>' +
      '</div>';

    var filters = '<div class="conn-filters" role="tablist" aria-label="连通性分类">' + CONN_CATEGORIES.map(function (it) {
      return '<button class="conn-filter' + (c.filter === it[0] ? ' is-active' : '') + '" type="button" role="tab" aria-selected="' + (c.filter === it[0] ? 'true' : 'false') + '" data-action="conn.filter" data-filter="' + it[0] + '">' + escapeHTML(it[1]) + '</button>';
    }).join('') + '</div>';

    var note = connContextNote(c);
    if (testing) {
      note += '<div class="conn-running"><span class="spinner"></span><span>正在测试全部服务，结果会在完成后写入。</span></div>';
    } else if (c.testedAt) {
      note += '<div class="conn-tested">最近测试 ' + escapeHTML(fmtTime(c.testedAt)) + '</div>';
    }

    var body;
    if (c.loading && !c.loaded) {
      body = '<div class="card conn-loading"><div class="skeleton skeleton--line"></div><div class="skeleton skeleton--line"></div><div class="skeleton skeleton--line"></div></div>';
    } else if (c.error && !c.items.length) {
      body = '<div class="card conn-empty">' + icon('alert', 24) + '<div class="conn-empty__title">无法读取服务列表</div><div class="conn-empty__text">' + escapeHTML(c.error) + '</div><button class="btn btn--soft btn--sm" type="button" data-action="conn.reload">重试</button></div>';
    } else if (!c.items.length) {
      body = '<div class="card conn-empty">' + icon('radar', 24) + '<div class="conn-empty__title">暂无服务</div><div class="conn-empty__text">首次加载完成后可开始检测。</div></div>';
    } else {
      var list = c.filter === 'all' ? c.items : c.items.filter(function (item) { return item.category === c.filter; });
      if (!list.length) {
        body = '<div class="conn-empty conn-empty--plain">该分类暂无服务</div>';
      } else {
        var groups = {};
        var order = [];
        list.forEach(function (item) {
          var cat = item.category || 'other';
          if (!groups[cat]) { groups[cat] = []; order.push(cat); }
          groups[cat].push(item);
        });
        body = '<div class="conn-groups">' + order.map(function (cat) {
          return '<div class="conn-group"><div class="conn-group__label">' + escapeHTML(connCategoryLabel(cat)) + '<span>' + groups[cat].length + '</span></div>' +
            groups[cat].map(connRow).join('') + '</div>';
        }).join('') + '</div>';
      }
    }

    root.innerHTML = '<section class="conn-page">' + head + summary + filters + note + body +
      '<div class="hint conn-hint">状态参考 FlClash 服务状态规则，通过真实页面 / API 内容判断；流媒体结果不保证账号权益或内容版权可用。</div></section>';
  }

  async function loadConnectivity(force) {
    var c = state.conn;
    if (c.loading) return;
    if (c.loaded && !force) return;
    c.loading = true;
    c.error = '';
    if (state.page === 'connectivity') renderConnectivity();
    try {
      var listRes = await runCli(['connectivity', 'list']);
      if (!listRes.ok) throw new Error(firstLine(listRes.stderr || listRes.stdout) || '读取服务列表失败');
      var list = parseJSON(listRes.stdout);
      var results = { tested_at: 0, region: '', results: {} };
      var resultsRes = await runCli(['connectivity', 'results']);
      if (resultsRes.ok) {
        try { results = parseJSON(resultsRes.stdout); } catch (e) { /* keep empty */ }
      }
      c.items = Array.isArray(list) ? list : [];
      c.results = results.results || {};
      c.context = results.context || null;
      c.region = results.region || '';
      c.testedAt = Number(results.tested_at) || 0;
      c.loaded = true;
    } catch (e) {
      c.error = e && e.message ? e.message : String(e);
    } finally {
      c.loading = false;
      if (state.page === 'connectivity') renderConnectivity();
    }
  }

  async function testConnectivity() {
    if (state.busy || taskRunning()) return;
    if (!state.conn.loaded) await loadConnectivity();
    await startTask('连通性测试', ['connectivity', 'test'], function () {
      loadConnectivity(true);
    });
  }

  async function refreshConnectivity(id) {
    var item = (state.conn.items || []).filter(function (x) { return x.id === id; })[0];
    if (!item || state.conn.probing[id] || taskRunning()) return;
    state.conn.probing[id] = true;
    if (state.page === 'connectivity') renderConnectivity();
    try {
      var res = await runCli(['connectivity', 'probe', id]);
      if (!res.ok) throw new Error(firstLine(res.stderr || res.stdout) || '测试失败');
      state.conn.results[id] = parseJSON(res.stdout);
      state.conn.testedAt = Math.floor(Date.now() / 1000);
      toast(item.name + '：' + connStatusText(state.conn.results[id]), 'ok', 1800);
    } catch (e) {
      toast(e.message || '连通性测试失败', 'err');
    } finally {
      delete state.conn.probing[id];
      if (state.page === 'connectivity') renderConnectivity();
    }
  }

  function openConnDetail(id) {
    var item = (state.conn.items || []).filter(function (x) { return x.id === id; })[0];
    if (!item) return;
    var result = state.conn.results[id];
    var rows = [
      ['状态', connStatusText(result)],
      ['分类', connCategoryLabel(item.category)],
      ['地址', item.url],
      ['出口', result && result.region ? result.region : '—'],
      ['延迟', result && result.latency_ms ? result.latency_ms + ' ms' : '—'],
      ['HTTP', result && result.http ? String(result.http) : '—'],
      ['测试时间', result && result.tested_at ? fmtTime(result.tested_at) : '—']
    ];
    if (result && result.hint) rows.push(['诊断', result.hint]);
    var body = '<div class="conn-detail">' + rows.map(function (row) {
      return '<div class="conn-detail__row"><span>' + escapeHTML(row[0]) + '</span><strong' + (row[0] === '地址' ? ' class="inline-code"' : '') + '>' + escapeHTML(row[1]) + '</strong></div>';
    }).join('') + (result && result.error ? '<div class="conn-detail__error">' + escapeHTML(result.error) + '</div>' : '') +
      '<button class="btn btn--soft btn--sm btn--block" type="button" data-action="conn.refresh" data-id="' + escapeHTML(id) + '"' + disableAttr() + '>' + icon('refresh', 14) + '重新测试</button></div>';
    openSheet({ type: 'conn-detail', title: item.name, sub: connCategoryLabel(item.category), body: body, actions: [{ label: '关闭', action: 'sheet.close', cls: 'btn--ghost' }] });
  }

  function updateConfigDynamic() {
    if (state.page !== 'config' || !state.status) return;
    var s = state.status;
    var target = state.config.target;
    var sizeEl = $('#cfg-file-size');
    if (sizeEl) sizeEl.textContent = humanSize(utf8Length(state.config.content));
    var stateEl = $('#cfg-file-state');
    if (stateEl) {
      var badge;
      if (state.config.dirty) badge = pill('未保存', 'warn');
      else if (target === 'substore') badge = s.substore.dirty ? pill('已修改', 'warn') : pill('已保存', 'ok');
      else {
        var core = target === 'singbox' ? s.cores['sing-box'] : s.cores.mihomo;
        badge = configBadge(core.config_state);
      }
      stateEl.innerHTML = badge + ' · <span id="cfg-file-size">' + humanSize(utf8Length(state.config.content)) + '</span>';
    }
    var proxy = $('#proxy-input');
    if (proxy && !state.forms.proxyDirty && document.activeElement !== proxy) proxy.value = s.settings.gh_proxy || '';
    syncFormsFromStatus();
    var uiCard = $('#local-ui-card');
    if (uiCard && s) uiCard.outerHTML = localUiCard(s);
  }

  function bindEditorMeta() {
    // 占位：编辑器元信息在 input 事件中即时更新
  }

  function updateEditorMeta() {
    var ta = $('#cfg-editor');
    if (!ta) return;
    var content = ta.value;
    var lines = content ? content.split('\n').length : 0;
    var linesEl = $('#cfg-lines');
    var charsEl = $('#cfg-chars');
    var fileSizeEl = $('#cfg-file-size');
    var stateEl = $('#cfg-save-state');
    var saveBtn = $('#cfg-save-btn');
    var revertBtn = $('#cfg-revert-btn');
    if (linesEl) linesEl.textContent = lines + ' 行';
    if (charsEl) charsEl.textContent = content.length + ' 字符';
    if (fileSizeEl) fileSizeEl.textContent = humanSize(utf8Length(content));
    if (stateEl) {
      stateEl.textContent = state.config.dirty ? '已修改' : '已保存';
      stateEl.className = state.config.dirty ? 'dirty' : 'saved';
    }
    if (saveBtn) saveBtn.disabled = !state.config.dirty || !!state.busy || taskRunning();
    if (revertBtn) revertBtn.disabled = !state.config.dirty || !!state.busy;
  }

  async function loadConfig(target) {
    if (state.config.loading) return;
    state.config.target = target;
    state.config.loading = true;
    state.config.content = '';
    state.config.original = '';
    state.config.dirty = false;
    renderConfigPage();
    try {
      var res = await runCli(['cfg', 'get', target], { trim: false });
      if (!res.ok) throw new Error(firstLine(res.stderr || res.stdout) || '读取配置失败');
      state.config.content = res.stdout;
      state.config.original = res.stdout;
      state.config.dirty = false;
    } catch (e) {
      toast(e.message || '读取配置失败', 'err');
    } finally {
      state.config.loading = false;
      renderConfigPage();
    }
  }

  async function saveConfig() {
    if (state.busy) return;
    if (taskRunning()) {
      toast('请等待当前任务结束', 'err');
      return;
    }
    var target = state.config.target;
    var content = state.config.content;
    var bytes = window.TextEncoder ? new TextEncoder().encode(content) : null;
    if (!content) {
      toast('配置内容为空', 'err');
      return;
    }
    var chunkSize = 12000;
    var total = bytes ? Math.ceil(bytes.length / chunkSize) : Math.ceil(content.length / chunkSize);
    state.busy = '保存配置';
    updateEditorMeta();
    renderConsole();
    try {
      await runCli(['cfg', 'reset', target]);
      for (var i = 0; i < total; i++) {
        var b64;
        if (bytes) b64 = bytesToB64(bytes.subarray(i * chunkSize, Math.min((i + 1) * chunkSize, bytes.length)));
        else b64 = textToB64(content.slice(i * chunkSize, (i + 1) * chunkSize));
        var put = await runCli(['cfg', 'put', target, String(i), b64]);
        if (!put.ok) throw new Error(firstLine(put.stderr || put.stdout) || '上传分块失败');
        state.busy = '保存配置 ' + (i + 1) + '/' + total;
        renderConsole();
      }
      var commit = await runCli(['cfg', 'commit', target, '0']);
      if (!commit.ok) {
        var force = await confirmSheet({
          title: '配置校验未通过',
          message: '校验输出：<br><strong>' + escapeHTML(firstLine(commit.stderr || commit.stdout) || '未知错误') + '</strong><br><br>仍然保存可能导致内核无法启动，确定继续吗？',
          confirmText: '仍然保存',
          danger: true
        });
        if (!force) {
          toast('已取消保存', 'info');
          return;
        }
        commit = await runCli(['cfg', 'commit', target, '1']);
        if (!commit.ok) throw new Error(firstLine(commit.stderr || commit.stdout) || '保存失败');
      }
      state.config.original = content;
      state.config.dirty = false;
      state.lastOutput = firstLine(commit.stderr || commit.stdout) || '配置已保存';
      state.lastLabel = '保存配置';
      state.lastAt = Math.floor(Date.now() / 1000);
      toast('配置已保存' + (target === 'substore' ? '，重启 Sub-Store 后生效' : '，重启内核后生效'), 'ok');
      await refreshStatus();
      state.forms.sub.dirty = false;
      renderConfigPage();
    } catch (e) {
      toast(e.message || '保存失败', 'err');
    } finally {
      state.busy = '';
      updateEditorMeta();
      renderConsole();
    }
  }

  // ----------------------------------------------------------
  // 运行日志 / 终端
  // ----------------------------------------------------------
  function lastLogLine(log) {
    var lines = String(log || '').split('\n').map(function (l) { return l.trim(); }).filter(Boolean);
    var line = lines.length ? lines[lines.length - 1] : '';
    return line.length > 150 ? line.slice(0, 150) + '…' : line;
  }

  function colorizeLog(log) {
    return String(log || '').split('\n').map(function (line) {
      var cls = '';
      if (/\[(Error|错误)\]|error:|failed/i.test(line)) cls = 'logline--err';
      else if (/\[Warn\]|warning:/i.test(line)) cls = 'logline--warn';
      else if (/\[Info\]|success|ok\b/i.test(line)) cls = 'logline--info';
      else if (/^\s*$/.test(line)) cls = 'logline--dim';
      return '<div class="' + cls + '">' + escapeHTML(line || ' ') + '</div>';
    }).join('');
  }

  function renderConsole() {
    var bar = $('#console');
    if (!bar) return;
    var failed = !!(state.task && ['failed', 'cancelled', 'error'].indexOf(state.task.state) >= 0);
    var visible = !!state.busy || taskRunning() || failed;
    bar.classList.toggle('is-visible', visible);
    var app = $('#app');
    if (app) app.classList.toggle('console-active', visible);
    var dot = $('#console-dot');
    var iconEl = $('#console-icon');
    var textEl = $('#console-text');
    var metaEl = $('#console-meta');
    var chev = $('#console-chevron');
    bar.classList.remove('is-running', 'is-ok', 'is-error');
    if (state.busy) {
      bar.classList.add('is-running');
      if (textEl) textEl.textContent = state.busy + '…';
      if (metaEl) metaEl.textContent = '';
      if (iconEl) iconEl.innerHTML = '<span class="spinner"></span>';
      if (chev) chev.innerHTML = icon('chevron', 16);
    } else if (state.task) {
      var t = state.task;
      var stateName = t.state || 'running';
      if (stateName === 'running') {
        bar.classList.add('is-running');
        if (textEl) textEl.textContent = lastLogLine(t.log) || t.label || '正在执行…';
        if (metaEl) metaEl.textContent = t.started ? fmtElapsed(Math.floor(Date.now() / 1000) - t.started) : '';
        if (iconEl) iconEl.innerHTML = '<span class="spinner"></span>';
      } else if (stateName === 'success') {
        bar.classList.add('is-ok');
        if (textEl) textEl.textContent = '完成 · ' + (t.label || '任务');
        if (metaEl) metaEl.textContent = t.elapsed != null ? fmtElapsed(t.elapsed) : '';
        if (iconEl) iconEl.innerHTML = icon('check', 17);
      } else if (stateName === 'cancelled') {
        bar.classList.add('is-error');
        if (textEl) textEl.textContent = '已取消 · ' + (t.label || '任务');
        if (metaEl) metaEl.textContent = '';
        if (iconEl) iconEl.innerHTML = icon('x', 17);
      } else {
        bar.classList.add('is-error');
        if (textEl) textEl.textContent = '失败 · ' + (t.label || '任务');
        if (metaEl) metaEl.textContent = t.code != null ? 'exit ' + t.code : '';
        if (iconEl) iconEl.innerHTML = icon('alert', 17);
      }
      if (chev) chev.innerHTML = icon('chevron', 16);
    } else {
      if (textEl) textEl.textContent = state.lastLabel ? '空闲 · 上次：' + state.lastLabel : '等待指令执行';
      if (metaEl) metaEl.textContent = state.lastAt ? fmtTime(state.lastAt) : '';
      if (iconEl) iconEl.innerHTML = icon('terminal', 17);
      if (chev) chev.innerHTML = icon('chevron', 16);
    }
    if (state.sheet && state.sheet.type === 'console' && (!state.sheet.consoleView || state.sheet.consoleView === 'task')) {
      var logEl = $('#sheet-log');
      if (logEl) {
        var log = state.task ? state.task.log : state.lastOutput;
        logEl.innerHTML = colorizeLog(log || '（暂无输出）');
        logEl.scrollTop = logEl.scrollHeight;
      }
      var sub = $('#sheet-log-sub');
      if (sub) sub.textContent = state.task && state.task.label ? state.task.label : (state.lastLabel || '最近任务输出');
    }
  }

  var CONSOLE_VIEWS = [
    ['task', '任务输出'],
    ['singbox', 'sing-box'],
    ['mihomo', 'mihomo'],
    ['substore', 'Sub-Store'],
    ['wifi', 'Wi-Fi'],
    ['hotspot', '热点'],
    ['boot', '开机']
  ];

  function consoleTabsHTML(view) {
    return '<div class="seg console-tabs" role="tablist">' + CONSOLE_VIEWS.map(function (v) {
      return '<button type="button" class="console-tab' + (v[0] === view ? ' is-active' : '') + '" role="tab" aria-selected="' + (v[0] === view ? 'true' : 'false') + '" data-action="console.view" data-view="' + v[0] + '">' + escapeHTML(v[1]) + '</button>';
    }).join('') + '</div>';
  }

  function consoleTaskText() {
    return state.task ? state.task.log : state.lastOutput;
  }

  function openConsoleSheet(view) {
    view = view || 'task';
    var taskText = consoleTaskText();
    var body = consoleTabsHTML(view) +
      '<div class="logbox logbox--console" id="sheet-log">' +
      (view === 'task' ? colorizeLog(taskText || '（暂无输出）') : '<span class="spinner"></span> 读取中…') +
      '</div>';
    var actions = [{ label: '复制', action: 'console.copy', cls: 'btn--soft' }];
    if (taskRunning()) actions.push({ label: '停止任务', action: 'console.cancel', cls: 'btn--danger' });
    actions.push({ label: '关闭', action: 'sheet.close', cls: 'btn--ghost' });
    openSheet({
      type: 'console',
      title: '运行与日志',
      sub: view === 'task' ? (state.task && state.task.label ? state.task.label : (state.lastLabel || '最近任务输出')) : view,
      body: body,
      actions: actions,
      consoleView: view,
      logName: view === 'task' ? null : view
    });
    if (view !== 'task') loadLogInto(view);
  }

  function switchConsoleView(view) {
    if (!state.sheet || state.sheet.type !== 'console') return;
    state.sheet.consoleView = view;
    state.sheet.logName = view === 'task' ? null : view;
    $$('.console-tab').forEach(function (tab) {
      var active = tab.dataset.view === view;
      tab.classList.toggle('is-active', active);
      tab.setAttribute('aria-selected', active ? 'true' : 'false');
    });
    var sub = $('#sheet-log-sub');
    if (sub) sub.textContent = view === 'task' ? (state.task && state.task.label ? state.task.label : (state.lastLabel || '最近任务输出')) : (CONSOLE_VIEWS.filter(function (v) { return v[0] === view; })[0] || ['', view])[1];
    var logEl = $('#sheet-log');
    if (view === 'task') {
      if (logEl) {
        logEl.innerHTML = colorizeLog(consoleTaskText() || '（暂无输出）');
        logEl.scrollTop = logEl.scrollHeight;
      }
    } else {
      loadLogInto(view);
    }
  }

  async function openLogSheet(name) {
    var titles = { singbox: 'sing-box 日志', 'sing-box': 'sing-box 日志', mihomo: 'mihomo 日志', substore: 'Sub-Store 日志', wifi: 'Wi-Fi 守护日志', hotspot: '热点共享日志', boot: '开机日志' };
    openSheet({
      type: 'log',
      title: titles[name] || '服务日志',
      sub: '最近 300 行',
      body: '<div class="logbox" id="sheet-log">加载中…</div>',
      actions: [
        { label: '刷新', action: 'log.refresh', cls: 'btn--soft' },
        { label: '复制', action: 'log.copy', cls: 'btn--ghost' },
        { label: '清空', action: 'log.clear', cls: 'btn--danger' },
        { label: '关闭', action: 'sheet.close', cls: 'btn--ghost' }
      ],
      logName: name
    });
    await loadLogInto(name);
  }

  async function loadLogInto(name) {
    var el = $('#sheet-log');
    if (el) el.innerHTML = '<span class="spinner"></span> 读取中…';
    try {
      var res = await runCli(['log', name, '300'], { trim: false });
      var log = res.ok ? res.stdout : (res.stderr || res.stdout);
      if (el) {
        el.innerHTML = colorizeLog(log || '（日志为空）');
        el.scrollTop = el.scrollHeight;
      }
    } catch (e) {
      if (el) el.innerHTML = colorizeLog(e.message || '读取失败');
    }
  }

  async function clearLog(name) {
    var ok = await confirmSheet({
      title: '清空日志',
      message: '确定清空 <strong>' + escapeHTML(name) + '</strong> 的服务日志吗？正在运行的服务会继续写入新日志。',
      confirmText: '清空',
      danger: true
    });
    if (!ok) return;
    var res = await runCli(['log', 'clear', name]);
    if (!res.ok) {
      toast(firstLine(res.stderr || res.stdout) || '清空失败', 'err');
      return;
    }
    toast('日志已清空', 'ok');
    openLogSheet(name);
  }

  function clearConsoleLog() {
    confirmSheet({
      title: '清空运行日志',
      message: '仅清空当前终端视图中的输出；正在执行的任务会继续写入新日志。',
      confirmText: '清空',
      danger: false
    }).then(function (ok) {
      if (!ok) return;
      if (state.task) state.task.log = '';
      state.lastOutput = '';
      renderConsole();
      openConsoleSheet();
    });
  }

  // ----------------------------------------------------------
  // 任务
  // ----------------------------------------------------------
  function taskLabel(args) {
    var a = args.join(' ');
    if (/^core start/.test(a)) return '启动内核';
    if (/^core stop/.test(a)) return '停止内核';
    if (/^core restart/.test(a)) return '重启内核';
    if (/^core switch/.test(a)) return '切换内核';
    if (/^core update/.test(a)) return '更新内核';
    if (/^core rollback/.test(a)) return '回滚内核';
    if (/^core check/.test(a)) return '校验内核配置';
    if (/^core delete/.test(a)) return '删除内核';
    if (/^sub update/.test(a)) return '更新 Sub-Store';
    if (/^sub restart/.test(a)) return '重启 Sub-Store';
    if (/^sub start/.test(a)) return '启动 Sub-Store';
    if (/^sub stop/.test(a)) return '停止 Sub-Store';
    if (/^sub regen-path/.test(a)) return '生成访问路径';
    if (/^cfg fetch/.test(a)) return '拉取配置';
    if (/^cfg export/.test(a)) return '导出配置';
    if (/^ui update/.test(a)) return '下载本地 UI';
    if (/^ui delete/.test(a)) return '删除本地 UI';
    if (/^ui clear/.test(a)) return '清空内核目录';
    if (/^all update/.test(a)) return '一键更新';
    if (/^checkup/.test(a)) return '检查更新';
    if (/^connectivity test/.test(a)) return '连通性测试';
    if (/^connectivity probe/.test(a)) return '连通性测试';
    return '执行任务';
  }

  async function startTask(label, args, onSuccess, onFailure) {
    if (taskRunning()) {
      toast('已有任务正在执行', 'err');
      return false;
    }
    state.task = { id: '', state: 'running', label: label || taskLabel(args), log: '', started: Math.floor(Date.now() / 1000) };
    state.lastLabel = state.task.label;
    renderConsole();
    if (state.page !== 'config') renderPage();
    try {
      var res = await runCli(['task', 'start'].concat(args));
      if (!res.ok) throw new Error(firstLine(res.stderr || res.stdout) || '任务启动失败');
      var data = parseJSON(res.stdout);
      state.task.id = data.id;
      if (data.label) state.task.label = data.label;
      pollTask(data.id, onSuccess, onFailure);
      return true;
    } catch (e) {
      state.task = { id: '', state: 'failed', label: label || taskLabel(args), log: String(e.message || e), started: Math.floor(Date.now() / 1000) };
      state.lastOutput = String(e.message || e);
      renderConsole();
      if (state.page !== 'config') renderPage();
      toast(e.message || '任务启动失败', 'err');
      return false;
    }
  }

  function pollTask(id, onSuccess, onFailure) {
    if (state.taskTimer) clearTimeout(state.taskTimer);
    var loop = async function () {
      if (!state.task || state.task.id !== id) return;
      try {
        var res = await runCli(['task', 'status', id]);
        if (!res.ok) throw new Error(firstLine(res.stderr || res.stdout) || '读取任务状态失败');
        var t = parseJSON(res.stdout);
        state.task = Object.assign({}, state.task, t);
        if (state.task.state === 'running') {
          state.taskTimer = setTimeout(loop, TASK_POLL_MS);
          renderConsole();
          if (state.page !== 'config') renderPage();
          return;
        }
        state.taskTimer = null;
        state.lastOutput = t.log || '';
        state.lastAt = Math.floor(Date.now() / 1000);
        renderConsole();
        if (state.page !== 'config') renderPage();
        await refreshStatus(false);
        refreshSubSettingsCard();
        if (t.state === 'success') {
          toast((t.label || '任务') + ' 完成', 'ok');
          if (typeof onSuccess === 'function') onSuccess(t);
        } else {
          toast((t.label || '任务') + ' 失败', 'err');
          if (typeof onFailure === 'function') onFailure(t);
        }
      } catch (e) {
        state.taskTimer = setTimeout(loop, 1200);
      }
    };
    loop();
  }

  async function cancelTask() {
    if (!state.task || !state.task.id) return;
    try {
      await runCli(['task', 'cancel', state.task.id]);
      state.task.state = 'cancelled';
      toast('任务已取消', 'info');
      closeSheet();
      renderConsole();
      if (state.page !== 'config') renderPage();
    } catch (e) {
      toast(e.message || '取消失败', 'err');
    }
  }

  // ----------------------------------------------------------
  // 操作
  // ----------------------------------------------------------
  async function startCore() {
    var s = state.status;
    if (!s) return;
    var id = s.settings.active_core;
    var core = s.cores[id];
    if (!core.installed) {
      toast('请先在核心页安装 ' + id, 'err');
      setPage('core');
      return;
    }
    if (core.config_state === 'fail') {
      toast('配置校验未通过，请先修复配置', 'err');
      setPage('config');
      return;
    }
    await startTask('启动 ' + id, ['core', 'start', id], function () {
      toast(id + ' 已启动', 'ok');
    });
  }

  async function stopCore() {
    var s = state.status;
    if (!s) return;
    var id = s.settings.active_core;
    var ok = await confirmSheet({
      title: '停止内核',
      message: '停止 <strong>' + escapeHTML(id) + '</strong> 后，设备代理将中断。确定继续吗？',
      confirmText: '停止',
      danger: true
    });
    if (!ok) return;
    await startTask('停止 ' + id, ['core', 'stop', id]);
  }

  async function restartCore() {
    var s = state.status;
    if (!s) return;
    var id = s.settings.active_core;
    await startTask('重启 ' + id, ['core', 'restart', id]);
  }

  async function switchCore(target) {
    if (!target) {
      var s = state.status;
      if (!s) return;
      var current = s.cores[s.settings.active_core];
      var currentRunning = !!(current && current.running);
      var rows = ['sing-box', 'mihomo'].filter(function (id) { return !!s.cores[id]; }).map(function (id) {
        var c = s.cores[id];
        var active = s.settings.active_core === id;
        var noConfigBlocked = currentRunning && c.config_state === 'none';
        var disabled = active || !c.installed || noConfigBlocked;
        var sub = (c.installed ? verLabel(c.version) : '未安装') + ' · ' + channelLabel(coreChannel(s, id));
        if (c.config_state === 'none') sub += ' · 无配置';
        if (noConfigBlocked) sub += '（需先导入配置）';
        return '<button class="row row--tap" type="button" data-action="core.switch.do" data-core="' + id + '" style="width:100%;text-align:left;background:none"' + (disabled ? ' disabled' : '') + '>' +
          coreLogo(id, 'light') +
          '<span class="row__main"><span class="row__title">' + escapeHTML(CORE_META[id].name) + (active ? ' ' + pill('当前', 'info', false) : '') + '</span><span class="row__sub">' + escapeHTML(sub) + '</span></span>' +
          '<span class="chev">' + icon('chevron', 17) + '</span></button>';
      }).join('');
      openSheet({
        title: '切换内核',
        sub: currentRunning ? '当前有内核在运行，切换会短暂中断代理' : '当前没有内核在运行，切换只修改激活设置',
        body: '<div style="margin-top:6px">' + rows + '</div>',
        actions: [{ label: '取消', action: 'sheet.close', cls: 'btn--ghost' }]
      });
      return;
    }
    closeSheet();
    await startTask('切换到 ' + target, ['core', 'switch', target], function () {
      toast('已切换到 ' + target, 'ok');
    });
  }

  async function coreCheck(id) {
    if (!id) return;
    await startTask('校验 ' + id, ['core', 'check', id], function () {
      toast(id + ' 配置校验通过', 'ok');
    });
  }

  async function coreDelete(id) {
    var s = state.status;
    if (!s || !id || !s.cores[id]) return;
    var core = s.cores[id];
    var ok = await confirmSheet({
      title: '删除 ' + CORE_META[id].name,
      message: '将删除<strong>内核二进制、版本记录和回滚缓存</strong>；配置文件与日志会保留。' +
        (core.running ? '<br><br>内核正在运行，会先停止再删除。' : '') +
        '<br><br>删除后可以随时重新安装。',
      confirmText: '删除',
      danger: true
    });
    if (!ok) return;
    await startTask('删除 ' + id, ['core', 'delete', id], function () {
      toast('已删除 ' + id, 'ok');
    });
  }

  async function coreUpdate(id, channel) {
    var s = state.status;
    if (!s) return;
    var core = s.cores[id];
    var running = core.running;
    var ok = await confirmSheet({
      title: (core.installed ? '更新 ' : '安装 ') + id,
      message: '通道：<strong>' + escapeHTML(channelLabel(channel)) + '</strong>' +
        (running ? '<br><br>内核正在运行，更新过程会短暂停止并在完成后自动重启。' : '') +
        '<br><br>将从 GitHub 下载最新版本，网络不佳时请先在配置页设置加速地址。',
      confirmText: core.installed ? '更新' : '安装',
      danger: false
    });
    if (!ok) return;
    await startTask((core.installed ? '更新 ' : '安装 ') + id, ['core', 'update', id, channel], function () {
      toast(id + ' 更新完成', 'ok');
    });
  }

  async function coreRollback(id) {
    var ok = await confirmSheet({
      title: '回滚 ' + id,
      message: '将恢复上一次更新前的二进制。若当前内核正在运行，会先停止再启动旧版本。',
      confirmText: '回滚',
      danger: true
    });
    if (!ok) return;
    await startTask('回滚 ' + id, ['core', 'rollback', id]);
  }

  async function toggleCoreAutostart() {
    var s = state.status;
    if (!s) return;
    var target = !s.settings.auto_start;
    await runSync(target ? '开启内核自启' : '关闭内核自启', ['autostart', target ? 'true' : 'false'], { successToast: target ? '已开启内核自启' : '已关闭内核自启' });
  }

  async function toggleSubAutostart() {
    var s = state.status;
    if (!s) return;
    var target = !s.substore.autostart;
    await runSync(target ? '开启 Sub-Store 自启' : '关闭 Sub-Store 自启', ['sub', 'autostart', target ? 'true' : 'false'], { successToast: target ? '已开启 Sub-Store 自启' : '已关闭 Sub-Store 自启' });
  }

  async function toggleWifiGuard() {
    var s = state.status;
    if (!s || !s.wifi) return;
    var target = !s.wifi.guard;
    await runSync(target ? '开启 Wi-Fi 自动启停' : '关闭 Wi-Fi 自动启停', ['wifi', target ? 'enable' : 'disable'], {
      successToast: target ? 'Wi-Fi 自动启停已开启' : 'Wi-Fi 自动启停已关闭'
    });
  }

  async function addWifiSsid() {
    var input = $('#wifi-ssid-input');
    if (!input) return;
    var ssid = String(input.value || '').trim();
    if (!ssid) {
      toast('请输入 Wi-Fi 名称', 'err');
      input.focus();
      return;
    }
    await runSync('添加信任 Wi-Fi', ['wifi', 'add', textToB64(ssid)], { successToast: '已添加 ' + ssid });
  }

  async function removeWifiSsid(ssid) {
    if (!ssid) return;
    await runSync('移除信任 Wi-Fi', ['wifi', 'remove', textToB64(ssid)], { successToast: '已移除 ' + ssid });
  }

  async function checkWifi() {
    await runSync('检测 Wi-Fi', ['wifi', 'check'], { successToast: 'Wi-Fi 状态已刷新' });
  }

  async function resumeWifiGuard() {
    await runSync('恢复 Wi-Fi 自动逻辑', ['wifi', 'resume'], { successToast: '已恢复自动逻辑' });
  }

  async function runSync(label, args, opts) {
    opts = opts || {};
    if (state.busy) return false;
    if (taskRunning()) {
      toast('请等待当前任务结束', 'err');
      return false;
    }
    state.busy = label;
    state.lastLabel = label;
    renderConsole();
    if (state.page !== 'config') renderPage();
    try {
      var res = await runCli(args);
      if (!res.ok) {
        var msg = firstLine(res.stderr || res.stdout) || (label + '失败');
        state.lastOutput = msg;
        state.lastAt = Math.floor(Date.now() / 1000);
        toast(msg, 'err');
        return false;
      }
      state.lastOutput = firstLine(res.stdout || res.stderr) || label + '完成';
      state.lastAt = Math.floor(Date.now() / 1000);
      await refreshStatus(false);
      if (opts.successToast !== false) toast(opts.successToast || label + '完成', 'ok');
      return true;
    } catch (e) {
      state.lastOutput = e.message || String(e);
      toast(e.message || label + '失败', 'err');
      return false;
    } finally {
      state.busy = '';
      renderConsole();
      if (state.page !== 'config') renderPage();
      else updateConfigDynamic();
    }
  }

  async function subAction(action) {
    var s = state.status;
    if (!s) return;
    var sub = s.substore;
    if (action === 'start') {
      if (!sub.health) {
        toast('Sub-Store 运行环境未就绪：' + (sub.health_reason || '缺少组件'), 'err');
        return;
      }
      await startTask('启动 Sub-Store', ['sub', 'start']);
    } else if (action === 'stop') {
      var ok = await confirmSheet({ title: '停止 Sub-Store', message: '停止后订阅管理与定时任务将暂停。', confirmText: '停止', danger: true });
      if (!ok) return;
      await startTask('停止 Sub-Store', ['sub', 'stop']);
    } else if (action === 'restart') {
      await startTask('重启 Sub-Store', ['sub', 'restart']);
    } else if (action === 'install') {
      await startTask('安装 Sub-Store 运行环境', ['sub', 'update', 'all'], function () {
        toast('运行环境安装完成', 'ok');
        var st = state.status;
        if (st && st.substore && !st.substore.running) {
          startTask('启动 Sub-Store', ['sub', 'start']);
        }
      });
    } else if (action === 'update.all') {
      await startTask('更新 Sub-Store 前后端', ['sub', 'update', 'all']);
    } else if (action === 'update.node') {
      await startTask('更新 Node 运行时', ['sub', 'update', 'node']);
    } else if (action === 'update.backend') {
      await startTask('更新 Sub-Store 后端', ['sub', 'update', 'backend']);
    } else if (action === 'update.frontend') {
      await startTask('更新 Sub-Store 前端', ['sub', 'update', 'frontend']);
    } else if (action === 'regen') {
      var ok2 = await confirmSheet({
        title: '重新生成访问路径',
        message: '旧路径会立即失效，已打开的 Sub-Store 页面需要重新打开。',
        confirmText: '重新生成',
        danger: false
      });
      if (!ok2) return;
      await startTask('生成访问路径', ['sub', 'regen-path']);
    }
  }

  async function saveProxy(clear) {
    var value = clear ? '' : (state.forms.proxy || '').trim();
    var ok = await runSync(clear ? '清空加速地址' : '保存加速地址', ['set', 'GH_PROXY', textToB64(value)], { successToast: clear ? '已改为直连' : '加速地址已保存' });
    if (ok) {
      state.forms.proxy = value;
      state.forms.proxyDirty = false;
      var proxyEl = $('#proxy-input');
      if (proxyEl) proxyEl.value = value;
      updateConfigDynamic();
    }
  }

  async function setChannel(id, channel) {
    var s = state.status;
    if (!s) return;
    var current = coreChannel(s, id);
    if (current === channel) return;
    var key = id === 'sing-box' ? 'SINGBOX_CHANNEL' : 'MIHOMO_CHANNEL';
    await runSync('切换通道', ['set', key, textToB64(channel)], { successToast: id + ' 默认通道：' + channelLabel(channel) });
  }

  async function checkConfig(target) {
    var label = '校验 ' + TARGET_META[target].label;
    await runSync(label, ['cfg', 'check', target], { successToast: '配置校验通过' });
  }

  async function pullConfig(target) {
    target = target || state.config.target;
    var form = state.forms.pull[target];
    if (!form) return;
    var url = (form.url || '').trim();
    if (!url) {
      toast('请先填写 ' + TARGET_META[target].label + ' 的 URL', 'err');
      return;
    }
    if (state.config.dirty && state.config.target === target) {
      var discard = await confirmSheet({
        title: '覆盖当前编辑器？',
        message: '拉取成功后会重新载入 ' + TARGET_META[target].file + '，当前编辑器里未保存的修改会丢失。',
        confirmText: '继续拉取',
        danger: true
      });
      if (!discard) return;
    }
    var force = form.force ? '1' : '0';
    var meta = TARGET_META[target];
    await startTask('拉取 ' + meta.label + ' 配置', ['cfg', 'fetch', target, textToB64(url), textToB64(''), force], function () {
      if (state.config.dirty && state.config.target !== target) {
        toast('已写入 ' + meta.file + '；当前编辑器有未保存修改，未自动切换', 'ok', 3800);
        refreshStatus(false);
      } else {
        state.config.target = target;
        loadConfig(target);
      }
    }, function (t) {
      if (form.force) return;
      if (!/校验未通过|校验失败|verify/i.test(t.log || '')) return;
      confirmSheet({
        title: '配置校验未通过',
        message: '文件已下载，但校验失败。仍然保存到 <strong>' + escapeHTML(meta.file) + '</strong> 吗？<br><br>保存后需要手动修正配置才能启动。',
        confirmText: '仍然保存',
        danger: true
      }).then(function (ok) {
        if (!ok) return;
        runCli(['cfg', 'commit', target, '1']).then(function (res) {
          if (!res.ok) {
            toast(firstLine(res.stderr || res.stdout) || '保存失败', 'err');
            return;
          }
          toast('已强制保存到 ' + meta.file + '，请修复配置后再启动', 'info', 3600);
          if (!state.config.dirty || state.config.target === target) {
            state.config.target = target;
            loadConfig(target);
          }
          refreshStatus(false);
        });
      });
    });
  }

  async function downloadConfig() {
    if (state.busy || taskRunning()) {
      toast('请等待当前操作结束', 'err');
      return;
    }
    var res = await runCli(['cfg', 'download', state.config.target]);
    if (!res.ok) {
      toast(firstLine(res.stderr || res.stdout) || '导出失败', 'err');
      return;
    }
    toast('已导出：' + (lastLogLine(res.stdout) || 'Download/Nakedcore'), 'ok', 3800);
  }

  async function exportConfig() {
    await startTask('导出全部配置', ['cfg', 'export'], function (t) {
      toast('已导出：' + (lastLogLine(t.log) || 'Download/Nakedcore'), 'ok', 3800);
    });
  }

  async function deleteConfig() {
    if (state.busy || taskRunning()) {
      toast('请等待当前操作结束', 'err');
      return;
    }
    var target = state.config.target;
    var ok = await confirmSheet({
      title: '删除 ' + TARGET_META[target].label + ' 配置',
      message: '会先保留 <strong>.bak</strong> 备份，然后删除当前文件。Sub-Store 环境变量会重置为默认值。',
      confirmText: '删除',
      danger: true
    });
    if (!ok) return;
    var res = await runCli(['cfg', 'delete', target]);
    if (!res.ok) {
      toast(firstLine(res.stderr || res.stdout) || '删除失败', 'err');
      return;
    }
    toast('已删除配置', 'ok');
    await refreshStatus(false);
    await loadConfig(target);
  }

  async function importFile(file, target) {
    if (!file) return;
    target = target || state.config.target;
    if (target !== state.config.target) {
      if (state.config.dirty) {
        var discard = await confirmSheet({
          title: '切换并导入？',
          message: '导入会切换到 <strong>' + TARGET_META[target].file + '</strong>；当前编辑器里未保存的修改会丢失。',
          confirmText: '切换并导入',
          danger: true
        });
        if (!discard) return;
      }
      state.config.target = target;
      await loadConfig(target);
    }
    var reader = new FileReader();
    reader.onload = function (e) {
      state.config.content = String(e.target.result || '');
      state.config.dirty = state.config.content !== state.config.original;
      var ta = $('#cfg-editor');
      if (ta) ta.value = state.config.content;
      updateEditorMeta();
      toast('已导入到 ' + TARGET_META[target].label + ' 编辑器，点击保存后生效', 'ok');
    };
    reader.onerror = function () { toast('读取文件失败', 'err'); };
    reader.readAsText(file);
  }

  async function saveSubSettings() {
    var s = state.status;
    if (!s) return;
    if (state.busy || taskRunning()) {
      toast('请等待当前操作结束', 'err');
      return;
    }
    var form = state.forms.sub;
    var port = parseInt(form.port, 10);
    var frontPort = parseInt(form.frontPort, 10);
    if (!(port >= 1024 && port <= 65535)) {
      toast('后端端口需在 1024-65535 之间', 'err');
      return;
    }
    if (!form.merge && !(frontPort >= 1024 && frontPort <= 65535)) {
      toast('前端端口需在 1024-65535 之间', 'err');
      return;
    }
    if (form.host === '0.0.0.0') {
      var lan = await confirmSheet({
        title: '允许局域网访问',
        message: 'Sub-Store 将监听 <strong>0.0.0.0</strong>，同一局域网设备可访问。请确保访问路径足够随机，且不要在不可信网络使用。',
        confirmText: '继续保存',
        danger: true
      });
      if (!lan) return;
    }
    state.busy = '保存 Sub-Store 设置';
    renderConsole();
    try {
      var changes = [
        ['SUB_STORE_BACKEND_API_HOST', form.host],
        ['SUB_STORE_BACKEND_API_PORT', String(port)],
        ['SUB_STORE_BACKEND_MERGE', form.merge ? 'true' : 'false'],
        ['SUB_STORE_FRONTEND_PORT', String(frontPort)]
      ];
      for (var i = 0; i < changes.length; i++) {
        var res = await runCli(['sub', 'set', changes[i][0], textToB64(changes[i][1])]);
        if (!res.ok) throw new Error(firstLine(res.stderr || res.stdout) || '写入失败');
      }
      state.forms.sub.dirty = false;
      state.forms.sub.port = String(port);
      state.forms.sub.frontPort = String(frontPort);
      await refreshStatus(false);
      toast('Sub-Store 设置已保存', 'ok');
      if (s.substore.running) {
        await startTask('重启 Sub-Store', ['sub', 'restart']);
      } else {
        toast('下次启动 Sub-Store 时生效', 'info');
      }
    } catch (e) {
      toast(e.message || '保存失败', 'err');
    } finally {
      state.busy = '';
      renderConsole();
      refreshSubSettingsCard();
      if (state.page === 'config') updateConfigDynamic();
    }
  }

  async function downloadLocalUi(type) {
    var meta = UI_META[type];
    if (!meta) return;
    var item = state.status && state.status.ui && state.status.ui[type] ? state.status.ui[type] : {};
    var path = item.path || (DATA_DIR + '/' + meta.rel);
    var ok = await confirmSheet({
      title: '下载 ' + meta.name + ' 本地 UI',
      message: '将下载并部署到：<br><strong>' + escapeHTML(path) + '</strong><br><br>' +
        (item.installed ? '旧版本会被替换；' : '') + '下载需要网络，完成后可在内核的 external_ui / external-ui 中指向该目录。',
      confirmText: '下载',
      danger: false
    });
    if (!ok) return;
    await startTask('下载 ' + meta.name + ' 本地 UI', ['ui', 'update', type], function () {
      toast(meta.name + ' 已部署到 ' + meta.rel, 'ok', 3600);
    });
  }

  async function deleteLocalUi(type) {
    var meta = UI_META[type];
    if (!meta) return;
    var ok = await confirmSheet({
      title: '删除 ' + meta.name + ' 本地 UI',
      message: '将删除 <strong>' + meta.rel + '</strong> 下的静态文件，不影响内核配置。',
      confirmText: '删除',
      danger: true
    });
    if (!ok) return;
    await runSync('删除 ' + meta.name + ' 本地 UI', ['ui', 'delete', type], { successToast: meta.name + ' 本地 UI 已删除' });
  }

  async function clearLocalUiCache() {
    var ok = await confirmSheet({
      title: '清空内核目录',
      message: '将清空两个内核目录，只保留：<br><strong>sing-box/config.json</strong><br><strong>mihomo/config.yaml</strong><br><br>' +
        'cache.db、ui/、rules/、.bak、旧面板与下载临时文件都会删除。内核二进制和 run 日志不在这些目录，不会被删除。',
      confirmText: '清空',
      danger: true
    });
    if (!ok) return;
    var done = await runSync('清空内核目录', ['ui', 'clear'], { successToast: '已清空，仅保留配置文件' });
    if (done) {
      try { localStorage.removeItem(STATUS_CACHE_KEY); } catch (e) { /* ignore */ }
    }
  }

  async function toggleHotspot() {
    var h = state.status && state.status.hotspot ? state.status.hotspot : { enabled: false };
    await runSync(h.enabled ? '关闭热点代理共享' : '开启热点代理共享', ['hotspot', h.enabled ? 'disable' : 'enable'], {
      successToast: h.enabled ? '热点代理共享已关闭' : '热点代理共享已开启'
    });
  }

  async function toggleHotspotUsb() {
    var h = state.status && state.status.hotspot ? state.status.hotspot : { usb: true };
    await runSync(h.usb ? '关闭 USB 共享接管' : '接管 USB 共享', ['hotspot', 'usb', h.usb ? 'false' : 'true'], {
      successToast: h.usb ? '已关闭 USB 共享接管' : '已接管 USB 共享'
    });
  }

  async function syncHotspot() {
    await runSync('同步热点接管', ['hotspot', 'sync'], { successToast: '热点状态已刷新' });
  }

  async function openExternal(url) {
    if (!url) return;
    if (runtime.preview) {
      window.open(url, '_blank', 'noopener,noreferrer');
      return;
    }
    try {
      var res = await ksuExec('am start -a android.intent.action.VIEW -d ' + shq(url));
      if (res.errno !== 0) toast('打开失败，请手动访问', 'err');
    } catch (e) {
      toast('打开失败：' + (e.message || e), 'err');
    }
  }

  // ----------------------------------------------------------
  // Sheet / Toast
  // ----------------------------------------------------------
  function openSheet(opts) {
    closeSheet(true);
    state.sheet = opts;
    var actions = (opts.actions || []).map(function (a, i) {
      return '<button class="btn ' + (a.cls || 'btn--soft') + '" type="button" data-action="sheet.action" data-index="' + i + '">' + escapeHTML(a.label) + '</button>';
    }).join('');
    var html = '<div class="sheet-mask" data-action="sheet.mask"><div class="sheet" role="dialog" aria-modal="true" aria-label="' + escapeHTML(opts.title || '') + '">' +
      '<div class="sheet__handle"></div>' +
      '<div class="sheet__head"><div><div class="sheet__title">' + escapeHTML(opts.title || '') + '</div>' +
      (opts.sub ? '<div class="sheet__sub" id="sheet-log-sub">' + escapeHTML(opts.sub) + '</div>' : '') +
      '</div><button class="iconbtn" type="button" data-action="sheet.close" aria-label="关闭">' + icon('x', 18) + '</button></div>' +
      '<div class="sheet__body">' + (opts.body || '') + '</div>' +
      (actions ? '<div class="sheet__actions">' + actions + '</div>' : '') +
      '</div></div>';
    var root = $('#sheet-root');
    root.innerHTML = html;
  }

  function closeSheet(silent) {
    var root = $('#sheet-root');
    if (root) root.innerHTML = '';
    var wasConfirm = !!state.confirmResolve;
    state.sheet = null;
    if (wasConfirm) {
      var resolve = state.confirmResolve;
      state.confirmResolve = null;
      resolve(false);
    }
    if (!silent && wasConfirm) { /* already resolved */ }
  }

  function confirmSheet(opts) {
    return new Promise(function (resolve) {
      // 先打开 sheet，再登记 resolver：openSheet 会关闭旧 sheet，
      // 若提前登记会被 closeSheet 当成旧确认而立即 resolve(false)。
      openSheet({
        title: opts.title || '确认操作',
        sub: opts.sub || '',
        body: '<div class="sheet__message">' + (opts.message || '确定执行此操作吗？') + '</div>',
        actions: [
          { label: opts.cancelText || '取消', action: 'confirm.cancel', cls: 'btn--ghost' },
          { label: opts.confirmText || '确定', action: 'confirm.ok', cls: opts.danger ? 'btn--danger' : 'btn--primary' }
        ]
      });
      state.confirmResolve = resolve;
    });
  }

  function resolveConfirm(value) {
    var resolve = state.confirmResolve;
    state.confirmResolve = null;
    state.sheet = null;
    var root = $('#sheet-root');
    if (root) root.innerHTML = '';
    if (resolve) resolve(value);
  }

  function toast(message, type, duration) {
    var root = $('#toast-root');
    if (!root) return;
    var el = document.createElement('div');
    el.className = 'toast toast--' + (type || 'info');
    var iconName = type === 'ok' ? 'check' : type === 'err' ? 'alert' : 'info';
    el.innerHTML = icon(iconName, 15) + '<span>' + escapeHTML(message) + '</span>';
    root.appendChild(el);
    while (root.children.length > 3) root.removeChild(root.firstChild);
    var ms = duration || 2600;
    setTimeout(function () {
      el.classList.add('is-out');
      setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 220);
    }, ms);
  }

  // ----------------------------------------------------------
  // 事件
  // ----------------------------------------------------------
  document.addEventListener('click', function (e) {
    var nav = e.target.closest('[data-nav]');
    if (nav) {
      setPage(nav.dataset.nav);
      return;
    }
    var el = e.target.closest('[data-action]');
    if (!el) return;
    var action = el.dataset.action;
    if (action === 'sheet.mask' && e.target !== el) return;
    if (el.tagName === 'BUTTON' && el.disabled) return;

    switch (action) {
      case 'refresh':
        refreshStatus(true);
        break;
      case 'conn.test':
        testConnectivity();
        break;
      case 'conn.reload':
        loadConnectivity(true);
        break;
      case 'conn.filter':
        state.conn.filter = el.dataset.filter || 'all';
        renderConnectivity();
        break;
      case 'conn.detail':
        openConnDetail(el.dataset.id);
        break;
      case 'conn.refresh':
        refreshConnectivity(el.dataset.id);
        break;
      case 'go.home':
        setPage('home');
        break;
      case 'go.core':
        setPage('core');
        break;
      case 'go.config':
        setPage('config');
        break;
      case 'core.start':
        startCore();
        break;
      case 'hotspot.toggle':
        toggleHotspot();
        break;
      case 'hotspot.usb':
        toggleHotspotUsb();
        break;
      case 'hotspot.sync':
        syncHotspot();
        break;
      case 'wifi.toggle':
        toggleWifiGuard();
        break;
      case 'wifi.add':
        addWifiSsid();
        break;
      case 'wifi.remove':
        removeWifiSsid(el.dataset.ssid);
        break;
      case 'wifi.check':
        checkWifi();
        break;
      case 'wifi.resume':
        resumeWifiGuard();
        break;
      case 'core.stop':
        stopCore();
        break;
      case 'core.restart':
        restartCore();
        break;
      case 'core.switch':
        switchCore();
        break;
      case 'core.switch.do':
        switchCore(el.dataset.core);
        break;
      case 'core.log':
        var logCore = el.dataset.core || (state.status && state.status.settings && state.status.settings.active_core) || 'sing-box';
        openLogSheet(logCore === 'sing-box' ? 'singbox' : logCore);
        break;
      case 'core.autostart':
        toggleCoreAutostart();
        break;
      case 'core.check':
        coreCheck(el.dataset.core || (state.status && state.status.settings.active_core));
        break;
      case 'core.delete':
        coreDelete(el.dataset.core);
        break;
      case 'core.update':
        coreUpdate(el.dataset.core, el.dataset.channel || 'stable');
        break;
      case 'core.rollback':
        coreRollback(el.dataset.core);
        break;
      case 'core.channel':
        setChannel(el.dataset.core, el.dataset.channel);
        break;
      case 'sub.start':
        subAction('start');
        break;
      case 'sub.stop':
        subAction('stop');
        break;
      case 'sub.restart':
        subAction('restart');
        break;
      case 'sub.install':
        subAction('install');
        break;
      case 'sub.update.all':
        subAction('update.all');
        break;
      case 'sub.update.node':
        subAction('update.node');
        break;
      case 'sub.update.backend':
        subAction('update.backend');
        break;
      case 'sub.update.frontend':
        subAction('update.frontend');
        break;
      case 'sub.regen':
        subAction('regen');
        break;
      case 'sub.autostart':
        toggleSubAutostart();
        break;
      case 'sub.settings':
        openSubSettingsSheet();
        break;
      case 'sub.open':
        if (state.status && state.status.substore) openExternal(state.status.substore.direct_url || state.status.substore.open_url);
        break;
      case 'sub.copy':
        copyText(el.dataset.value || (state.status && state.status.substore.direct_url) || '').then(function () { toast('地址已复制', 'ok'); });
        break;
      case 'sub.log':
        openLogSheet('substore');
        break;
      case 'sub.mode':
        state.forms.sub.merge = el.dataset.mode === 'true';
        state.forms.sub.dirty = true;
        refreshSubSettingsCard();
        break;
      case 'sub.host':
        state.forms.sub.host = el.dataset.host;
        state.forms.sub.dirty = true;
        refreshSubSettingsCard();
        break;
      case 'sub.save':
        saveSubSettings();
        break;
      case 'checkup':
        startTask('检查更新', ['checkup'], function () { refreshStatus(false); });
        break;
      case 'all.update':
        (async function () {
          var ok = await confirmSheet({
            title: '一键更新',
            message: '将更新当前激活内核与 Sub-Store 前端/后端。内核正在运行时会短暂中断。',
            confirmText: '开始更新',
            danger: false
          });
          if (ok) startTask('一键更新', ['all', 'update']);
        })();
        break;
      case 'cfg.select':
        (async function () {
          if (state.config.target === el.dataset.target) return;
          if (state.config.dirty) {
            var ok = await confirmSheet({ title: '放弃未保存修改？', message: '切换文件会丢失当前编辑器中的修改。', confirmText: '放弃并切换', danger: true });
            if (!ok) return;
          }
          state.config.target = el.dataset.target;
          loadConfig(el.dataset.target);
        })();
        break;
      case 'cfg.save':
        saveConfig();
        break;
      case 'cfg.check':
        checkConfig(state.config.target);
        break;
      case 'cfg.format':
        (function () {
          try {
            var data = JSON.parse(state.config.content);
            state.config.content = JSON.stringify(data, null, 2) + '\n';
            state.config.dirty = state.config.content !== state.config.original;
            var ta = $('#cfg-editor');
            if (ta) ta.value = state.config.content;
            updateEditorMeta();
            toast('JSON 已格式化', 'ok');
          } catch (e2) {
            toast('JSON 解析失败：' + firstLine(e2.message), 'err');
          }
        })();
        break;
      case 'cfg.revert':
        state.config.content = state.config.original;
        state.config.dirty = false;
        var ta = $('#cfg-editor');
        if (ta) ta.value = state.config.content;
        updateEditorMeta();
        toast('已还原到上次保存的内容', 'info');
        break;
      case 'cfg.delete':
        deleteConfig();
        break;
      case 'cfg.download':
        downloadConfig();
        break;
      case 'cfg.export':
        exportConfig();
        break;
      case 'cfg.import':
        var importTarget = el.dataset.target || state.config.target;
        if (importTarget !== state.config.target) {
          state.config.target = importTarget;
          renderConfigPage();
        }
        var importInput = $('#cfg-file');
        if (importInput) importInput.click();
        break;
      case 'cfg.pull':
        pullConfig(el.dataset.target);
        break;
      case 'ui.update':
        downloadLocalUi(el.dataset.ui);
        break;
      case 'ui.delete':
        deleteLocalUi(el.dataset.ui);
        break;
      case 'ui.clear':
        clearLocalUiCache();
        break;
      case 'proxy.save':
        saveProxy(false);
        break;
      case 'proxy.clear':
        saveProxy(true);
        break;
      case 'log.open':
        openLogSheet(el.dataset.log);
        break;
      case 'log.refresh':
        if (state.sheet && state.sheet.logName) loadLogInto(state.sheet.logName);
        break;
      case 'log.copy':
        (function () {
          var logEl = $('#sheet-log');
          copyText(logEl ? logEl.textContent : '').then(function () { toast('日志已复制', 'ok'); });
        })();
        break;
      case 'console.open':
        openConsoleSheet();
        break;
      case 'console.copy':
        (function () {
          var el = $('#sheet-log');
          copyText(el ? el.textContent : consoleTaskText()).then(function () { toast('日志已复制', 'ok'); });
        })();
        break;
      case 'console.view':
        switchConsoleView(el.dataset.view);
        break;
      case 'console.cancel':
        cancelTask();
        break;
      case 'open.link':
        openExternal(el.dataset.url);
        break;
      case 'theme.cycle':
        cycleTheme();
        if (state.page === 'config') renderConfigPage();
        break;
      case 'theme.set':
        applyTheme(el.dataset.mode);
        if (state.page === 'config') renderConfigPage();
        break;
      case 'sheet.mask':
        closeSheet();
        break;
      case 'sheet.close':
        closeSheet();
        break;
      case 'confirm.ok':
        resolveConfirm(true);
        break;
      case 'confirm.cancel':
        resolveConfirm(false);
        break;
      case 'sheet.action':
        (function () {
          var idx = Number(el.dataset.index);
          var sheet = state.sheet;
          if (!sheet || !sheet.actions || !sheet.actions[idx]) return;
          var a = sheet.actions[idx];
          if (a.action === 'sheet.close') closeSheet();
          else if (a.action === 'confirm.ok') resolveConfirm(true);
          else if (a.action === 'confirm.cancel') resolveConfirm(false);
          else if (a.action === 'console.copy') { var cel = $('#sheet-log'); copyText(cel ? cel.textContent : consoleTaskText()).then(function () { toast('日志已复制', 'ok'); }); }
          else if (a.action === 'console.cancel') cancelTask();
          else if (a.action === 'log.refresh') { if (sheet.logName) loadLogInto(sheet.logName); }
          else if (a.action === 'log.clear') { if (sheet.logName) clearLog(sheet.logName); }
          else if (a.action === 'console.clear') { clearConsoleLog(); }
          else if (a.action === 'log.copy') { var le = $('#sheet-log'); copyText(le ? le.textContent : '').then(function () { toast('日志已复制', 'ok'); }); }
        })();
        break;
      default:
        break;
    }
  });

  document.addEventListener('input', function (e) {
    var t = e.target;
    if (t.id === 'cfg-editor') {
      state.config.content = t.value;
      state.config.dirty = t.value !== state.config.original;
      updateEditorMeta();
    } else if (t.id === 'cfg-pull-url') {
      var pullTarget = state.config.target;
      if (state.forms.pull[pullTarget]) state.forms.pull[pullTarget].url = t.value;
    } else if (t.id === 'proxy-input') {
      state.forms.proxy = t.value;
      state.forms.proxyDirty = true;
    } else if (t.id === 'sub-port') {
      state.forms.sub.port = t.value;
      state.forms.sub.dirty = true;
    } else if (t.id === 'sub-front-port') {
      state.forms.sub.frontPort = t.value;
      state.forms.sub.dirty = true;
    }
  });

  document.addEventListener('change', function (e) {
    var t = e.target;
    if (t.id === 'cfg-pull-force') {
      var pullTarget = state.config.target;
      if (state.forms.pull[pullTarget]) state.forms.pull[pullTarget].force = t.checked;
    } else if (t.id === 'cfg-file') {
      var f = t.files && t.files[0];
      if (f) importFile(f, state.config.target);
      t.value = '';
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && e.target && e.target.id === 'wifi-ssid-input') {
      e.preventDefault();
      addWifiSsid();
      return;
    }
    if (e.key === 'Escape') {
      if (state.sheet) {
        if (state.confirmResolve) resolveConfirm(false);
        else closeSheet();
      }
      return;
    }
    if (e.target && e.target.id === 'cfg-editor' && e.key === 'Tab') {
      e.preventDefault();
      var ta = e.target;
      var start = ta.selectionStart;
      var end = ta.selectionEnd;
      ta.value = ta.value.slice(0, start) + '  ' + ta.value.slice(end);
      ta.selectionStart = ta.selectionEnd = start + 2;
      state.config.content = ta.value;
      state.config.dirty = ta.value !== state.config.original;
      updateEditorMeta();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
      if (state.page === 'config') {
        e.preventDefault();
        if (state.config.dirty && !state.busy && !taskRunning()) saveConfig();
      }
    }
  });

  function refreshSubSettingsCard() {
    var body = $('#sheet-sub-settings');
    if (body && state.status) body.innerHTML = subSettingsInner(state.status, true);
  }

  // ----------------------------------------------------------
  // Mock / 预览
  // ----------------------------------------------------------
  var mockTasks = {};

  var MOCK_CONN_ITEMS = [
    { id: 'google', name: 'Google', category: 'dev', url: 'https://www.google.com/generate_204', abbr: 'G', color: '#4285f4' },
    { id: 'github', name: 'GitHub', category: 'dev', url: 'https://github.com/', abbr: 'GH', color: '#24292f' },
    { id: 'youtube', name: 'YouTube', category: 'stream', url: 'https://www.youtube.com/premium?hl=en', abbr: 'YT', color: '#ff0033' },
    { id: 'chatgpt', name: 'ChatGPT', category: 'ai', url: 'https://chat.openai.com/cdn-cgi/trace', abbr: 'C', color: '#10a37f' },
    { id: 'claude', name: 'Claude', category: 'ai', url: 'https://claude.ai/cdn-cgi/trace', abbr: 'C', color: '#d97757' },
    { id: 'gemini', name: 'Gemini', category: 'ai', url: 'https://gemini.google.com', abbr: 'G', color: '#4285f4' },
    { id: 'netflix', name: 'Netflix', category: 'stream', url: 'https://www.netflix.com/title/81280792', abbr: 'N', color: '#e50914' },
    { id: 'disney-plus', name: 'Disney+', category: 'stream', url: 'https://www.disneyplus.com', abbr: 'D', color: '#113ccf' },
    { id: 'prime-video', name: 'Prime Video', category: 'stream', url: 'https://www.primevideo.com', abbr: 'P', color: '#00a8e1' },
    { id: 'spotify', name: 'Spotify', category: 'stream', url: 'https://open.spotify.com', abbr: 'S', color: '#1db954' },
    { id: 'tiktok', name: 'TikTok', category: 'stream', url: 'https://www.tiktok.com/', abbr: 'TT', color: '#111111' },
    { id: 'discord', name: 'Discord', category: 'community', url: 'https://discord.com', abbr: 'D', color: '#5865f2' },
    { id: 'bilibili', name: '哔哩哔哩', category: 'cn', url: 'https://www.bilibili.com', abbr: 'B', color: '#00aeec' }
  ];

  var mockConnStore = null;

  function mockConnSeed() {
    var now = Math.floor(Date.now() / 1000);
    var results = {};
    var labels = {
      available: '可用', restricted: '访问受限', blocked: '已被封禁',
      'unsupported-region': '地区不支持', 'originals-only': '仅限自制内容',
      unavailable: '不可用', timeout: '超时', failed: '检测失败'
    };
    var forced = {
      netflix: 'originals-only',
      'disney-plus': 'unsupported-region',
      'prime-video': 'unavailable',
      spotify: 'restricted',
      gemini: 'unsupported-region'
    };
    MOCK_CONN_ITEMS.forEach(function (item, i) {
      var status = forced[item.id] || 'available';
      results[item.id] = {
        id: item.id,
        status: status,
        label: labels[status] || '检测失败',
        http: status === 'unavailable' ? 0 : 200,
        latency_ms: status === 'unavailable' ? 0 : 420 + i * 73,
        region: status === 'available' || status === 'originals-only' ? 'SG' : '',
        error: status === 'unavailable' ? '连接超时' : '',
        tested_at: now - 90
      };
    });
    return { tested_at: now - 90, region: '', results: results };
  }

  function mockConnResult(id, fresh) {
    var item = MOCK_CONN_ITEMS.filter(function (x) { return x.id === id; })[0];
    if (!item) return null;
    if (!mockConnStore) mockConnStore = mockConnSeed();
    if (!fresh && mockConnStore.results[id]) return mockConnStore.results[id];
    var seed = mockConnSeed().results[id];
    if (fresh) {
      seed.latency_ms = 400 + Math.floor(Math.random() * 1800);
      seed.tested_at = Math.floor(Date.now() / 1000);
      mockConnStore.results[id] = seed;
      mockConnStore.tested_at = seed.tested_at;
    }
    return seed;
  }

  function mockStatus() {
    var now = Math.floor(Date.now() / 1000);
    return {
      ok: true,
      time: now,
      module: { id: 'Android_Nakedcore', name: 'Android Nakedcore', version: 'V1.2.0', versionCode: 1120 },
      device: { model: 'Pixel 8 Pro', android: '15', sdk: '35', abi: 'arm64-v8a', kernel: '6.1.75-android14-gki', manager: 'KernelSU' },
      settings: {
        active_core: 'sing-box',
        auto_start: true,
        sub_auto_start: true,
        gh_proxy: 'https://gh-proxy.com',
        singbox_channel: 'stable',
        mihomo_channel: 'alpha'
      },
      cores: {
        'sing-box': { id: 'sing-box', installed: true, version: '1.15.0-alpha.13', running: true, pid: 2841, config_exists: true, config_size: 8421, config_state: 'ok', config_dirty: false, rollback: true, log: DATA_DIR + '/run/sing-box.log', latest: '1.15.0-alpha.13', channel: 'stable' },
        mihomo: { id: 'mihomo', installed: true, version: 'alpha-6780eee', running: false, pid: 0, config_exists: true, config_size: 6120, config_state: 'unknown', config_dirty: false, rollback: false, log: DATA_DIR + '/run/mihomo.log', latest: 'alpha-6780eee', channel: 'alpha' }
      },
      substore: {
        running: true,
        pid: 3122,
        health: true,
        health_reason: '正常',
        node: { installed: true, version: '24.21.0', path: DATA_DIR + '/bin/node' },
        backend: { installed: true, version: '2.42.6' },
        frontend: { installed: true, version: '2.11.0' },
        host: '127.0.0.1',
        port: 3000,
        front_host: '127.0.0.1',
        front_port: 3001,
        merge: true,
        backend_path: '/pvZokLv4HJvPhQEXo7aB2j',
        direct_url: 'http://127.0.0.1:3000?api=http://127.0.0.1:3000/pvZokLv4HJvPhQEXo7aB2j',
        open_url: 'http://127.0.0.1:3000?api=http://127.0.0.1:3000/pvZokLv4HJvPhQEXo7aB2j',
        autostart: true,
        dirty: false,
        data_dir: DATA_DIR + '/sub-store/data',
        log: DATA_DIR + '/run/substore.log',
        latest_backend: '2.42.6',
        latest_frontend: '2.11.0'
      },
      ui: {
        dashboard: { installed: false, path: DATA_DIR + '/sing-box/ui/dashboard', size: 0 },
        zashboard: { installed: false, path: DATA_DIR + '/mihomo/ui/zashboard', size: 0 }
      },
      wifi: {
        guard: true,
        ssids: ['2.4G', 'Home_WiFi'],
        current_ssid: 'H3C_5G',
        trusted: false,
        suspended: false,
        manual_stop: false,
        daemon: true,
        detect_ok: true,
        interval: 5
      },
      hotspot: {
        enabled: false,
        active: false,
        usb: true,
        ifaces: [],
        subnet: ''
      },
      task: null,
      last_task: null,
      update_check: {
        checked_at: now - 180,
        sb_stable: '1.14.4',
        sb_alpha: '1.15.0-alpha.13',
        mh_stable: '1.19.33',
        mh_alpha: 'alpha-6780eee',
        sub_backend: '2.42.6',
        sub_frontend: '2.11.0'
      }
    };
  }

  function mockText(target) {
    if (target === 'mihomo') {
      return 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nexternal-controller: 127.0.0.1:9090\n\nproxies:\n  - name: "示例节点"\n    type: ss\n    server: example.com\n    port: 443\n    cipher: aes-256-gcm\n    password: "password"\n\nproxy-groups:\n  - name: 节点选择\n    type: select\n    proxies:\n      - 示例节点\n      - DIRECT\n\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,节点选择\n';
    }
    if (target === 'substore') {
      return 'SUB_STORE_BACKEND_API_HOST="127.0.0.1"\nSUB_STORE_BACKEND_API_PORT="3000"\nSUB_STORE_FRONTEND_BACKEND_PATH="/pvZokLv4HJvPhQEXo7aB2j"\nSUB_STORE_FRONTEND_PATH="' + DATA_DIR + '/sub-store/frontend"\nSUB_STORE_DATA_BASE_PATH="' + DATA_DIR + '/sub-store/data"\nSUB_STORE_BACKEND_MERGE="true"\nSUB_STORE_FRONTEND_HOST="127.0.0.1"\nSUB_STORE_FRONTEND_PORT="3001"\nSUB_STORE_BODY_JSON_LIMIT="1mb"\nSUB_STORE_MAX_HEADER_SIZE="32768"\nSUB_STORE_CORS_ALLOWED_ORIGINS="*"\n';
    }
    return '{\n  "log": {\n    "level": "info",\n    "timestamp": true\n  },\n  "dns": {\n    "servers": [\n      { "tag": "google", "address": "tls://8.8.8.8" },\n      { "tag": "local", "address": "223.5.5.5", "detour": "direct" }\n    ],\n    "rules": [\n      { "outbound": "any", "server": "local" }\n    ]\n  },\n  "inbounds": [\n    {\n      "type": "tun",\n      "tag": "tun-in",\n      "address": ["172.19.0.1/30"],\n      "auto_route": true,\n      "strict_route": true,\n      "stack": "mixed"\n    }\n  ],\n  "outbounds": [\n    { "type": "direct", "tag": "direct" },\n    {\n      "type": "shadowsocks",\n      "tag": "proxy",\n      "server": "example.com",\n      "server_port": 443,\n      "method": "aes-256-gcm",\n      "password": "password"\n    }\n  ],\n  "route": {\n    "rules": [\n      { "geoip": ["cn"], "outbound": "direct" }\n    ],\n    "final": "proxy",\n    "auto_detect_interface": true\n  },\n  "experimental": {\n    "clash_api": {\n      "external_controller": "127.0.0.1:9090",\n      "external_ui": ""\n    }\n  }\n}\n';
  }

  function mockTask(args) {
    var id = 'mock-' + Date.now() + '-' + Math.floor(Math.random() * 1000);
    var label = taskLabel(args);
    var t = { id: id, state: 'running', label: label, log: '', started: Math.floor(Date.now() / 1000), code: null, elapsed: 0 };
    mockTasks[id] = t;
    var lines = [
      '[Info] ' + label + ' 开始',
      '[Info] 正在检查网络与组件…',
      '[Info] 下载/安装中，请稍候…'
    ];
    var i = 0;
    var timer = setInterval(function () {
      if (i < lines.length) {
        t.log += lines[i++] + '\n';
        t.elapsed = Math.floor(Date.now() / 1000) - t.started;
      } else {
        clearInterval(timer);
        t.log += '[Info] 任务完成\n';
        t.state = 'success';
        t.code = 0;
        t.elapsed = Math.floor(Date.now() / 1000) - t.started;
        mockApply(args);
      }
    }, 420);
    return { id: id, label: label };
  }

  function mockApply(args) {
    var s = state.status;
    if (!s) return;
    var a = args.join(' ');
    if (/^core start/.test(a)) {
      var id = args[2] || s.settings.active_core;
      s.settings.active_core = id;
      Object.keys(s.cores).forEach(function (k) { s.cores[k].running = k === id; s.cores[k].pid = k === id ? 2841 : 0; });
      if (s.wifi) s.wifi.manual_stop = false;
    } else if (/^core stop/.test(a)) {
      var id2 = args[2] || s.settings.active_core;
      if (s.cores[id2]) { s.cores[id2].running = false; s.cores[id2].pid = 0; }
      if (s.wifi) { s.wifi.manual_stop = true; s.wifi.suspended = false; }
    } else if (/^core switch/.test(a)) {
      var id3 = args[2];
      s.settings.active_core = id3;
      Object.keys(s.cores).forEach(function (k) { if (k !== id3) s.cores[k].running = false; });
    } else if (/^core delete/.test(a)) {
      var idDel = args[2];
      if (s.cores[idDel]) { s.cores[idDel].installed = false; s.cores[idDel].running = false; s.cores[idDel].version = ''; s.cores[idDel].pid = 0; }
    } else if (/^core update/.test(a)) {
      var id4 = args[2];
      if (s.cores[id4] && s.cores[id4].latest) { s.cores[id4].version = s.cores[id4].latest; s.cores[id4].installed = true; }
    } else if (/^sub start/.test(a)) {
      s.substore.running = true; s.substore.pid = 3122;
    } else if (/^sub stop/.test(a)) {
      s.substore.running = false; s.substore.pid = 0;
    } else if (/^sub update/.test(a)) {
      s.substore.backend.version = s.substore.latest_backend || s.substore.backend.version;
      s.substore.frontend.version = s.substore.latest_frontend || s.substore.frontend.version;
      s.substore.health = true;
      s.substore.health_reason = '正常';
      s.substore.node.installed = true;
      s.substore.node.version = s.substore.node.version || '24.21.0';
      s.substore.running = true;
    } else if (/^ui update/.test(a)) {
      var uiType = args[2];
      if (s.ui && s.ui[uiType]) { s.ui[uiType].installed = true; s.ui[uiType].size = 262144; }
    } else if (/^ui delete/.test(a)) {
      var uiTypeDel = args[2];
      if (s.ui && s.ui[uiTypeDel]) { s.ui[uiTypeDel].installed = false; s.ui[uiTypeDel].size = 0; }
    } else if (/^ui clear/.test(a)) {
      if (s.ui) Object.keys(s.ui).forEach(function (k) { s.ui[k].installed = false; s.ui[k].size = 0; });
    } else if (/^cfg fetch/.test(a)) {
      var target = args[2];
      var content = mockText(target);
      if (target === 'singbox') { s.cores['sing-box'].config_state = 'ok'; s.cores['sing-box'].config_size = utf8Length(content); }
      if (target === 'mihomo') { s.cores.mihomo.config_state = 'ok'; s.cores.mihomo.config_size = utf8Length(content); }
    } else if (/^all update/.test(a)) {
      var c = s.cores[s.settings.active_core];
      if (c && c.latest) c.version = c.latest;
      s.substore.backend.version = s.substore.latest_backend || s.substore.backend.version;
      s.substore.frontend.version = s.substore.latest_frontend || s.substore.frontend.version;
    } else if (/^checkup/.test(a)) {
      s.update_check.checked_at = Math.floor(Date.now() / 1000);
    } else if (/^connectivity test/.test(a)) {
      mockConnStore = mockConnSeed();
    }
  }

  function mockExec(args, opts) {
    var a = args.join(' ');
    return new Promise(function (resolve) {
      setTimeout(function () {
        var result = { ok: true, errno: 0, stdout: '', stderr: '' };
        if (a === 'status') {
          result.stdout = JSON.stringify(state.status || mockStatus());
        } else if (/^core info/.test(a)) {
          var s = mockStatus();
          result.stdout = JSON.stringify(s.cores[args[2] || s.settings.active_core]);
        } else if (/^sub info/.test(a)) {
          result.stdout = JSON.stringify(mockStatus().substore);
        } else if (a === 'connectivity list') {
          result.stdout = JSON.stringify(MOCK_CONN_ITEMS);
        } else if (a === 'connectivity results') {
          if (!mockConnStore) mockConnStore = mockConnSeed();
          result.stdout = JSON.stringify(mockConnStore);
        } else if (/^connectivity probe /.test(a)) {
          var connResult = mockConnResult(args[2], true);
          result.stdout = JSON.stringify(connResult || {});
        } else if (/^cfg get /.test(a)) {
          result.stdout = mockText(args[2]);
        } else if (/^cfg check/.test(a) || /^cfg commit/.test(a) || /^cfg put/.test(a) || /^cfg reset/.test(a)) {
          result.stdout = 'ok';
        } else if (/^cfg download/.test(a)) {
          result.stdout = '/sdcard/Download/Nakedcore/' + TARGET_META[args[2]].file;
        } else if (/^cfg export/.test(a)) {
          result.stdout = '/sdcard/Download/Nakedcore/nakedcore-backup-demo.tar.gz';
        } else if (/^task start/.test(a)) {
          var t = mockTask(args.slice(2));
          result.stdout = JSON.stringify(t);
        } else if (/^task status/.test(a)) {
          var task = mockTasks[args[2]];
          result.stdout = JSON.stringify(task || { id: args[2], state: 'failed', code: 1, label: '任务', log: '[Error] 任务不存在\n', elapsed: 0 });
        } else if (/^task cancel/.test(a)) {
          var tc = mockTasks[args[2]];
          if (tc) { tc.state = 'cancelled'; tc.code = 143; }
          result.stdout = '';
        } else if (/^log /.test(a)) {
          var name = args[1];
          if (name === 'substore') result.stdout = '[Info] Sub-Store 启动成功\n[Info] 访问地址: ' + (mockStatus().substore.direct_url) + '\n[Info] 后端版本: 2.42.6\n';
          else if (name === 'boot') result.stdout = '[Info] 开机启动流程开始\n[Info] 内核启动完成\n[Info] Sub-Store 启动完成\n';
          else result.stdout = '[Info] ' + name + ' 启动成功\n[Info] 配置校验通过\n[Info] inbound/tun 初始化完成\n[Info] started\n';
        } else if (/^ui delete|^ui clear/.test(a)) {
          var uiAction = a.indexOf('ui delete') === 0 ? args[2] : '';
          if (state.status && state.status.ui) {
            Object.keys(state.status.ui).forEach(function (k) {
              if (!uiAction || k === uiAction) { state.status.ui[k].installed = false; state.status.ui[k].size = 0; }
            });
          }
          result.stdout = 'ok';
        } else if (/^hotspot enable/.test(a)) {
          if (state.status && state.status.hotspot) {
            state.status.hotspot.enabled = true;
            state.status.hotspot.ifaces = ['ap0'];
            state.status.hotspot.subnet = '192.168.43.0/24';
            state.status.hotspot.active = true;
          }
        } else if (/^hotspot disable/.test(a)) {
          if (state.status && state.status.hotspot) {
            state.status.hotspot.enabled = false;
            state.status.hotspot.active = false;
            state.status.hotspot.ifaces = [];
            state.status.hotspot.subnet = '';
          }
        } else if (/^hotspot usb/.test(a)) {
          if (state.status && state.status.hotspot) state.status.hotspot.usb = args[2] === 'true';
        } else if (/^hotspot sync/.test(a)) {
          if (state.status && state.status.hotspot) {
            var mockHot = state.status.hotspot;
            var activeCore = state.status.cores[state.status.settings.active_core];
            mockHot.ifaces = mockHot.enabled ? ['ap0'] : [];
            mockHot.subnet = mockHot.enabled ? '192.168.43.0/24' : '';
            mockHot.active = !!(mockHot.enabled && activeCore && activeCore.running);
          }
        } else if (/^wifi status/.test(a)) {
          result.stdout = JSON.stringify((state.status || mockStatus()).wifi || {});
        } else if (/^wifi enable/.test(a)) {
          if (state.status && state.status.wifi) { state.status.wifi.guard = true; state.status.wifi.daemon = true; }
        } else if (/^wifi disable/.test(a)) {
          if (state.status && state.status.wifi) { state.status.wifi.guard = false; state.status.wifi.daemon = false; state.status.wifi.suspended = false; state.status.wifi.manual_stop = false; }
        } else if (/^wifi resume/.test(a)) {
          if (state.status && state.status.wifi) state.status.wifi.manual_stop = false;
        } else if (/^wifi add/.test(a)) {
          var ssidAdd = b64ToText(args[2] || '');
          if (state.status && state.status.wifi && ssidAdd && state.status.wifi.ssids.indexOf(ssidAdd) < 0) {
            state.status.wifi.ssids.push(ssidAdd);
          }
        } else if (/^wifi remove/.test(a)) {
          var ssidRemove = b64ToText(args[2] || '');
          if (state.status && state.status.wifi) {
            state.status.wifi.ssids = state.status.wifi.ssids.filter(function (x) { return x !== ssidRemove; });
          }
        } else if (/^wifi check/.test(a)) {
          if (state.status && state.status.wifi) state.status.wifi.suspended = !!state.status.wifi.trusted;
        } else if (/^set GH_PROXY/.test(a)) {
          var v = args[2] ? b64ToText(args[2]) : '';
          mockStatus().settings.gh_proxy = v;
          if (state.status) state.status.settings.gh_proxy = v;
        } else if (/^set SINGBOX_CHANNEL/.test(a) || /^set MIHOMO_CHANNEL/.test(a)) {
          var key = args[1];
          var val = b64ToText(args[2]);
          if (state.status) state.status.settings[key === 'SINGBOX_CHANNEL' ? 'singbox_channel' : 'mihomo_channel'] = val;
        } else if (/^autostart/.test(a)) {
          if (state.status) state.status.settings.auto_start = args[1] === 'true';
        } else if (/^sub autostart/.test(a)) {
          if (state.status) state.status.substore.autostart = args[2] === 'true';
        } else if (/^sub set /.test(a)) {
          var k = args[2];
          var value = b64ToText(args[3] || '');
          if (state.status) {
            if (k === 'SUB_STORE_BACKEND_API_HOST') state.status.substore.host = value;
            if (k === 'SUB_STORE_BACKEND_API_PORT') state.status.substore.port = Number(value);
            if (k === 'SUB_STORE_FRONTEND_PORT') state.status.substore.front_port = Number(value);
            if (k === 'SUB_STORE_BACKEND_MERGE') state.status.substore.merge = value === 'true';
          }
        } else if (/^sub regen-path/.test(a)) {
          if (state.status) state.status.substore.backend_path = '/mock' + Math.random().toString(36).slice(2, 14);
        } else if (/^sub restart/.test(a)) {
          if (state.status) { state.status.substore.running = true; state.status.substore.pid = 3122; }
        }
        if (opts && opts.trim === false) {
          // keep trailing newline for config text
        } else {
          result.stdout = String(result.stdout || '').trim();
        }
        resolve(result);
      }, 120);
    });
  }

  // ----------------------------------------------------------
  // 启动
  // ----------------------------------------------------------
  function boot() {
    detectRuntime();
    state.preview = runtime.preview;
    var savedTheme = 'system';
    try { savedTheme = localStorage.getItem(THEME_KEY) || 'system'; } catch (e) { /* ignore */ }
    var q = new URLSearchParams(window.location.search || '');
    var qTheme = q.get('theme');
    if (qTheme === 'light' || qTheme === 'dark' || qTheme === 'system') savedTheme = qTheme;
    applyTheme(savedTheme, true);
    renderNavIcons();

    if (q.get('nobanner') === '1') document.body.classList.add('hide-preview');
    var hash = String(window.location.hash || '').replace('#', '');
    var initialPage = q.get('page') || hash || 'home';
    if (initialPage !== 'home' && initialPage !== 'core' && initialPage !== 'config' && initialPage !== 'connectivity') initialPage = 'home';
    state.page = initialPage;
    $$('.page').forEach(function (el) { el.classList.toggle('is-active', el.dataset.page === initialPage); });
    $$('.tab').forEach(function (el) {
      var active = el.dataset.nav === initialPage;
      el.classList.toggle('is-active', active);
      if (active) el.setAttribute('aria-current', 'page');
      else el.removeAttribute('aria-current');
    });

    if (initialPage === 'connectivity' && !state.conn.loaded && !state.conn.loading) {
      loadConnectivity();
    }

    if (runtime.preview) {
      state.status = mockStatus();
      state.loading = false;
      syncFormsFromStatus();
    } else {
      // 先用上次缓存秒开，再后台刷新；避免每次进 WebUI 都等 status 命令
      try {
        var cachedRaw = localStorage.getItem(STATUS_CACHE_KEY);
        if (cachedRaw) {
          var cached = JSON.parse(cachedRaw);
          if (cached && cached.ok) {
            state.status = cached;
            state.loading = false;
            syncFormsFromStatus();
          }
        }
      } catch (e2) { /* ignore */ }
    }
    renderTopbar();
    renderPage();
    renderConsole();

    if (window.matchMedia) {
      try {
        var mq = window.matchMedia('(prefers-color-scheme: dark)');
        if (mq.addEventListener) mq.addEventListener('change', function () { if (state.themeMode === 'system') applyTheme('system', true); });
      } catch (e2) { /* ignore */ }
    }

    refreshStatus(true).then(function () {
      if (state.page === 'config') loadConfig(state.config.target);
    });
    startStatusPolling();

    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) refreshStatus(false);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
