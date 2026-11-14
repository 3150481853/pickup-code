/* 注入到每个站点的 WebView：把「待取件」抓出来推给原生，并顺手修掉几个网页在壳里的小毛病。
   原生收到 { site, state, items:[{code, station, place, raw}] }。

   拼多多走官方 DOM（见 HandyCode 的 pdd-layout.js）：
     [class*="package-list-wrapper"] .package-list-picking   -> 一个包裹
       .package-code-value  取件码
       .station-name        驿站名
       .package-tags        货架/状态等
   淘宝/菜鸟没有稳定结构，退化成「取件码正则 + 就近文本」的启发式。 */
(function () {
    if (window.__pickupAgentLoaded) { return; }
    window.__pickupAgentLoaded = true;

    var HOST = location.hostname || '';
    var SITE = HOST.indexOf('pinduoduo') >= 0 || HOST.indexOf('yangkeduo') >= 0 ? 'pdd' : 'taobao';

    var CODE = /\b\d{1,3}-\d{1,2}-\d{3,6}\b/;
    var CODE_G = /\b\d{1,3}-\d{1,2}-\d{3,6}\b/g;
    var STATION = /([\u4e00-\u9fa5A-Za-z0-9（）()·]{2,20}?(?:驿站|服务站|自提点|快递柜|快递中心|代收点|门店|超市|便利店))/;
    var PLACE = /((?:货架|货位|取件位|位置|柜机|柜号|货架号)[:：]?\s*[A-Za-z0-9\-]{1,10}|[A-Z]?\d{1,2}\s*号?\s*(?:架|柜|排|层))/;
    var LOGIN_HINT = /(您需要登录才能继续访问|请登录|手机登录|扫码登录|验证码)/;

    // 页面自己的 console.error 也存一份，诊断页能直接看到「为什么挂了」
    var CONSOLE = [];
    try {
        ['error', 'warn'].forEach(function (k) {
            var orig = console[k];
            console[k] = function () {
                try {
                    var s = Array.prototype.map.call(arguments, function (a) { return String(a); }).join(' ');
                    CONSOLE.push(k + ': ' + s.slice(0, 200));
                    if (CONSOLE.length > 30) { CONSOLE.splice(0, CONSOLE.length - 30); }
                } catch (e) { /* 忽略 */ }
                return orig.apply(console, arguments);
            };
        });
    } catch (e) { /* 忽略 */ }

    function norm(s) {
        return (s || '').replace(/[\s\u200b]+/g, ' ').trim();
    }

    function post(items, state) {
        try {
            window.webkit.messageHandlers.pickup.postMessage({
                site: SITE,
                state: state || '',
                items: items || []
            });
        } catch (e) { /* 浏览器里调试时忽略 */ }
    }

    function pushUnique(out, seen, code, station, place, raw) {
        if (!code || seen[code]) { return; }
        seen[code] = true;
        out.push({
            code: code,
            station: station || '',
            place: place || '',
            raw: raw || ''
        });
    }

    // ---- 拼多多：官方结构 ----
    function collectPdd() {
        var out = [];
        var seen = Object.create(null);
        var nodes = document.querySelectorAll('[class*="package-list-picking"]');
        for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            var codeEl = n.querySelector('[class*="package-code-value"]') ||
                         n.querySelector('[class*="package-code"]');
            var codeTxt = norm(codeEl ? codeEl.textContent : '');
            var m = codeTxt.match(CODE) || norm(n.textContent).match(CODE);
            if (!m) { continue; }
            var st = n.querySelector('[class*="station-name"]');
            var tags = n.querySelector('[class*="package-tags"]');
            var raw = norm(n.textContent);
            pushUnique(out, seen, m[0],
                st ? norm(st.textContent) : '',
                tags ? norm(tags.textContent).slice(0, 20) : '',
                raw.length > 90 ? raw.slice(0, 90) : raw);
        }
        return out;
    }

    // ---- 通用启发式（淘宝/菜鸟，以及拼多多改版后的兜底）----
    // 两遍扫：先给每个码找到「文本最短」的元素（最贴近码本身），
    // 再从这个元素往上爬到卡片层，借它的文本拿驿站名和货架号。
    function collectGeneric() {
        var out = [];
        var seen = Object.create(null);
        var nodes = document.querySelectorAll('div,li,section,article,dd,tr,a,span,p');
        var best = Object.create(null);
        for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            var t = norm(el.innerText || el.textContent);
            if (!t || t.length < 6 || t.length > 200) { continue; }
            var m = t.match(CODE);
            if (!m) { continue; }
            var prev = best[m[0]];
            if (!prev || t.length < prev.len) { best[m[0]] = { el: el, len: t.length }; }
        }
        Object.keys(best).forEach(function (code) {
            var el = best[code].el;
            var ctx = norm(el.innerText || el.textContent);
            var a = el.parentElement;
            for (var hop = 0; a && hop < 5; hop++, a = a.parentElement) {
                var at = norm(a.innerText || a.textContent);
                if (!at || at.length > 120) { break; }
                if ((at.match(CODE_G) || []).length > 1) { break; }  // 再往上就是列表了
                ctx = at;
            }
            var sm = ctx.match(STATION);
            var pm = ctx.match(PLACE);
            pushUnique(out, seen, code, sm ? sm[1] : '', pm ? norm(pm[1]) : '',
                ctx.length > 90 ? ctx.slice(0, 90) : ctx);
        });
        return out;
    }

    function collect() {
        var items = SITE === 'pdd' ? collectPdd() : [];
        if (!items.length) { items = collectGeneric(); }
        return items;
    }

    function stateOf(items) {
        var body = document.body ? norm(document.body.textContent) : '';
        if (items.length) { return '抓到 ' + items.length + ' 件'; }
        if (document.querySelector('[class*="package-none-container"]')) { return '没有待取件'; }
        if (LOGIN_HINT.test(body)) { return '未登录 / 登录中'; }
        if (body.length < 200) { return '页面空白，可能被拦截'; }
        return '没抓到取件码';
    }

    window.__pickupCollect = function () {
        var items = collect();
        post(items, stateOf(items));
        return items.length;
    };

    // 给「诊断」页用：一句话说清「这个页面现在到底卡在哪」
    window.__pickupDiagnostics = function () {
        var body = document.body ? norm(document.body.textContent) : '';
        var frames = [];
        var fs = document.querySelectorAll('iframe');
        for (var i = 0; i < fs.length && i < 6; i++) {
            frames.push(String(fs[i].src || '(无 src)').slice(0, 110));
        }
        var o = {
            site: SITE,
            url: location.href.slice(0, 200),
            title: document.title,
            ready: document.readyState,
            bodyLen: body.length,
            head: body.slice(0, 160),
            loginish: LOGIN_HINT.test(body),
            pddCards: document.querySelectorAll('[class*="package-list-picking"]').length,
            noneBox: !!document.querySelector('[class*="package-none-container"]'),
            frames: frames,
            items: collect(),
            map: window.__pddMap || null,
            console: CONSOLE,
            ua: (navigator.userAgent || '').slice(0, 120)
        };
        return JSON.stringify(o);
    };

    var timer = 0;
    function schedule(delay) {
        clearTimeout(timer);
        timer = setTimeout(function () {
            try { window.__pickupCollect(); } catch (e) {}
        }, delay || 1200);
    }
    try {
        new MutationObserver(function () { schedule(1600); })
            .observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}

    // ---- 壳里的三处修补 ----

    // 1) window.open / target=_blank：壳里没有第二个 webview，就地跳转，
    //    否则淘宝「输完验证码」那一下点了没反应。
    window.open = function (url) {
        if (url && typeof url === 'string') { location.href = url; }
        return null;
    };
    document.addEventListener('click', function (e) {
        var a = e.target && e.target.closest ? e.target.closest('a[target=_blank]') : null;
        if (a && a.href) {
            e.preventDefault();
            location.href = a.href;
        }
    }, true);

    // 2) 拼多多登录页那个「打开拼多多App」按钮：壳里点了只会跳走，直接不响应
    document.addEventListener('click', function (e) {
        if (SITE !== 'pdd') { return; }
        var node = e.target;
        for (var d = 0; node && node !== document.body && d < 6; d++, node = node.parentElement) {
            var txt = norm(node.textContent).replace(/[\u200b\ue000-\uf8ff]/g, '').toLowerCase();
            if (txt === '打开拼多多app') {
                e.preventDefault();
                e.stopImmediatePropagation();
                return;
            }
        }
    }, true);

    // 3) 淘宝登录横条「您需要登录才能继续访问」会挤掉登录框的高度
    function fixTaobaoLoginChrome() {
        if (SITE === 'pdd') { return; }
        var frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
            var f = frames[i];
            var st = getComputedStyle(f);
            if (parseFloat(st.top) > 0) { f.style.top = '0px'; }
            if (parseFloat(st.marginTop) > 0) { f.style.marginTop = '0px'; }
            var r = f.getBoundingClientRect();
            if (r.height > 0 && r.height < 300) { f.style.minHeight = '100vh'; }
        }
    }

    if (document.readyState === 'complete') { schedule(800); }
    else { window.addEventListener('load', function () { schedule(1000); }); }
    setInterval(function () { try { fixTaobaoLoginChrome(); } catch (e) {} }, 1500);
})();
