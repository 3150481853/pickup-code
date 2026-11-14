// ==UserScript==
// @name         取件聚合·淘宝/菜鸟
// @namespace    https://local/pdd-pickup
// @version      0.1.0
// @description  淘宝/菜鸟官方取件页的轻度整理：收掉「您需要登录才能继续访问」横条，让内嵌登录 iframe 占满屏幕
// @match        https://pages-fast.m.taobao.com/*
// @match        https://page.cainiao.com/*
// @match        https://*.taobao.com/*
// @match        https://*.cainiao.com/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

/*
 * 只做一件事：官方页面把「您需要登录才能继续访问」这条外层标题画在顶部，
 * 登录表单在跨域 iframe 里，被这条标题挤下去一截，手机上看着像没加载出来。
 * 这里只藏那条标题，并把内嵌 iframe 顶上来的偏移归零。
 * 不碰 iframe 的 src、不碰表单、不代替提交。
 */

(function () {
  'use strict';

  var BANNER = '您需要登录才能继续访问';

  function visible(el) {
    return !!el && el.getClientRects().length > 0;
  }

  function liftFrames() {
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      var f = frames[i];
      var cs = getComputedStyle(f);
      var top = parseFloat(cs.top) || 0;
      var mt = parseFloat(cs.marginTop) || 0;
      if (top > 0) f.style.top = '0px';
      if (mt > 0) f.style.marginTop = '0px';
      if (f.getBoundingClientRect().height < 200) f.style.minHeight = '100vh';
    }
  }

  function hideBanner() {
    var nodes = document.querySelectorAll('div,section,header,p,span,a');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (!visible(el)) continue;
      var t = (el.textContent || '').replace(/\s+/g, '');
      if (t.indexOf(BANNER) < 0) continue;
      if (el.querySelector && el.querySelector('iframe')) continue;   // 别把登录表单一起藏了
      if (el.getBoundingClientRect().height > 90) continue;
      el.style.display = 'none';
    }
    liftFrames();
  }

  function boot() {
    var style = document.createElement('style');
    style.textContent = 'iframe{max-width:100vw !important;}';
    (document.head || document.documentElement).appendChild(style);

    hideBanner();

    var timer = null;
    var mo = new MutationObserver(function () {
      if (timer) return;
      timer = setTimeout(function () { timer = null; hideBanner(); }, 400);
    });
    mo.observe(document.documentElement, { childList: true, subtree: true });

    setInterval(hideBanner, 1500);   // 兜底，页面是 SPA 会重绘
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
