/* HA 面板 —— 菜单栏控制面板前端逻辑 */

const H = {
  entities: {},
  order: [],
  meta: {},
  areaNames: {},
  status: 'idle',
  statusMsg: '',
  config: { url: '', token: '' },
  tab: 'devices',
  query: '',
  group: false,
  hideUnavailable: false,
  manageQuery: '',
  manageDomain: 'all',
  manageArea: 'all',
  collapsed: {},
  dragging: false,
  pendingRender: false,
  ready: false,
  seeded: false,
  lastManageSig: '',
  autostart: false,
  noise: true,
  prefsLoaded: false,
  booted: false,
};

const DOMAIN_ICON = {
  light: 'i-light', switch: 'i-switch', input_boolean: 'i-switch',
  cover: 'i-cover', climate: 'i-climate', fan: 'i-fan',
  media_player: 'i-media', scene: 'i-scene', script: 'i-scene',
  button: 'i-bolt', input_button: 'i-bolt', automation: 'i-automation',
  lock: 'i-lock', vacuum: 'i-vacuum', sensor: 'i-sensor', binary_sensor: 'i-sensor',
};

const DOMAIN_LABEL = {
  light: '灯', switch: '开关', input_boolean: '虚拟开关', cover: '窗帘',
  climate: '空调', fan: '风扇', media_player: '影音', scene: '场景',
  script: '脚本', button: '按钮', input_button: '按钮', automation: '自动化',
  lock: '门锁', vacuum: '扫地机', sensor: '传感器', binary_sensor: '传感器',
};

const CONTROLLABLE = new Set(['light', 'switch', 'input_boolean', 'cover', 'climate', 'fan',
  'media_player', 'scene', 'script', 'button', 'input_button', 'automation', 'lock', 'vacuum']);

const HVAC_ZH = {
  off: '关闭', heat: '制热', cool: '制冷', heat_cool: '自动', auto: '自动',
  dry: '除湿', fan_only: '送风',
};

const COLOR_PRESETS = [
  { label: '暖白', hs: [33, 32] },
  { label: '冷白', hs: [210, 8] },
  { label: '红', hs: [0, 92] },
  { label: '橙', hs: [28, 96] },
  { label: '黄', hs: [50, 95] },
  { label: '绿', hs: [125, 78] },
  { label: '青', hs: [185, 82] },
  { label: '蓝', hs: [215, 90] },
  { label: '紫', hs: [270, 80] },
  { label: '粉', hs: [330, 78] },
];

const $ = (s, r = document) => r.querySelector(s);
const isEditing = () => document.activeElement && document.activeElement.tagName === 'INPUT';
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const dom = (id) => id.split('.')[0];
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const icon = (d) => `<svg class="ic"><use href="#${DOMAIN_ICON[d] || 'i-switch'}"/></svg>`;

/* ---------------- bridge ---------------- */
function post(msg) {
  try {
    window.webkit.messageHandlers.ha.postMessage(msg);
  } catch (e) {
    console.warn('bridge unavailable', e);
  }
}

function savePrefs() {
  post({ t: 'prefs', data: { order: H.order, group: H.group, hideUnavailable: H.hideUnavailable, seeded: H.seeded } });
}

/* ---------------- helpers ---------------- */
function isOn(e) {
  const d = dom(e.entity_id);
  if (e.state === 'unavailable' || e.state === 'unknown') return false;
  if (d === 'cover') return e.state === 'open' || e.state === 'opening';
  if (d === 'lock') return e.state === 'locked';
  if (d === 'climate') return e.state !== 'off';
  if (d === 'media_player') return e.state !== 'off' && e.state !== 'standby';
  return e.state === 'on';
}

const isToggleable = (d) => ['light', 'switch', 'input_boolean', 'fan', 'automation'].includes(d);

function stateText(e) {
  const d = dom(e.entity_id);
  const a = e.attributes || {};
  if (e.state === 'unavailable') return '<span class="warn">不可用</span>';
  if (e.state === 'unknown') return '未知';

  if (d === 'light') {
    if (e.state !== 'on') return '已关闭';
    const parts = [];
    const b = a.brightness != null ? Math.round((a.brightness / 255) * 100) : null;
    if (b != null) parts.push(b + '%');
    if (a.color_mode === 'color_temp' && a.color_temp_kelvin) parts.push(a.color_temp_kelvin + 'K');
    else if (a.color_mode === 'hs' || a.color_mode === 'xy') parts.push('彩色');
    return '<b>开启</b>' + (parts.length ? ' · ' + parts.join(' · ') : '');
  }
  if (d === 'switch' || d === 'input_boolean') return e.state === 'on' ? '<b>已开启</b>' : '已关闭';
  if (d === 'automation') return e.state === 'on' ? '<b>运行中</b>' : '已停用';
  if (d === 'fan') {
    if (e.state !== 'on') return '已关闭';
    return '<b>开启</b>' + (a.percentage != null ? ' · ' + a.percentage + '%' : '');
  }
  if (d === 'cover') {
    if (e.state === 'opening') return '正在开启…';
    if (e.state === 'closing') return '正在关闭…';
    if (e.state === 'open') return '<b>已开启</b>' + (a.current_position != null ? ' · ' + a.current_position + '%' : '');
    return '已关闭';
  }
  if (d === 'climate') {
    if (e.state === 'off') return '已关闭';
    let s = '<b>' + (HVAC_ZH[e.state] || e.state) + '</b>';
    if (a.temperature != null) s += ' · 目标 ' + a.temperature + '°';
    if (a.current_temperature != null) s += ' · 室温 ' + a.current_temperature + '°';
    return s;
  }
  if (d === 'media_player') {
    const m = { playing: '<b>播放中</b>', paused: '已暂停', idle: '空闲', off: '已关闭', standby: '待机' };
    return m[e.state] || e.state;
  }
  if (d === 'lock') return e.state === 'locked' ? '<b>已上锁</b>' : '已解锁';
  if (d === 'scene') return '点按执行';
  if (d === 'script') return '点按运行';
  if (d === 'button' || d === 'input_button') return '点按触发';
  if (d === 'vacuum') {
    const m = { cleaning: '清扫中', docked: '已回充', paused: '已暂停', idle: '待机', returning: '返回中', error: '故障' };
    return m[e.state] || e.state;
  }
  const unit = a.unit_of_measurement || '';
  return esc(e.state) + (unit ? ' ' + esc(unit) : '');
}

/* ---------------- controls ---------------- */
function bodyHTML(e, d) {
  const a = e.attributes || {};
  const id = e.entity_id;
  const on = isOn(e);
  const dis = e.state === 'unavailable' ? 'disabled' : '';
  if (d === 'light' && on) return lightBody(e, a, id, dis);
  if (d === 'climate') return climateBody(e, a, id, dis);
  if (d === 'cover') return coverBody(e, a, id, dis);
  if (d === 'fan' && on) return fanBody(e, a, id, dis);
  if (d === 'media_player' && on) return mediaBody(e, a, id, dis);
  if (d === 'lock') return lockBody(e, id, dis);
  if (d === 'vacuum') return vacuumBody(e, id, dis);
  return '';
}

