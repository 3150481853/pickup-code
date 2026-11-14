// ==UserScript==
// @name         拼多多取件码·极简
// @namespace    https://local/pdd-pickup
// @version      0.1.0
// @description  让拼多多身份码页在 iOS Safari / 电脑浏览器里能正常登录，去掉推荐和广告块，只留身份码与待取包裹，身份码可放大
// @match        https://m.pinduoduo.net/mdkd/*
// @match        https://m.pinduoduo.net/index.html*
// @match        https://m.pinduoduo.net/login.html*
// @run-at       document-start
// @grant        none
// ==/UserScript==

/*
 * 这个脚本只做两件事，别的一概不碰：
 * 1) 把身份码页原本发往 https://api.pinduoduo.com/api/... 的业务请求，
 *    改发到拼多多自己的同源官方路由 https://m.pinduoduo.net/proxy/api/api/...
 *    不改 Cookie、不改请求头、不代发任何请求，只是换了个同源地址。
 *    （不发这一步，登录后页面会一直弹回登录页，实测请求直接 424）
 * 2) 页面出来后，把推荐 / 广告之类的块藏掉，身份码点一下放大。
 */

(function () {
  'use strict';

  // ---------- 一、同源改路（必须在 document-start 完成） ----------
  var API_HOST = 'api.pinduoduo.com/api/';
  var SAME_HOST = 'm.pinduoduo.net/proxy/api/api/';

  // 诊断用：改写过多少条、最近几条长什么样
  if (!window.__pddMap) { window.__pddMap = { count: 0, log: [] }; }
  function mapLog(kind, from, to) {
    var L = window.__pddMap.log;
    L.push(kind + ' ' + from + (to && to !== from ? '  ->  ' + to : '  (未改)'));
    if (L.length > 30) { L.splice(0, L.length - 30); }
  }

  function remap(u) {
    if (typeof u !== 'string') { return u; }
    var i = u.indexOf(API_HOST);
    if (i < 0) { return u; }
    window.__pddMap.count++;
    return u.slice(0, i) + SAME_HOST + u.slice(i + API_HOST.length);
  }

  // 注意：这里**不再**跳过登录页。
  // 登录页自己也要发 POST https://api.pinduoduo.com/api/apoc/...pre/check，
  // 那条同样因为跨站拿不到 Cookie 而 424 —— 登录验证永远过不去，
  // 表现就是「输完验证码 / 密码，又弹回登录页」。所以全站一律改写。
  var origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      try {
        if (typeof input === 'string') {
          var nu = remap(input);
          mapLog('fetch', input, nu);
          input = nu;
        } else if (input && typeof input === 'object' && typeof input.url === 'string') {
          var nu2 = remap(input.url);
          mapLog('fetch', input.url, nu2);
          if (nu2 !== input.url && typeof Request === 'function') {
            input = new Request(nu2, input);
          }
        }
      } catch (e) { /* 映射失败就走原请求 */ }
      return origFetch.call(this, input, init);
    };
  }

  // XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function () {
    var a = Array.prototype.slice.call(arguments);
    if (a.length > 1) {
      var nu = remap(a[1]);
      mapLog('xhr', String(a[1]), nu);
      a[1] = nu;
    }
    return origOpen.apply(this, a);
  };

  // sendBeacon（有就顺手一起）
  if (navigator.sendBeacon) {
    var origBeacon = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = function (u, d) { return origBeacon(remap(u), d); };
  }

  // 是否跑在自签 App 的壳里：壳里有自己的首页和按钮，页面里那个「简」就别出来抢位置
  var IN_SHELL = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pickup);

  // ---------- 二、页面整理 ----------
  var HIDE_KEY = 'pddpickup.hidden.v1';
  var muted = false;      // 精简模式开关
  var picking = false;    // 圈选模式开关
  var hidden = [];
  try { hidden = JSON.parse(localStorage.getItem(HIDE_KEY) || '[]') || []; } catch (e) { hidden = []; }

  var JUNK = /(推荐|猜你喜欢|百亿补贴|拼小圈|天天领现金|限时秒杀|开通会员|去拼单|广告|为你精选|更多好物|领取红包)/;
  var KEEP = /(身份码|取件|包裹|驿站|自提|条码|出库)/;

  function looksJunk(el) {
    var t = (el.textContent || '').replace(/\s+/g, '');
    if (!t || t.length > 300) return false;
    return JUNK.test(t) && !KEEP.test(t);
  }

  // 从命中的小节点往上爬到「整块都是垃圾」的最高祖先
  function junkBlock(el) {
    var cur = el, best = el;
    while (cur && cur !== document.body && cur !== document.documentElement) {
      if (!looksJunk(cur)) break;
      best = cur;
      cur = cur.parentElement;
    }
    return best;
  }

  // 稳定的节点路径，用来记住手动隐藏了哪块
  function pathOf(el) {
    var parts = [];
    var cur = el;
    while (cur && cur.nodeType === 1 && cur !== document.body) {
      var i = 0, s = cur;
      while ((s = s.previousElementSibling)) i++;
      parts.unshift(cur.tagName + ':' + i);
      cur = cur.parentElement;
    }
    return parts.join('/');
  }

  function elAt(path) {
    var cur = document.body;
    var parts = String(path).split('/');
    for (var i = 0; i < parts.length; i++) {
      if (!cur) return null;
      var seg = parts[i].split(':');
      var idx = parseInt(seg[1], 10);
      var kids = cur.children, n = 0, next = null;
      for (var k = 0; k < kids.length; k++) {
        if (kids[k].tagName === seg[0]) {
          if (n === idx) { next = kids[k]; break; }
          n++;
        }
      }
      cur = next;
    }
    return cur;
  }

  function applyHidden() {
    var i;
    for (i = 0; i < hidden.length; i++) {
      var el = elAt(hidden[i]);
      if (el) el.style.display = 'none';
    }
  }

  function sweepJunk() {
    if (!muted) return;
    var nodes = document.querySelectorAll('#__next *:not(script):not(style)');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (!el.offsetParent && el.offsetHeight === 0) continue;
      if (!looksJunk(el)) continue;
      var block = junkBlock(el);
      if (block && block !== document.body) block.style.display = 'none';
    }
  }

  function hideEl(el) {
    if (!el || el === document.body || el === document.documentElement) return;
    el.style.display = 'none';
    var p = pathOf(el);
    if (hidden.indexOf(p) < 0) hidden.push(p);
    try { localStorage.setItem(HIDE_KEY, JSON.stringify(hidden)); } catch (e) {}
  }

  // ---------- 三、身份码放大 ----------
  function overlay(src) {
    var old = document.getElementById('pdd-big');
    if (old) { old.remove(); return; }
    var box = document.createElement('div');
    box.id = 'pdd-big';
    box.style.cssText = 'position:fixed;inset:0;z-index:2147483646;background:#fff;display:flex;' +
      'align-items:center;justify-content:center;touch-action:manipulation';
    var img = document.createElement('img');
    img.src = src;
    img.style.cssText = 'width:92vw;max-width:92vh;transform:rotate(90deg);background:#fff';
    box.appendChild(img);
    box.addEventListener('click', function () { box.remove(); });
    document.body.appendChild(box);
  }

  function bindBigCode() {
    document.addEventListener('click', function (ev) {
      if (picking) return;
      var t = ev.target;
      if (!t || t.tagName !== 'IMG') return;
      if (t.naturalWidth < 120 || t.naturalHeight < 120) return;
      var scope = t.closest && t.closest('#__next');
      if (!scope) return;
      var near = t.parentElement ? (t.parentElement.textContent || '') : '';
      if (!/身份码|取件|条码/.test(near) && t.naturalWidth < 240) return;
      ev.preventDefault();
      ev.stopPropagation();
      overlay(t.currentSrc || t.src);
    }, true);
  }

  // ---------- 四、小按钮 ----------
  var btn, pressTimer;

  function makeButton() {
    btn = document.createElement('div');
    btn.id = 'pdd-tools';
    btn.textContent = '简';
    btn.style.cssText = 'position:fixed;right:10px;bottom:calc(env(safe-area-inset-bottom, 0px) + 96px);' +
      'z-index:2147483645;width:38px;height:38px;border-radius:19px;' +
      'background:rgba(255,44,85,.14);color:#ff2c55;font:600 13px/38px -apple-system,"PingFang SC";' +
      'text-align:center;user-select:none;-webkit-user-select:none;opacity:.5';

    function refresh() {
      btn.style.opacity = (muted || picking) ? '1' : '.5';
      btn.style.background = picking ? 'rgba(255,44,85,.85)' : 'rgba(255,44,85,.14)';
      btn.style.color = picking ? '#fff' : '#ff2c55';
      btn.textContent = picking ? '选' : (muted ? '简' : '简');
    }
    refresh();

    btn.addEventListener('touchstart', function (e) {
      pressTimer = setTimeout(function () {
        pressTimer = null;
        picking = !picking;
        document.body.classList.toggle('pdd-picking', picking);
        if (!picking) { muted = false; location.reload(); }
        refresh();
      }, 550);
      e.stopPropagation();
    }, { passive: true });

    btn.addEventListener('touchend', function (e) {
      e.stopPropagation();
      if (pressTimer) {
        clearTimeout(pressTimer);
        pressTimer = null;
        muted = !muted;
        if (muted) sweepJunk();
        else location.reload();   // 取消精简：直接重载最省事
        refresh();
      }
    });

    // 电脑上调试用
    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      muted = !muted;
      if (muted) sweepJunk(); else location.reload();
      refresh();
    });

    document.body.appendChild(btn);
  }

  // 圈选模式：长按页面里的任意块把它藏起来
  function bindPicker() {
    var timer = null, target = null;
    document.addEventListener('touchstart', function (e) {
      if (!picking) return;
      target = e.target;
      if (!target || target.id === 'pdd-tools') return;
      timer = setTimeout(function () {
        timer = null;
        hideEl(target);
        if (navigator.vibrate) navigator.vibrate(15);
      }, 500);
    }, { passive: true });
    document.addEventListener('touchend', function () {
      if (timer) { clearTimeout(timer); timer = null; }
    }, { passive: true });
    document.addEventListener('touchmove', function () {
      if (timer) { clearTimeout(timer); timer = null; }
    }, { passive: true });
  }

  // ---------- 五、启动 ----------
  // 拼多多「请确认继续用当前账号登录」那一屏的「快速进入」是要拉拼多多 App 的，
  // 壳里把 pinduoduo:// 拦掉了，所以点了等于没反应。把它藏掉，留一条能走通的路。
  // 注意：只在拼多多域名下动手 —— 淘系的「快速进入」是网页内 SSO，必须能点。
  function fixLoginConfirm() {
    var h = (location.hostname || '').toLowerCase();
    if (h.indexOf('pinduoduo') < 0 && h.indexOf('yangkeduo') < 0) return;
    var nodes = document.querySelectorAll('div,button,span,a');
    var hit = null;
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.childElementCount === 0 && (el.textContent || '').trim() === '快速进入') { hit = el; break; }
    }
    if (!hit) return;
    var btn = hit.parentNode || hit;
    if (btn.getAttribute('data-pdd-hidden') === '1') return;
    btn.setAttribute('data-pdd-hidden', '1');
    btn.style.display = 'none';
    var tip = document.createElement('div');
    tip.textContent = '「快速进入」要跳到拼多多 App，这个壳里用不了。请点下面的「使用其他账号登录」，用手机号或扫码登录。';
    tip.setAttribute('style', 'margin:10px 16px;padding:10px 12px;border-radius:8px;'
      + 'background:#fff3f5;color:#c81e3c;font-size:12px;line-height:1.6;');
    btn.parentNode.insertBefore(tip, btn);
  }

  function boot() {
    var style = document.createElement('style');
    style.textContent = [
      'html,body{background:#fff !important;}',
      '#__next{overflow-x:hidden;}',
      'body.pdd-picking{-webkit-touch-callout:none;}',
      'body.pdd-picking #__next *{outline:1px dashed rgba(255,44,85,.35);}'
    ].join('\n');
    document.head.appendChild(style);

    applyHidden();
    if (!IN_SHELL) {
      makeButton();
      bindPicker();
    }
    bindBigCode();
    fixLoginConfirm();

    // SPA 会不停重绘，节流后再扫一遍
    var t = null;
    var mo = new MutationObserver(function () {
      if (t) return;
      t = setTimeout(function () {
        t = null;
        applyHidden();
        sweepJunk();
        fixLoginConfirm();
      }, 600);
    });
    var root = document.getElementById('__next') || document.body;
    mo.observe(root, { childList: true, subtree: true });

    // 调试：地址后面加 ?pddpick=1 可以看出哪些块在页面上
    if (/[?&]pddpick=1/.test(location.search)) {
      muted = true;
      sweepJunk();
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
