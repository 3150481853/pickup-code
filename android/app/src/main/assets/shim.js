// 安卓侧桥接：让为 iOS 写的 pickup-agent.js 不用改一行就能跑。
// iOS 里是 window.webkit.messageHandlers.pickup.postMessage(obj)，
// 这里用 addJavascriptInterface 注入的 Pickup 对象转一手。
(function () {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pickup) {
    return;
  }
  if (!window.Pickup) { return; }
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.pickup = {
    postMessage: function (o) {
      try { window.Pickup.post(JSON.stringify(o)); } catch (e) { /* 忽略 */ }
    }
  };
})();