function lightBody(e, a, id, dis) {
  const modes = a.supported_color_modes || [];
  const onlyOnOff = modes.length === 1 && modes[0] === 'onoff';
  const hasBright = !onlyOnOff;
  const hasTemp = modes.includes('color_temp') || (a.min_color_temp_kelvin && a.max_color_temp_kelvin && !modes.length);
  const hasColor = modes.some((m) => ['hs', 'rgb', 'rgbw', 'rgbww', 'xy'].includes(m));
  const pct = a.brightness != null ? Math.round((a.brightness / 255) * 100) : 100;
  let html = '';

  if (hasBright) {
    html += `<div class="ctl"><span class="lbl">亮度</span>
      <input type="range" min="1" max="100" value="${pct}" style="--p:${pct}%"
        data-act="brightness" data-id="${id}" ${dis}><span class="val">${pct}%</span></div>`;
  }
  if (hasTemp) {
    const min = a.min_color_temp_kelvin || 2000;
    const max = a.max_color_temp_kelvin || 6500;
    const cur = a.color_temp_kelvin || Math.round((min + max) / 2);
    const p = Math.round(((cur - min) / (max - min)) * 100);
    html += `<div class="ctl"><span class="lbl">色温</span>
      <input type="range" class="temp" min="${min}" max="${max}" step="50" value="${cur}" style="--p:${p}%"
        data-act="colortemp" data-id="${id}" ${dis}><span class="val">${cur}K</span></div>`;
  }
  if (hasColor) {
    const hs = a.hs_color;
    let dots = COLOR_PRESETS.map((c) => {
      const sel = hs && Math.abs(hs[0] - c.hs[0]) < 8 && Math.abs(hs[1] - c.hs[1]) < 12;
      return `<button class="cdot ${sel ? 'sel' : ''}" title="${c.label}" data-act="color" data-id="${id}"
        data-h="${c.hs[0]}" data-s="${c.hs[1]}" style="background:hsl(${c.hs[0]},${Math.max(c.hs[1], 22)}%,${c.hs[1] < 20 ? 88 : 55}%)" ${dis}></button>`;
    }).join('');
    html += `<div class="colors"><span class="lbl">颜色</span>${dots}
      <button class="cpick ${hs ? 'has' : ''}" title="自定义颜色" data-act="openpicker" data-id="${id}"
        style="${hs ? `--cur:hsl(${hs[0]},${hs[1]}%,55%)` : ''}" ${dis}></button></div>`;
  }
  return html ? `<div class="body">${html}</div>` : '';
}

function climateBody(e, a, id, dis) {
  const modes = a.hvac_modes || ['off', 'cool', 'heat', 'auto'];
  const min = a.min_temp != null ? a.min_temp : 16;
  const max = a.max_temp != null ? a.max_temp : 30;
  const cur = a.temperature != null ? a.temperature : 26;
  const step = a.target_temp_step || 0.5;
  const chips = modes.map((m) =>
    `<button class="mode ${e.state === m ? 'on' : ''}" data-act="hvac" data-id="${id}" data-mode="${m}" ${dis}>${HVAC_ZH[m] || m}</button>`
  ).join('');
  const p = Math.round(((cur - min) / (max - min)) * 100);
  return `<div class="body">
    <div class="modes">${chips}</div>
    <div class="temp-row">
      <div class="temp-big">${cur}<span>°C</span></div>
      <button class="round" data-act="tempdelta" data-id="${id}" data-delta="${-step}" ${dis}>−</button>
      <button class="round" data-act="tempdelta" data-id="${id}" data-delta="${step}" ${dis}>+</button>
      <input type="range" class="temp" min="${min}" max="${max}" step="${step}" value="${cur}" style="--p:${p}%"
        data-act="settemperature" data-id="${id}" ${dis}>
    </div>
  </div>`;
}

function coverBody(e, a, id, dis) {
  const f = a.supported_features || 0;
  const pos = a.current_position != null ? a.current_position : 0;
  const slider = (f & 4) ? `<div class="ctl"><span class="lbl">位置</span>
      <input type="range" min="0" max="100" value="${pos}" style="--p:${pos}%"
        data-act="coverpos" data-id="${id}" ${dis}><span class="val">${pos}%</span></div>` : '';
  return `<div class="body">
    <div class="ctl" style="gap:6px">
      <button class="pill sm" data-act="cover" data-id="${id}" data-svc="open_cover" ${dis}>开启</button>
      <button class="pill sm" data-act="cover" data-id="${id}" data-svc="stop_cover" ${dis}>停止</button>
      <button class="pill sm" data-act="cover" data-id="${id}" data-svc="close_cover" ${dis}>关闭</button>
    </div>${slider}
  </div>`;
}

function fanBody(e, a, id, dis) {
  const canSpeed = (a.supported_features || 0) & 1 || a.percentage != null;
  if (!canSpeed) return '';
  const pct = a.percentage != null ? a.percentage : 0;
  return `<div class="body"><div class="ctl"><span class="lbl">风速</span>
    <input type="range" min="0" max="100" step="1" value="${pct}" style="--p:${pct}%"
      data-act="fanspeed" data-id="${id}" ${dis}><span class="val">${pct}%</span></div></div>`;
}

function mediaBody(e, a, id, dis) {
  const vol = a.volume_level != null ? Math.round(a.volume_level * 100) : 0;
  const playing = e.state === 'playing';
  return `<div class="body">
    <div class="ctl" style="gap:6px;justify-content:flex-start">
      <button class="round" data-act="media" data-id="${id}" data-svc="media_previous_track" ${dis}><svg class="ic"><use href="#i-prev"/></svg></button>
      <button class="round" data-act="media" data-id="${id}" data-svc="media_play_pause" ${dis}><svg class="ic"><use href="#${playing ? 'i-pause' : 'i-play'}"/></svg></button>
      <button class="round" data-act="media" data-id="${id}" data-svc="media_next_track" ${dis}><svg class="ic"><use href="#i-next"/></svg></button>
    </div>
    <div class="ctl"><span class="lbl">音量</span>
      <input type="range" min="0" max="100" value="${vol}" style="--p:${vol}%"
        data-act="volume" data-id="${id}" ${dis}><span class="val">${vol}%</span></div>
  </div>`;
}

function lockBody(e, id, dis) {
  return `<div class="body"><div class="ctl" style="gap:6px">
    <button class="pill sm" data-act="lock" data-id="${id}" data-svc="lock" ${dis}>上锁</button>
    <button class="pill sm" data-act="lock" data-id="${id}" data-svc="unlock" ${dis}>解锁</button>
  </div></div>`;
}

