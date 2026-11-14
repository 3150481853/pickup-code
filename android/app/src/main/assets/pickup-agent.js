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

    // 取件码：三段的数字，中间可能用半角/全角横线，也可能带空格。
    // 拼多多不同快递公司渲染出来的破折号不一定是 ASCII 的 -，只认半角会漏件。
    // 驿站/菜鸟：122-3-12020；顺丰：B-13016（字母-数字）
    var CODE = /\b(?:\d{1,3}\s*[-－—–−]\s*\d{1,2}\s*[-－—–−]\s*\d{3,6}|[A-Za-z]{1,3}\s*[-－—–−]\s*\d{3,7})\b/;
    var CODE_G = /\b(?:\d{1,3}\s*[-－—–−]\s*\d{1,2}\s*[-－—–−]\s*\d{3,6}|[A-Za-z]{1,3}\s*[-－—–−]\s*\d{3,7})\b/g;
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

    // 阿里系接口（mtop）的返回码：淘宝/菜鸟都是先打 acs.m.taobao.com 拿数据，
    // 诊断时能一眼区分「压根没登录」和「登录了但接口拒了」。
    var MTOP = [];
    function recordMtop(api, text) {
        var item = { api: String(api || '').slice(0, 80), ret: '', data: '' };
        try {
            var o = JSON.parse(text || '');
            if (o && o.ret) { item.ret = [].concat(o.ret).join(' | ').slice(0, 140); }
            var d = o && o.data;
            if (d && typeof d === 'object') {
                item.data = Object.keys(d).slice(0, 8).join(',');
                var pk = d.packages || d.packageList || d.packList || d.list;
                if (pk && typeof pk.length === 'number') { item.data += ' n=' + pk.length; }
            } else if (typeof d === 'string') {
                item.data = d.slice(0, 100);
            }
        } catch (e) {
            item.ret = 'not-json';
            item.data = String(text || '').slice(0, 100);
        }
        MTOP.push(item);
        if (MTOP.length > 10) { MTOP.shift(); }
    }
    function apiOf(u) {
        var m = String(u || '').match(/api=([A-Za-z0-9_.]+)/);
        return m ? m[1] : String(u || '').slice(0, 60);
    }
    try {
        var _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, u) {
            try { this.__mtopUrl = String(u || '').indexOf('acs.m.taobao.com') >= 0 ? String(u) : ''; } catch (e) {}
            return _open.apply(this, arguments);
        };
        var _send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function () {
            var xhr = this;
            if (xhr.__mtopUrl) {
                xhr.addEventListener('loadend', function () {
                    try { recordMtop(apiOf(xhr.__mtopUrl), xhr.responseText); } catch (e) {}
                });
            }
            return _send.apply(this, arguments);
        };
    } catch (e) { /* 忽略 */ }
    try {
        var _fetch = window.fetch;
        if (typeof _fetch === 'function') {
            window.fetch = function (input) {
                var u = typeof input === 'string' ? input : ((input && input.url) || '');
                var p = _fetch.apply(this, arguments);
                if (String(u).indexOf('acs.m.taobao.com') >= 0) {
                    try {
                        p.then(function (r) { return r.clone().text(); })
                         .then(function (t) { recordMtop(apiOf(u), t); })
                         .catch(function () {});
                    } catch (e) {}
                }
                return p;
            };
        }
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

    function pushUnique(out, seen, code, station, place, raw, img, mailNo) {
        if (!code) { return; }
        code = String(code).replace(/[－—–−]/g, '-').replace(/\s+/g, '');
        if (seen[code]) { return; }
        seen[code] = true;
        out.push({
            code: code,
            station: station || '',
            place: place || '',
            raw: raw || '',
            img: img || '',
            mailNo: mailNo || ''
        });
    }

    // 快递单号：拼多多卡片上写着「圆通速递 YT7656364590990」「丹鸟 611723856155233」。
    // 排除 11 位（手机号）和带横杠的（那是取件码）。
    function mailNoOf(text) {
        var t = norm(text || '');
        var re = /\b([A-Z]{2,3}\d{8,14}|\d{12,18})\b/g;
        var m, best = '';
        while ((m = re.exec(t))) {
            var v = m[1];
            if (/^\d{11}$/.test(v)) { continue; }
            if (!best) { best = v; }
            if (/^(YT|JT|SF|JD|ZT|YD|DB|DP|EMS)/i.test(v)) { best = v; break; }
        }
        return best;
    }

    // 每条左侧的主图：优先 <img>，其次 background-image。
    // 阿里/拼多多的图常常是相对路径或 //img.xxx，这里统一补成绝对地址。
    function imgOf(node) {
        if (!node) { return ''; }
        var best = '';
        var imgs = node.querySelectorAll ? node.querySelectorAll('img') : [];
        for (var i = 0; i < imgs.length; i++) {
            var s = imgs[i].getAttribute('src') || imgs[i].getAttribute('data-src') || '';
            if (!s || /^data:/.test(s)) { continue; }
            if (!best) { best = s; }
            if (/alicdn|hdslb|pddpic|picasso|\.(jpg|jpeg|png|webp)/i.test(s)) { best = s; break; }
        }
        if (!best) {
            var all = node.querySelectorAll ? node.querySelectorAll('div,span,a') : [];
            for (var j = 0; j < all.length && j < 60; j++) {
                var bg = '';
                try { bg = window.getComputedStyle(all[j]).backgroundImage || ''; } catch (e) { bg = ''; }
                var m = bg.match(/url\(["']?(https?:\/\/[^"')]+)/);
                if (m) { best = m[1]; break; }
            }
        }
        if (!best) { return ''; }
        try { return new URL(best, location.href).href; } catch (e) { return best; }
    }

    // ---- 拼多多：官方结构 ----
    // 坑：驿站名常常只渲染在列表头一处（`station-name`），下面每张卡片里没有，
    // 于是 7 件里只有第一件带驿站名；`package-tags` 里混着「支持退换货」「导航」
    // 「电话」「照片」这类按钮文案，当成货位就变成 place:"支持退换货"。
    function listStationName() {
        var el = document.querySelector('[class*="station-name"]');
        var s = el ? norm(el.textContent) : '';
        if (s) { return s; }
        var body = norm(document.body ? document.body.textContent : '');
        var m = body.match(/[\u4e00-\u9fa5A-Za-z0-9]{2,16}驿站/);
        return m ? m[0] : '';
    }

    function cleanPlace(s) {
        s = norm(s).slice(0, 24);
        if (!s) { return ''; }
        if (/支持|退换|导航|电话|照片|复制|提醒|入站|天|小时|查看/.test(s)) {
            var m = s.match(PLACE);
            return m ? norm(m[1]) : '';
        }
        var p = s.match(PLACE);
        return p ? norm(p[1]) : s;
    }

    function collectPdd() {
        var out = [];
        var seen = Object.create(null);
        var listStation = listStationName();
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
                st ? norm(st.textContent) : listStation,
                tags ? cleanPlace(tags.textContent) : '',
                raw.length > 90 ? raw.slice(0, 90) : raw,
                imgOf(n),
                mailNoOf(raw));
        }
        // 兜底：还是没驿站名的，统一补上列表头那个
        if (listStation) {
            for (var k = 0; k < out.length; k++) {
                if (!out[k].station) { out[k].station = listStation; }
            }
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
            var card = el;
            var a = el.parentElement;
            for (var hop = 0; a && hop < 5; hop++, a = a.parentElement) {
                var at = norm(a.innerText || a.textContent);
                if (!at || at.length > 120) { break; }
                if ((at.match(CODE_G) || []).length > 1) { break; }  // 再往上就是列表了
                ctx = at;
                card = a;
            }
            var sm = ctx.match(STATION);
            var pm = ctx.match(PLACE);
            pushUnique(out, seen, code, sm ? sm[1] : '', pm ? norm(pm[1]) : '',
                ctx.length > 90 ? ctx.slice(0, 90) : ctx,
                imgOf(card),
                mailNoOf(ctx));
        });
        return out;
    }

    function collect() {
        // 两条路都跑，按取件码合并：
        // 拼多多的卡片有时只有第一张带官方类名（换快递公司就换一套 DOM），
        // 只靠官方结构会漏件；只靠通用启发式又容易把驿站电话之类当成码。
        var items = collectPdd();
        var seen = Object.create(null);
        for (var i = 0; i < items.length; i++) { seen[items[i].code] = true; }
        var gen = collectGeneric();
        for (var j = 0; j < gen.length; j++) {
            var g = gen[j];
            if (!seen[g.code]) {
                seen[g.code] = true;
                items.push(g);
            } else {
                // 通用启发式给的驿站/货位常常更全，补空格
                for (var k = 0; k < items.length; k++) {
                    if (items[k].code !== g.code) { continue; }
                    if (!items[k].station && g.station) { items[k].station = g.station; }
                    if (!items[k].place && g.place) { items[k].place = g.place; }
                    if (!items[k].img && g.img) { items[k].img = g.img; }
                    if (!items[k].mailNo && g.mailNo) { items[k].mailNo = g.mailNo; }
                }
            }
        }
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
            mtop: MTOP,
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

    // 4) 淘系 SSO 确认页（头像 t**5 / 「请确认继续用当前账号登录」 / 「快速进入」）：
    //    这屏在网页里点「快速进入」是拿当前淘宝账号完成 SSO 再回跳，不会跳 App；
    //    但那个按钮常常不是真 <button>/<a>，点了没反应，所以这里替用户点一次。
    var ssoTried = false;
    function autoConfirmSso() {
        if (ssoTried) { return; }
        var host = location.hostname || '';
        if (!/(taobao|cainiao|alipay)\.com$/.test(host)) { return; }
        var body = document.body;
        if (!body) { return; }
        if (norm(body.textContent).indexOf('请确认继续用当前账号登录') < 0) { return; }
        var all = body.querySelectorAll('button, a, div, span');
        for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (el.childElementCount === 0 && norm(el.textContent) === '快速进入') {
                ssoTried = true;
                try { el.click(); } catch (e) {}
                return;
            }
        }
    }

    if (document.readyState === 'complete') { schedule(800); }
    else { window.addEventListener('load', function () { schedule(1000); }); }
    setInterval(function () {
        try { fixTaobaoLoginChrome(); } catch (e) {}
        try { autoConfirmSso(); } catch (e) {}
    }, 1500);
})();