function vacuumBody(e, id, dis) {
  return `<div class="body"><div class="ctl" style="gap:6px">
    <button class="pill sm" data-act="vacuum" data-id="${id}" data-svc="start" ${dis}>开始</button>
    <button class="pill sm" data-act="vacuum" data-id="${id}" data-svc="pause" ${dis}>暂停</button>
    <button class="pill sm" data-act="vacuum" data-id="${id}" data-svc="return_to_base" ${dis}>回充</button>
  </div></div>`;
}

function actionPill(d, id, un) {
  const map = { scene: '执行', script: '运行', button: '触发', input_button: '触发', lock: '', vacuum: '', media_player: '播放' };
  if (d === 'scene' || d === 'script' || d === 'button' || d === 'input_button') {
    return `<button class="pill" data-act="run" data-id="${id}" ${un ? 'disabled' : ''}>${map[d]}</button>`;
  }
  return '';
}

function cardHTML(id) {
  const e = H.entities[id];
  if (!e) return '';
  const d = dom(id);
  const a = e.attributes || {};
  const un = e.state === 'unavailable';
  const on = isOn(e);
  const name = a.friendly_name || id;
  const iconCls = on ? (d === 'light' ? 'ico on' : 'ico on blue') : 'ico';
  const right = isToggleable(d)
    ? `<button class="sw ${on ? 'on' : ''}" data-act="toggle" data-id="${id}" ${un ? 'disabled' : ''}></button>`
    : actionPill(d, id, un);
  const action = isToggleable(d) || ['scene', 'script', 'button', 'input_button'].includes(d)
    ? `data-act="${isToggleable(d) ? 'toggle' : 'run'}" data-id="${id}" style="cursor:pointer"`
    : 'style="cursor:default"';
  return `<section class="card ${on ? '' : 'off'}" data-card="${id}">
    <div class="row" ${action}>
      <div class="${iconCls} ${un ? 'dead' : ''}" ${action}>${icon(d)}</div>
      <div class="txt"><div class="nm">${esc(name)}</div><div class="st">${stateText(e)}</div></div>
      ${right}
    </div>
    ${bodyHTML(e, d)}
  </section>`;
}

/* ---------------- views ---------------- */

/** 用户是否正在文字输入框里打字（此时绝不能重绘，否则焦点和光标位置都会丢） */
function isTyping() {
  const ae = document.activeElement;
  if (!ae) return false;
  if (ae.tagName === 'TEXTAREA') return true;
  return ae.tagName === 'INPUT' && ['text', 'password', 'search', 'number', 'email'].includes(ae.type);
}

function flushRender() {
  if (!H.pendingRender) return;
  if (isTyping() || Picker.open) return;
  H.pendingRender = false;
  render(true);
}

function render(force) {
  if (H.dragging && !force) { H.pendingRender = true; return; }
  // 打字中 / 正在取色：延后重绘，避免把输入框和取色面板冲掉
  if (!force && (isTyping() || Picker.open)) { H.pendingRender = true; return; }
  // 强制重绘会替换整个 DOM，取色面板的锚点会失效，先收起来
  if (Picker.open) Picker.hide();
  const view = $('#view');
  const scroll = view.scrollTop;
  const keep = {};
  $$('[data-keepscroll]').forEach((el) => { keep[el.dataset.keepscroll] = el.scrollTop; });
  const ftrL = $('#ftrLeft');
  const ftrR = $('#ftrRight');
  $$('#tabs .tab').forEach((b) => b.classList.toggle('on', b.dataset.tab === H.tab));
  const gear = document.querySelector('.hdr-actions [data-tab="settings"]');
  if (gear) gear.classList.toggle('on', H.tab === 'settings');

  view.classList.toggle('mgr', H.tab === 'manage');
  if (H.tab === 'devices') view.innerHTML = devicesHTML();
  else if (H.tab === 'manage') view.innerHTML = manageHTML();
  else view.innerHTML = settingsHTML();

  view.scrollTop = H.tab === 'settings' ? 0 : scroll;
  $$('[data-keepscroll]').forEach((el) => {
    const v = keep[el.dataset.keepscroll];
    if (v != null) el.scrollTop = v;
  });
  updateChrome(ftrL, ftrR);
}

const TWO_COL = () => window.innerWidth >= 860;

/** 按顺序把卡片分到左右两列。mode='split' 按整个块的体量对半分（分组用），
 *  'alt' 左右交替（阅读顺序：左、右、左、右） */
function flowColumns(chunks, mode) {
  const items = chunks.filter((c) => c && c.h);
  if (!items.length) return '';
  if (!TWO_COL()) return items.map((c) => c.h).join('');
  const L = [], R = [];
  if (mode === 'split') {
    const total = items.reduce((s, c) => s + (c.w || 1), 0);
    let lw = 0, i = 0;
    for (; i < items.length; i++) {
      const w = items[i].w || 1;
      if (lw > 0 && lw + w > total / 2) break;
      L.push(items[i].h); lw += w;
    }
    for (; i < items.length; i++) R.push(items[i].h);
  } else {
    let lw = 0, rw = 0;
    for (const c of items) {
      if (lw <= rw) { L.push(c.h); lw += c.w || 1; }
      else { R.push(c.h); rw += c.w || 1; }
    }
  }
  return `<div class="cols"><div class="col">${L.join('')}</div><div class="col">${R.join('')}</div></div>`;
}

function updateChrome(ftrL, ftrR) {
  const dot = $('#dot');
  const st = $('#statusText');
  dot.className = 'dot ' + (H.status === 'connected' ? 'ok' : H.status === 'connecting' ? 'warn' : H.status === 'error' ? 'err' : '');
  st.textContent = H.status === 'connected' ? '已连接' : H.statusMsg || '未连接';
  const count = H.order.filter((id) => H.entities[id]).length;
  if (ftrL) ftrL.textContent = H.status === 'connected' ? `${count} 个设备 · ${Object.keys(H.entities).length} 个实体` : '未连接';
  if (ftrR) ftrR.textContent = H.group ? '按房间分组' : 'HA 面板';
}

function devicesHTML() {
  const favs = H.order.filter((id) => H.entities[id]);
  if (!favs.length) {
    const total = Object.keys(H.entities).length;
    return `<div class="empty">
      <svg class="ic"><use href="#i-plus"/></svg>
      <div class="big">还没有添加设备</div>
      <div>${total ? `已读取 ${total} 个实体，去「管理」里挑选要放在面板上的设备` : '正在读取设备…'}</div>
      <button class="pill primary" data-act="tab" data-tab="manage">去添加设备</button>
    </div>`;
  }

  let list = favs;
  if (H.query) {
    const q = H.query.toLowerCase();
    list = favs.filter((id) => {
      const e = H.entities[id] || {};
      const n = (e.attributes && e.attributes.friendly_name) || id;
      return n.toLowerCase().includes(q) || id.toLowerCase().includes(q);
    });
  }
  if (H.hideUnavailable) list = list.filter((id) => H.entities[id].state !== 'unavailable');

  const showSearch = favs.length > 3 || H.query;
  let html = showSearch ? `<div class="search-wrap">
      <label class="search">
        <svg class="ic"><use href="#i-search"/></svg>
        <input type="text" id="q" placeholder="搜索设备" value="${esc(H.query)}" autocomplete="off" spellcheck="false">
      </label>
      <button class="chip-btn ${H.group ? 'on' : ''}" data-act="toggle-group">分组</button>
    </div>` : '';

  html += `<div id="devList">${deviceListHTML(list)}</div>`;
  return html;
}

/** 只渲染设备卡片区（搜索时只换这一块，输入框不受影响） */
function deviceListHTML(list) {
  if (!list.length) {
    return `<div class="empty"><div class="big">没有匹配的设备</div><div>换个关键词试试</div></div>`;
  }

  const chunks = [];
  if (H.group) {
    const groups = new Map();
    for (const id of list) {
      const area = H.meta[id] || '未分配';
      if (!groups.has(area)) groups.set(area, []);
      groups.get(area).push(id);
    }
    const names = Array.from(groups.keys()).sort((a, b) => {
      if (a === '未分配') return 1;
      if (b === '未分配') return -1;
      return a.localeCompare(b, 'zh');
    });
    for (const name of names) {
      const ids = groups.get(name);
      const body = ids.map(cardHTML).filter(Boolean).join('');
      chunks.push({
        h: `<div class="group-hd">${esc(name)}<span class="cnt">${ids.length}</span></div>${body}`,
        w: ids.length + 1,
      });
    }
  } else {
    for (const id of list) {
      const h = cardHTML(id);
      if (!h) continue;
      chunks.push({ h, w: 2 + (h.match(/class="ctl"/g) || []).length });
    }
  }
  return flowColumns(chunks, H.group ? 'split' : 'alt');
}

function refreshDeviceList() {
  const el = $('#devList');
  if (!el) { render(true); return; }
  const favs = H.order.filter((id) => H.entities[id]);
  let list = favs;
  if (H.query) {
    const q = H.query.toLowerCase();
    list = favs.filter((id) => {
      const e = H.entities[id] || {};
      const n = (e.attributes && e.attributes.friendly_name) || id;
      return n.toLowerCase().includes(q) || id.toLowerCase().includes(q);
    });
  }
  if (H.hideUnavailable) list = list.filter((id) => H.entities[id].state !== 'unavailable');
  el.innerHTML = deviceListHTML(list);
}

function manageFiltered() {
  const all = Object.values(H.entities);
  const q = H.manageQuery.toLowerCase();

  let filtered = all.filter((e) => {
    const d = dom(e.entity_id);
    if (H.manageDomain === 'fast' && !CONTROLLABLE.has(d)) return false;
    if (H.manageDomain !== 'all' && H.manageDomain !== 'fast' && d !== H.manageDomain) return false;
    if (H.manageArea !== 'all' && (H.meta[e.entity_id] || '未分配') !== H.manageArea) return false;
    if (q) {
      const n = (e.attributes.friendly_name || '').toLowerCase();
      if (!n.includes(q) && !e.entity_id.toLowerCase().includes(q) && !(H.meta[e.entity_id] || '').toLowerCase().includes(q)) return false;
    }
    return true;
  });
  filtered.sort((a, b) => {
    const ca = CONTROLLABLE.has(dom(a.entity_id)) ? 0 : 1;
    const cb = CONTROLLABLE.has(dom(b.entity_id)) ? 0 : 1;
    if (ca !== cb) return ca - cb;
    const na = a.attributes.friendly_name || a.entity_id;
    const nb = b.attributes.friendly_name || b.entity_id;
    return na.localeCompare(nb, 'zh');
  });
  return { all, filtered };
}

function entityRowsHTML(filtered, sel) {
  return filtered.slice(0, 600).map((e) => {
    const id = e.entity_id;
    const d = dom(id);
    const added = sel.has(id);
    return `<div class="mrow">
      <div class="ico ${isOn(e) ? 'on blue' : ''}">${icon(d)}</div>
      <div class="txt"><div class="nm">${esc(e.attributes.friendly_name || id)}</div>
        <div class="st">${esc(H.meta[id] || '未分配')} · ${esc(DOMAIN_LABEL[d] || d)}</div></div>
      <button class="mini ${added ? 'del' : 'add'}" data-act="${added ? 'remove' : 'add'}" data-id="${id}">
        <svg class="ic"><use href="#${added ? 'i-check' : 'i-plus'}"/></svg></button>
    </div>`;
  }).join('');
}

/** 搜索时只重建右栏列表，不动输入框本身（保住焦点和光标） */
function refreshManageResults() {
  const { all, filtered } = manageFiltered();
  const sel = new Set(H.order);
  const body = $('#allRows');
  if (body) {
    body.innerHTML = entityRowsHTML(filtered, sel) || '<div class="mrow"><div class="st" style="padding:8px 2px">没有匹配的实体</div></div>';
    body.scrollTop = 0;
  }
  const cnt = $('#allCount');
  if (cnt) cnt.textContent = filtered.length;
  const note = $('#matchNote');
  if (note) note.textContent = `匹配 ${filtered.length} / 共 ${all.length}`;
  const addAll = $('#addAll');
  if (addAll) {
    addAll.textContent = `添加全部 (${filtered.length})`;
    addAll.style.display = filtered.length > 1 ? '' : 'none';
  }
}

function manageHTML() {
  const { all, filtered } = manageFiltered();
  const sel = new Set(H.order);
  const domainChips = [
    ['all', '全部'], ['fast', '常用'], ['light', '灯'], ['switch', '开关'], ['climate', '空调'],
    ['cover', '窗帘'], ['fan', '风扇'], ['media_player', '影音'], ['scene', '场景'], ['sensor', '传感器'],
  ];
  const areas = Array.from(new Set(Object.values(H.meta))).sort((a, b) => a.localeCompare(b, 'zh'));

  const favRows = H.order.map((id, i) => {
    const e = H.entities[id];
    if (!e) return '';
    const d = dom(id);
    return `<div class="mrow" draggable="true" data-fav="${id}">
      <div class="ico ${isOn(e) ? 'on blue' : ''}">${icon(d)}</div>
      <div class="txt"><div class="nm">${esc(e.attributes.friendly_name || id)}</div>
        <div class="st">${esc(H.meta[id] || DOMAIN_LABEL[d] || d)}</div></div>
      <button class="mini" data-act="up" data-id="${id}" ${i === 0 ? 'disabled' : ''}><svg class="ic"><use href="#i-up"/></svg></button>
      <button class="mini" data-act="down" data-id="${id}" ${i === H.order.length - 1 ? 'disabled' : ''}><svg class="ic"><use href="#i-down"/></svg></button>
      <button class="mini del" data-act="remove" data-id="${id}"><svg class="ic"><use href="#i-close"/></svg></button>
    </div>`;
  }).join('');

  const chipHTML = domainChips.map(([v, t]) =>
    `<button class="fchip ${H.manageDomain === v ? 'on' : ''}" data-act="mdomain" data-v="${v}">${t}</button>`
  ).join('');

  const areaOpts = ['all'].concat(areas).map((a) =>
    `<option value="${esc(a)}" ${H.manageArea === a ? 'selected' : ''}>${a === 'all' ? '全部房间' : esc(a)}</option>`
  ).join('');

  const rows = entityRowsHTML(filtered, sel);

  return `
  <div class="mgr-top">
    <div class="search-wrap">
      <label class="search">
        <svg class="ic"><use href="#i-search"/></svg>
        <input type="text" id="mq" placeholder="搜索全部实体（名称 / ID / 房间）" value="${esc(H.manageQuery)}" autocomplete="off" spellcheck="false">
      </label>
    </div>
    <div class="filters">${chipHTML}</div>
    <div class="filters" style="padding-bottom:6px">
      <select class="sel" data-act="marea">${areaOpts}</select>
      <button class="fchip" id="addAll" data-act="add-filtered" style="display:${filtered.length > 1 ? '' : 'none'}">添加全部 (${filtered.length})</button>
      <span style="flex:1 1 auto"></span>
      <span class="pane-note" id="matchNote">匹配 ${filtered.length} / 共 ${all.length}</span>
    </div>
  </div>

  <div class="mgr-cols">
    <section class="pane">
      <div class="pane-hd">
        <span>面板设备<span class="cnt">${H.order.length}</span></span>
        <span class="grow"></span>
        <span class="pane-note">拖动 / ↑↓ 排序</span>
        <button class="pill sm" data-act="clear-fav">清空</button>
      </div>
      <div class="pane-body" data-keepscroll="fav">
        ${favRows || '<div class="mrow"><div class="st" style="padding:8px 2px">还没有设备，从右侧点 + 添加 →</div></div>'}
      </div>
    </section>

    <section class="pane">
      <div class="pane-hd">
        <span>全部实体<span class="cnt" id="allCount">${filtered.length}</span></span>
        <span class="grow"></span>
        <span class="pane-note">点 + 加入面板</span>
      </div>
      <div class="pane-body" data-keepscroll="all" id="allRows">
        ${rows || '<div class="mrow"><div class="st" style="padding:8px 2px">没有匹配的实体</div></div>'}
      </div>
    </section>
  </div>`;
}

function settingsHTML() {
  return `
  <div class="settings">
  <div class="mcard"><div class="form">
    <div class="field">
      <label>Home Assistant 地址</label>
      <input type="text" id="cfgUrl" value="${esc(H.config.url)}" placeholder="http://192.168.1.10:8123" spellcheck="false">
    </div>
    <div class="field">
      <label>长期访问令牌</label>
      <input type="password" id="cfgToken" value="${esc(H.config.token)}" placeholder="在 HA 个人资料 → 安全 中创建" spellcheck="false">
    </div>
    <div class="hint">令牌只在本地保存（UserDefaults），不会上传到任何第三方。</div>
    <div class="btn-row">
      <button class="pill" data-act="test">测试连接</button>
      <button class="pill primary" data-act="save">保存并连接</button>
    </div>
    <div class="hint" id="testMsg"></div>
  </div></div>

  <div class="mcard"><div class="form">
    <div class="setrow">
      <div><div class="tt">按房间分组</div><div class="dd">在设备页按 HA 房间归类显示</div></div>
      <button class="sw ${H.group ? 'on' : ''}" data-act="toggle-group"></button>
    </div>
    <div class="setrow">
      <div><div class="tt">隐藏不可用设备</div><div class="dd">离线或不可达的实体不显示</div></div>
      <button class="sw ${H.hideUnavailable ? 'on' : ''}" data-act="toggle-unavailable"></button>
    </div>
    <div class="setrow">
      <div><div class="tt">过滤诊断类推送</div><div class="dd">小米「信息」按钮、固件更新、CPU 占用等空转实体不进界面刷新</div></div>
      <button class="sw ${H.noise ? 'on' : ''}" data-act="toggle-noise"></button>
    </div>
    <div class="setrow">
      <div><div class="tt">开机自动启动</div><div class="dd">登录后自动在菜单栏运行</div></div>
      <button class="sw ${H.autostart ? 'on' : ''}" data-act="toggle-autostart"></button>
    </div>
  </div></div>

  <div class="mcard"><div class="form">
    <div class="setrow"><div><div class="tt">连接状态</div><div class="dd">${esc(H.statusMsg || '—')}</div></div>
      <button class="pill sm" data-act="reconnect">重新连接</button></div>
    <div class="setrow"><div><div class="tt">实体 / 房间</div><div class="dd">${Object.keys(H.entities).length} 个实体 · ${Object.keys(H.areaNames).length} 个房间</div></div></div>
    <div class="setrow"><div><div class="tt">HA 面板 1.0</div><div class="dd">菜单栏控制 · 本地直连</div></div>
      <button class="pill sm" data-act="quit">退出</button></div>
  </div></div>
  </div>`;
}

/* ---------------- actions ---------------- */
function call(domain, service, data) {
  post({ t: 'call', domain, service, data });
}

function toggleEntity(id) {
  const e = H.entities[id];
  if (!e) return;
  const d = dom(id);
  const on = isOn(e);
  if (d === 'automation') return call('automation', on ? 'turn_off' : 'turn_on', { entity_id: id });
  if (d === 'lock') return call('lock', on ? 'unlock' : 'lock', { entity_id: id });
  return call(d, on ? 'turn_off' : 'turn_on', { entity_id: id });
}

function moveFav(id, dir) {
  const i = H.order.indexOf(id);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= H.order.length) return;
  [H.order[i], H.order[j]] = [H.order[j], H.order[i]];
  savePrefs();
  render(true);
  // 保证刚移动的那一行在可视区内（只微调，不跳走）
  const row = document.querySelector(`[data-fav="${id}"]`);
  const box = row && row.closest('.pane-body');
  if (row && box) {
    const r = row.getBoundingClientRect();
    const b = box.getBoundingClientRect();
    if (r.top < b.top) box.scrollTop -= (b.top - r.top + 4);
    else if (r.bottom > b.bottom) box.scrollTop += (r.bottom - b.bottom + 4);
  }
}

function addFav(id, silent) {
  if (!H.order.includes(id)) {
    H.order.push(id);
    if (!silent) savePrefs();
  }
}

function removeFav(id) {
  H.order = H.order.filter((x) => x !== id);
  savePrefs();
  render(true);
}

function toast(msg) {
  let t = $('#toast');
  if (!t) {
    t = document.createElement('div');
    t.id = 'toast';
    t.className = 'toast';
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove('show'), 1700);
}

function hslToHex(h, s, l) {
  s /= 100; l /= 100;
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  const to = (x) => Math.round(x * 255).toString(16).padStart(2, '0');
  return '#' + to(f(0)) + to(f(8)) + to(f(4));
}

function hexToRgb(hex) {
  const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
  return m ? [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)] : [255, 255, 255];
}

/* ---------------- events ---------------- */
document.addEventListener('click', (ev) => {
  const el = ev.target.closest('[data-act]');
  if (!el) return;
  const act = el.dataset.act;
  const id = el.dataset.id;

  switch (act) {
    case 'tab':
      H.tab = el.dataset.tab;
      H.manageQuery = H.tab === 'manage' ? H.manageQuery : H.manageQuery;
      render(true);
      break;
    case 'refresh':
      post({ t: 'refresh' });
      toast('正在刷新');
      break;
    case 'toggle':
      if (id) toggleEntity(id);
      break;
    case 'run': {
      const d = dom(id);
      call(d, 'turn_on', { entity_id: id });
      toast('已执行');
      break;
    }
    case 'toggle-group':
      H.group = !H.group;
      savePrefs();
      render(true);
      break;
    case 'toggle-autostart':
      H.autostart = !H.autostart;
      post({ t: 'autostart', on: H.autostart });
      render(true);
      toast(H.autostart ? '已开启开机自启' : '已关闭开机自启');
      break;
    case 'toggle-noise':
      H.noise = !H.noise;
      post({ t: 'noise', on: H.noise });
      render(true);
      toast(H.noise ? '已过滤诊断类推送' : '已恢复全部推送');
      break;
    case 'toggle-unavailable':
      H.hideUnavailable = !H.hideUnavailable;
      savePrefs();
      render(true);
      break;
    case 'mdomain':
      H.manageDomain = el.dataset.v;
      render(true);
      break;
    case 'add':
      addFav(id);
      render(true);
      break;
    case 'remove':
      removeFav(id);
      break;
    case 'up':
      moveFav(id, -1);
      break;
    case 'down':
      moveFav(id, 1);
      break;
    case 'clear-fav':
      if (H.order.length && confirm('清空面板上的所有设备？')) {
        H.order = [];
        savePrefs();
        render(true);
      }
      break;
    case 'add-filtered': {
      const ids = $$('#view .mrow [data-act="add"]').map((b) => b.dataset.id);
      ids.forEach((i) => addFav(i, true));
      savePrefs();
      render(true);
      toast(`已添加 ${ids.length} 个设备`);
      break;
    }
    case 'cover':
      call('cover', el.dataset.svc, { entity_id: id });
      break;
    case 'hvac':
      call('climate', 'set_hvac_mode', { entity_id: id, hvac_mode: el.dataset.mode });
      break;
    case 'tempdelta': {
      const e = H.entities[id];
      const cur = e.attributes.temperature != null ? e.attributes.temperature : 26;
      const next = Math.round((cur + parseFloat(el.dataset.delta)) * 10) / 10;
      call('climate', 'set_temperature', { entity_id: id, temperature: next });
      break;
    }
    case 'color': {
      const h = +el.dataset.h, s = +el.dataset.s;
      call('light', 'turn_on', { entity_id: id, hs_color: [h, s] });
      break;
    }
    case 'openpicker':
      Picker.openFor(id, el);
      break;
    case 'media':
      call('media_player', el.dataset.svc, { entity_id: id });
      break;
    case 'lock':
      call('lock', el.dataset.svc, { entity_id: id });
      break;
    case 'vacuum':
      call('vacuum', el.dataset.svc, { entity_id: id });
      break;
    case 'save': {
      const url = $('#cfgUrl').value.trim();
      const token = $('#cfgToken').value.trim();
      H.config = { url, token };
      post({ t: 'saveConfig', url, token });
      break;
    }
    case 'test': {
      const url = $('#cfgUrl').value.trim();
      const token = $('#cfgToken').value.trim();
      post({ t: 'test', url, token });
      const m = $('#testMsg');
      if (m) m.textContent = '测试中…';
      break;
    }
    case 'reconnect':
      post({ t: 'reconnect' });
      toast('正在重新连接');
      break;
    case 'quit':
      post({ t: 'quit' });
      break;
  }
});

document.addEventListener('input', (ev) => {
  const el = ev.target;
  if (el.id === 'q') {
    H.query = el.value;
    const v = $('#view');
    const s = v.scrollTop;
    refreshDeviceList();
    v.scrollTop = s;
    return;
  }
  if (el.id === 'mq') {
    H.manageQuery = el.value;
    refreshManageResults();
    return;
  }
  if (el.type === 'range') {
    H.dragging = true;
    const p = ((el.value - el.min) / (el.max - el.min)) * 100;
    el.style.setProperty('--p', p + '%');
    const val = el.parentElement.querySelector('.val');
    const a = el.dataset.act;
    if (val) {
      if (a === 'brightness' || a === 'fanspeed' || a === 'volume' || a === 'coverpos') val.textContent = el.value + '%';
      else if (a === 'colortemp') val.textContent = el.value + 'K';
      else if (a === 'settemperature') {
        const big = el.closest('.temp-row').querySelector('.temp-big');
        if (big) big.innerHTML = el.value + '<span>°C</span>';
      }
    }
    return;
  }
});

document.addEventListener('change', (ev) => {
  const el = ev.target;
  if (el.dataset && el.dataset.act === 'marea') {
    H.manageArea = el.value;
    render(true);
    return;
  }
  if (el.type !== 'range') return;
  H.dragging = false;
  if (H.pendingRender) {
    H.pendingRender = false;
    setTimeout(() => render(), 80);
  }
  const id = el.dataset.id;
  const v = parseFloat(el.value);
  const act = el.dataset.act;
  if (!id) return;

  if (act === 'brightness') {
    call('light', 'turn_on', { entity_id: id, brightness_pct: v });
    patchAttr(id, 'brightness', Math.round((v / 100) * 255));
  } else if (act === 'colortemp') {
    call('light', 'turn_on', { entity_id: id, color_temp_kelvin: v });
    patchAttr(id, 'color_temp_kelvin', v);
  } else if (act === 'fanspeed') {
    call('fan', 'set_percentage', { entity_id: id, percentage: v });
    patchAttr(id, 'percentage', v);
  } else if (act === 'volume') {
    call('media_player', 'volume_set', { entity_id: id, volume_level: v / 100 });
    patchAttr(id, 'volume_level', v / 100);
  } else if (act === 'coverpos') {
    call('cover', 'set_cover_position', { entity_id: id, position: v });
    patchAttr(id, 'current_position', v);
  } else if (act === 'settemperature') {
    call('climate', 'set_temperature', { entity_id: id, temperature: v });
    patchAttr(id, 'temperature', v);
  }
});

function patchAttr(id, key, value) {
  const e = H.entities[id];
  if (!e) return;
  e.attributes = e.attributes || {};
  e.attributes[key] = value;
  const card = document.querySelector(`[data-card="${id}"]`);
  if (!card) return;
  const st = card.querySelector('.st');
  if (st) st.innerHTML = stateText(e);
}

/* ---------------- 自定义取色面板 ---------------- */
function hsvToRgb(h, s, v) {
  const S = s / 100, V = v / 100;
  const C = V * S;
  const X = C * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = V - C;
  let r = 0, g = 0, b = 0;
  if (h < 60) { r = C; g = X; b = 0; }
  else if (h < 120) { r = X; g = C; b = 0; }
  else if (h < 180) { r = 0; g = C; b = X; }
  else if (h < 240) { r = 0; g = X; b = C; }
  else if (h < 300) { r = X; g = 0; b = C; }
  else { r = C; g = 0; b = X; }
  return [r, g, b].map((x) => Math.round((x + m) * 255));
}

const Picker = {
  open: false, id: null, btn: null, el: null,
  h: 30, s: 90, v: 100,
  _timer: 0, _dirty: false,

  build() {
    if (this.el) return;
    const el = document.createElement('div');
    el.className = 'cpicker';
    el.innerHTML = '<div class="cp-hd"><span>自定义颜色</span><i class="cp-val"></i></div>'
      + '<div class="cp-sv"><i class="cp-dot"></i></div>'
      + '<div class="cp-hue"><i class="cp-thumb"></i></div>';
    document.body.appendChild(el);
    this.el = el;
    this.sv = el.querySelector('.cp-sv');
    this.dot = el.querySelector('.cp-dot');
    this.hueEl = el.querySelector('.cp-hue');
    this.thumb = el.querySelector('.cp-thumb');
    this.valEl = el.querySelector('.cp-val');
    this.bindZone(this.sv, (ev) => {
      const r = this.sv.getBoundingClientRect();
      this.s = Math.round(Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width)) * 100);
      this.v = Math.round((1 - Math.min(1, Math.max(0, (ev.clientY - r.top) / r.height))) * 100);
      this.paint();
      this.push();
    });
    this.bindZone(this.hueEl, (ev) => {
      const r = this.hueEl.getBoundingClientRect();
      const x = Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width));
      this.h = Math.min(359, Math.round(x * 360));
      this.paint();
      this.push();
    });
  },

  bindZone(zone, fn) {
    zone.addEventListener('pointerdown', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      try { zone.setPointerCapture(ev.pointerId); } catch (e) { /* ignore */ }
      fn(ev);
      const mv = (e) => fn(e);
      const up = () => {
        zone.removeEventListener('pointermove', mv);
        zone.removeEventListener('pointerup', up);
        zone.removeEventListener('pointercancel', up);
        this.flush();
      };
      zone.addEventListener('pointermove', mv);
      zone.addEventListener('pointerup', up);
      zone.addEventListener('pointercancel', up);
    });
  },

  paint() {
    const [r, g, b] = hsvToRgb(this.h, this.s, this.v);
    const rgb = `rgb(${r},${g},${b})`;
    this.sv.style.background =
      `linear-gradient(to top, #000, rgba(0,0,0,0)), linear-gradient(to right, #fff, hsl(${this.h},100%,50%))`;
    // clamp 让圆点始终完整落在色块内，不会被边缘裁掉一半
    this.dot.style.left = `clamp(7px, ${this.s}%, calc(100% - 7px))`;
    this.dot.style.top = `clamp(7px, ${100 - this.v}%, calc(100% - 7px))`;
    this.dot.style.background = rgb;
    this.thumb.style.left = (this.h / 360 * 100) + '%';
    this.valEl.style.background = rgb;
  },

  push() {
    this._dirty = true;
    if (this._timer) return;
    this._timer = setTimeout(() => {
      this._timer = 0;
      if (this._dirty) this.send();
    }, 90);
  },

  send() {
    this._dirty = false;
    if (!this.id) return;
    const [r, g, b] = hsvToRgb(this.h, this.s, this.v);
    call('light', 'turn_on', { entity_id: this.id, rgb_color: [r, g, b] });
    patchAttr(this.id, 'hs_color', [this.h, this.s]);
    if (this.btn) {
      this.btn.classList.add('has');
      this.btn.style.setProperty('--cur', `rgb(${r},${g},${b})`);
    }
  },

  flush() {
    if (!this._dirty) return;
    if (this._timer) { clearTimeout(this._timer); this._timer = 0; }
    this.send();
  },

  place() {
    if (!this.btn || !this.el) return;
    const r = this.btn.getBoundingClientRect();
    const w = this.el.offsetWidth || 196;
    const h = this.el.offsetHeight || 168;
    let left = r.left + r.width / 2 - w + 14;
    let top = r.bottom + 9;
    if (top + h > window.innerHeight - 8) top = r.top - h - 9;
    if (top < 8) top = 8;
    left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
    this.el.style.left = left + 'px';
    this.el.style.top = top + 'px';
  },

  openFor(id, btn) {
    this.build();
    const e = H.entities[id];
    const hs = e && e.attributes ? e.attributes.hs_color : null;
    if (hs) { this.h = Math.min(359, Math.max(0, Math.round(hs[0]))); this.s = Math.round(hs[1]); }
    else { this.h = 30; this.s = 90; }
    this.v = 100;
    this.open = true;
    this.id = id;
    this.btn = btn;
    this.paint();
    this.el.classList.add('on');
    this.place();
  },

  hide() {
    this.open = false;
    this.id = null;
    this.btn = null;
    this._dirty = false;
    if (this._timer) { clearTimeout(this._timer); this._timer = 0; }
    if (this.el) this.el.classList.remove('on');
  },

  close(soft) {
    if (!this.open) return;
    this.flush();
    this.hide();
    if (soft) this._pendingClose = true;   // 等这次点击走完再重绘，避免把点击目标替换掉
    else flushRender();
  },
};

document.addEventListener('pointerdown', (ev) => {
  if (!Picker.open) return;
  if (ev.target.closest('.cpicker') || ev.target.closest('[data-act="openpicker"]')) return;
  Picker.close(true);
}, true);

document.addEventListener('pointerup', () => {
  if (!Picker._pendingClose) return;
  Picker._pendingClose = false;
  setTimeout(flushRender, 0);
}, true);

document.addEventListener('scroll', () => { if (Picker.open) Picker.place(); }, true);

/* drag reorder in manage */
let dragSrc = null;
document.addEventListener('dragstart', (ev) => {
  const row = ev.target.closest('[data-fav]');
  if (!row) return;
  dragSrc = row.dataset.fav;
  row.classList.add('dragging');
  ev.dataTransfer.effectAllowed = 'move';
});
document.addEventListener('dragover', (ev) => {
  const row = ev.target.closest('[data-fav]');
  if (!row || !dragSrc) return;
  ev.preventDefault();
  $$('[data-fav]').forEach((r) => r.classList.remove('drag-over'));
  if (row.dataset.fav !== dragSrc) row.classList.add('drag-over');
});

/* 拖到列表边缘时自动滚动，长列表也能拖到任意位置 */
let edgeScrollTimer = null;
document.addEventListener('dragover', (ev) => {
  if (!dragSrc) return;
  const box = ev.target.closest('.pane-body');
  if (edgeScrollTimer) return;
  if (!box || box.scrollHeight <= box.clientHeight + 2) return;
  const r = box.getBoundingClientRect();
  const edge = 46;
  let dy = 0;
  if (ev.clientY < r.top + edge) dy = -10;
  else if (ev.clientY > r.bottom - edge) dy = 10;
  if (!dy) return;
  edgeScrollTimer = setInterval(() => {
    if (!dragSrc) { clearInterval(edgeScrollTimer); edgeScrollTimer = null; return; }
    const before = box.scrollTop;
    box.scrollTop += dy;
    if (box.scrollTop === before) { clearInterval(edgeScrollTimer); edgeScrollTimer = null; }
  }, 40);
  box.scrollTop += dy;
});

document.addEventListener('drop', (ev) => {
  const row = ev.target.closest('[data-fav]');
  if (edgeScrollTimer) { clearInterval(edgeScrollTimer); edgeScrollTimer = null; }
  if (!row || !dragSrc) return;
  ev.preventDefault();
  const target = row.dataset.fav;
  if (target !== dragSrc) {
    const from = H.order.indexOf(dragSrc);
    const to = H.order.indexOf(target);
    H.order.splice(from, 1);
    H.order.splice(to, 0, dragSrc);
    savePrefs();
    render(true);
  }
  dragSrc = null;
});

document.addEventListener('dragend', () => {
  $$('[data-fav]').forEach((r) => r.classList.remove('dragging', 'drag-over'));
  dragSrc = null;
  if (edgeScrollTimer) { clearInterval(edgeScrollTimer); edgeScrollTimer = null; }
});

/* ---------------- native messages ---------------- */
window.hb = {
  receive(json) {
    let m;
    try { m = JSON.parse(json); } catch (e) { return; }
    switch (m.t) {
      case 'config':
        H.config = { url: m.url || '', token: m.token || '' };
        H.autostart = !!m.autostart;
        H.noise = m.noise !== false;
        if (H.tab === 'settings' && !isEditing()) render(true);
        break;
      case 'status':
        H.status = m.state;
        H.statusMsg = m.msg;
        updateChrome($('#ftrLeft'), $('#ftrRight'));
        if (H.tab === 'settings' && !isEditing()) render(true);
        break;
      case 'states':
        applyStates(m.data || []);
        break;
      case 'entity':
        applyStates([m.data]);
        break;
      case 'entities':
        applyStates(m.data || []);
        break;
      case 'meta':
        H.meta = m.areas || {};
        H.areaNames = m.areaNames || {};
        if (H.tab !== 'settings') render();
        break;
      case 'prefs':
        applyPrefs(m.data || {});
        break;
      case 'testResult': {
        const el = $('#testMsg');
        if (el) {
          el.textContent = m.msg;
          el.style.color = m.ok ? 'var(--green)' : 'var(--red)';
        }
        toast(m.ok ? '连接正常' : m.msg);
        break;
      }
      case 'toast':
        toast(m.msg || '');
        break;
      case 'shown':
        if (Picker.open) Picker.hide();
        if (H.tab === 'devices') render();
        break;
    }
  },
};

function applyPrefs(p) {
  H.prefsLoaded = true;
  if (Array.isArray(p.order)) H.order = p.order.slice();
  if (typeof p.group === 'boolean') H.group = p.group;
  if (typeof p.hideUnavailable === 'boolean') H.hideUnavailable = p.hideUnavailable;
  if (typeof p.seeded === 'boolean') H.seeded = p.seeded;
  // 只有确认读过偏好、且确实没有存过，才做首次播种
  if (H.ready && !H.order.length && !H.seeded) maybeSeed();
  render(true);
}

function applyStates(list) {
  for (const s of list) {
    if (!s || !s.entity_id) continue;
    H.entities[s.entity_id] = s;
  }
  if (!H.ready) { H.ready = true; }
  if (H.ready && H.prefsLoaded && !H.seeded && !H.order.length) maybeSeed();
  render();
}

function maybeSeed() {
  if (H.seeded || H.order.length) return;
  const wanted = ['light', 'climate', 'cover', 'media_player', 'fan'];
  const seen = new Set();
  const picked = [];
  for (const e of Object.values(H.entities)) {
    const d = dom(e.entity_id);
    if (!wanted.includes(d) || e.state === 'unavailable') continue;
    const key = (e.attributes.friendly_name || e.entity_id) + '|' + (H.meta[e.entity_id] || '');
    if (seen.has(key)) continue;
    seen.add(key);
    picked.push(e.entity_id);
  }
  H.order = picked.slice(0, 30);
  H.seeded = true;
  savePrefs();
}

document.addEventListener('keydown', (ev) => {
  if (ev.key === 'Escape') {
    if (Picker.open) { Picker.close(); return; }
    const q = $('#q') || $('#mq');
    if (q && document.activeElement === q) { q.blur(); return; }
    post({ t: 'hide' });
    return;
  }
  if (ev.key === '/' && !isEditing()) { const q = $('#q'); if (q) { ev.preventDefault(); q.focus(); } }
  if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === 'f') {
    const q = $('#q') || $('#mq');
    if (q) { ev.preventDefault(); q.focus(); q.select(); }
  }
});

/* 打字结束后补一次重绘（延迟到点击手势之后，避免按钮被替换掉导致点击丢失） */
document.addEventListener('focusout', () => {
  setTimeout(flushRender, 160);
});

/* boot：脚本在 body 末尾，直接发 ready，避免「状态先到、偏好后到」把用户列表冲掉 */
function boot() {
  updateChrome($('#ftrLeft'), $('#ftrRight'));
  if (!H.booted) { H.booted = true; post({ t: 'ready' }); }
}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}
