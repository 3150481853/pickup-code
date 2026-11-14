package local.pickup;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.List;

/**
 * 安卓版：和 iOS 版同一套思路 —— 网页只当登录 + 兜底抓取，菜鸟的取包裹列表走原生 mtop。
 * 首页把三个来源按取件码合并成一张清单。
 */
public class MainActivity extends Activity {

    static final String PDD_ENTRY = "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE";
    static final String CAINIAO_ENTRY = "https://page.cainiao.com/xiniao-web/xn-h5-gg-tab-closed-takeParcel/#/";
    static final String TAOBAO_ENTRY = "https://pages-fast.m.taobao.com/wow/z/uniapp/1011717/last-mile-fe/end-collect-platform/identity-code";
    static final String TAOBAO_LOGIN = "https://login.taobao.com/member/login.jhtml?style=minisimple&redirectURL=";

    static final String[] TABS = {"首页", "菜鸟取件", "拼多多", "淘宝取件"};
    static final String[] SITE_IDS = {null, "cainiao", "pdd", "taobao"};
    static final String[] ENTRIES = {null, CAINIAO_ENTRY, PDD_ENTRY, TAOBAO_ENTRY};

    final int RED = Color.rgb(237, 36, 76);
    final int INK = Color.rgb(23, 23, 23);
    final int GREY = Color.rgb(120, 120, 120);

    Store store;
    Handler ui = new Handler(Looper.getMainLooper());

    FrameLayout content;
    ScrollView homeScroll;
    LinearLayout homeInner;
    TextView subtitle, statusLine, banner, hint;
    LinearLayout tabBar;
    LinearLayout fabBox;
    TextView fabMain;
    boolean fabOpen = false;
    boolean needsLogin = false;

    WebView[] webs = new WebView[4];
    String jsShim;
    String jsPdd;
    String jsTaobao;
    String jsAgent;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        store = new Store(this);
        jsShim = readAsset("shim.js");
        jsPdd = readAsset("inject-pdd.js");
        jsTaobao = readAsset("inject-taobao.js");
        jsAgent = readAsset("pickup-agent.js");

        CookieManager cm = CookieManager.getInstance();
        cm.setAcceptCookie(true);

        store.setOnChange(() -> runOnUiThread(this::renderHome));

        setContentView(buildRoot());
        renderHome();
        select(0);
        queryCainiao();

        ui.postDelayed(new Runnable() {
            @Override public void run() {
                collectAll();
                ui.postDelayed(this, 25000);
            }
        }, 4000);
        ui.postDelayed(new Runnable() {
            @Override public void run() {
                queryCainiao();
                ui.postDelayed(this, 45000);
            }
        }, 45000);
    }

    // ---------------- UI ----------------

    View buildRoot() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setBackgroundColor(Color.WHITE);

        content = new FrameLayout(this);
        col.addView(content, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        hint = new TextView(this);
        hint.setTextSize(10);
        hint.setTextColor(GREY);
        hint.setGravity(Gravity.CENTER);
        hint.setPadding(dp(6), dp(3), dp(6), dp(3));
        hint.setVisibility(View.GONE);
        col.addView(hint);

        tabBar = new LinearLayout(this);
        tabBar.setOrientation(LinearLayout.HORIZONTAL);
        tabBar.setBackgroundColor(Color.WHITE);
        col.addView(tabBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        buildHome();
        buildFab();
        return col;
    }

    void buildHome() {
        homeScroll = new ScrollView(this);
        homeScroll.setBackgroundColor(Color.rgb(244, 244, 247));
        homeScroll.setFillViewport(true);
        homeInner = new LinearLayout(this);
        homeInner.setOrientation(LinearLayout.VERTICAL);
        homeInner.setPadding(dp(10), dp(10), dp(10), dp(24));
        homeScroll.addView(homeInner, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        content.addView(homeScroll, lp);
    }

    void renderHome() {
        homeInner.removeAllViews();

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText("待取件");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(INK);
        left.addView(title);
        subtitle = new TextView(this);
        subtitle.setTextSize(12);
        subtitle.setTextColor(GREY);
        left.addView(subtitle);
        head.addView(left, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView add = pill("＋ 添加", RED, Color.TRANSPARENT);
        add.setOnClickListener(v -> showAddDialog());
        head.addView(add);
        TextView diag = pill("诊断", GREY, Color.rgb(0, 0, 0));
        diag.setOnClickListener(v -> showDiag());
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dlp.leftMargin = dp(6);
        head.addView(diag, dlp);
        TextView refresh = pill("刷新全部", INK, Color.rgb(0, 0, 0));
        refresh.setOnClickListener(v -> refreshAll());
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rlp.leftMargin = dp(6);
        head.addView(refresh, rlp);

        homeInner.addView(head);

        String sub;
        if (store.items.isEmpty()) {
            sub = "还没有数据";
        } else {
            java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("HH:mm");
            sub = "共 " + store.items.size() + " 件 · " + f.format(new java.util.Date()) + " 更新";
        }
        subtitle.setText(sub);

        if (!store.siteState.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for (String k : store.siteState.keySet()) {
                if (sb.length() > 0) sb.append("   ");
                sb.append(store.siteLabel(k)).append("：").append(store.siteState.get(k));
            }
            statusLine = new TextView(this);
            statusLine.setText(sb.toString());
            statusLine.setTextSize(11);
            statusLine.setTextColor(GREY);
            statusLine.setPadding(0, dp(4), 0, dp(6));
            homeInner.addView(statusLine);
        }

        if (needsLogin) {
            banner = new TextView(this);
            banner.setText("淘宝登录已失效，菜鸟列表拿不到 → 点这里重新登录");
            banner.setTextSize(12);
            banner.setTextColor(RED);
            banner.setPadding(dp(10), dp(9), dp(10), dp(9));
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(Color.rgb(255, 240, 243));
            bg.setCornerRadius(dp(8));
            banner.setBackground(bg);
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            blp.topMargin = dp(4);
            blp.bottomMargin = dp(6);
            homeInner.addView(banner, blp);
            banner.setOnClickListener(v -> relogin());
        }

        if (store.items.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("还没有取件码\n\n两个来源各登录一次就行：\n「菜鸟取件」= 菜鸟的取包裹列表（要淘宝登录）\n「拼多多」= 被多多驿站代收的件\n也可以在右上角「＋ 添加」里手动输入");
            empty.setTextSize(13);
            empty.setTextColor(GREY);
            empty.setGravity(Gravity.CENTER_HORIZONTAL);
            empty.setLineSpacing(dp(3), 1f);
            empty.setPadding(0, dp(48), 0, 0);
            homeInner.addView(empty);
        } else {
            for (PickupItem it : new ArrayList<>(store.items)) {
                homeInner.addView(row(it));
            }
        }
    }

    View row(PickupItem it) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.WHITE);
        bg.setCornerRadius(dp(12));
        card.setBackground(bg);
        card.setPadding(dp(14), dp(12), dp(12), dp(12));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(8);
        card.setLayoutParams(lp);

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);

        TextView code = new TextView(this);
        code.setText(it.code);
        code.setTextSize(23);
        code.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        code.setTextColor(INK);
        left.addView(code);

        LinearLayout meta = new LinearLayout(this);
        meta.setOrientation(LinearLayout.HORIZONTAL);
        meta.setGravity(Gravity.CENTER_VERTICAL);
        TextView tag = new TextView(this);
        tag.setText(store.siteLabel(it.site));
        tag.setTextSize(10);
        tag.setTextColor(GREY);
        tag.setPadding(dp(5), dp(1), dp(5), dp(1));
        GradientDrawable tbg = new GradientDrawable();
        tbg.setColor(Color.rgb(238, 238, 242));
        tbg.setCornerRadius(dp(4));
        tag.setBackground(tbg);
        meta.addView(tag);

        String m = it.station;
        if (!it.place.isEmpty()) m = m.isEmpty() ? it.place : m + " · " + it.place;
        if (!m.isEmpty()) {
            TextView mv = new TextView(this);
            mv.setText(m);
            mv.setTextSize(11);
            mv.setTextColor(GREY);
            mv.setPadding(dp(6), 0, 0, 0);
            mv.setMaxLines(1);
            meta.addView(mv);
        }
        left.addView(meta);
        card.addView(left, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView act = new TextView(this);
        act.setText(it.manual ? "删除" : "复制");
        act.setTextSize(12);
        act.setTextColor(it.manual ? GREY : RED);
        act.setPadding(dp(8), dp(4), dp(6), dp(4));
        act.setOnClickListener(v -> {
            if (it.manual) {
                store.removeManual(it.code);
            } else {
                copy(it.code);
                Toast.makeText(this, "已复制 " + it.code, Toast.LENGTH_SHORT).show();
            }
        });
        card.addView(act);

        card.setOnClickListener(v -> {
            copy(it.code);
            Toast.makeText(this, "已复制 " + it.code, Toast.LENGTH_SHORT).show();
        });
        return card;
    }

    TextView pill(String text, int color, int bgBase) {
        TextView v = new TextView(this);
        v.setText(text);
        v.setTextSize(12);
        v.setTextColor(color);
        v.setPadding(dp(10), dp(6), dp(10), dp(6));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(bgBase == Color.TRANSPARENT ? Color.TRANSPARENT : Color.rgb(240, 240, 244));
        bg.setCornerRadius(dp(16));
        if (bgBase == Color.TRANSPARENT) {
            bg.setColor(Color.rgb(255, 236, 240));
        }
        v.setBackground(bg);
        return v;
    }

    void buildFab() {
        fabBox = new LinearLayout(this);
        fabBox.setOrientation(LinearLayout.VERTICAL);
        fabBox.setGravity(Gravity.END);
        fabBox.setVisibility(View.GONE);

        for (String[] item : new String[][]{
                {"整页登录", "login"}, {"刷新页面", "reload"},
                {"回到入口", "entry"}, {"抓一次", "collect"}}) {
            TextView btn = new TextView(this);
            btn.setText(item[0]);
            btn.setTextSize(13);
            btn.setTextColor(INK);
            btn.setPadding(dp(14), dp(9), dp(14), dp(9));
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(Color.WHITE);
            bg.setCornerRadius(dp(20));
            btn.setBackground(bg);
            btn.setElevation(dp(3));
            final String act = item[1];
            btn.setOnClickListener(v -> { doAction(act); toggleFab(false); });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.gravity = Gravity.END;
            lp.bottomMargin = dp(8);
            fabBox.addView(btn, lp);
        }

        fabMain = new TextView(this);
        fabMain.setText("⚙");
        fabMain.setTextSize(20);
        fabMain.setTextColor(Color.WHITE);
        fabMain.setGravity(Gravity.CENTER);
        GradientDrawable fbg = new GradientDrawable();
        fbg.setShape(GradientDrawable.OVAL);
        fbg.setColor(Color.argb(210, 30, 30, 30));
        fabMain.setBackground(fbg);
        fabMain.setElevation(dp(6));
        fabMain.setOnClickListener(v -> toggleFab(!fabOpen));
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(dp(50), dp(50));
        flp.gravity = Gravity.END;
        fabBox.addView(fabMain, flp);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.END;
        lp.rightMargin = dp(14);
        lp.bottomMargin = dp(16);
        content.addView(fabBox, lp);
    }

    void toggleFab(boolean open) {
        fabOpen = open;
        fabBox.setVisibility(open ? View.VISIBLE : View.GONE);
        fabMain.setText(open ? "✕" : "⚙");
    }

    void buildTabBar() {
        tabBar.removeAllViews();
        for (int i = 0; i < TABS.length; i++) {
            final int idx = i;
            boolean active = idx == selectedIndex;
            LinearLayout cell = new LinearLayout(this);
            cell.setOrientation(LinearLayout.VERTICAL);
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(0, dp(9), 0, dp(7));
            TextView t = new TextView(this);
            t.setText(TABS[i]);
            t.setTextSize(12);
            t.setTypeface(Typeface.DEFAULT, active ? Typeface.BOLD : Typeface.NORMAL);
            t.setTextColor(active ? RED : GREY);
            t.setGravity(Gravity.CENTER);
            cell.addView(t);
            View dot = new View(this);
            GradientDrawable d = new GradientDrawable();
            d.setShape(GradientDrawable.OVAL);
            d.setColor(active ? RED : Color.TRANSPARENT);
            dot.setBackground(d);
            LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(dp(5), dp(5));
            dlp.topMargin = dp(3);
            cell.addView(dot, dlp);
            cell.setOnClickListener(v -> select(idx));
            tabBar.addView(cell, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        }
    }

    int selectedIndex = 0;

    void select(int idx) {
        selectedIndex = idx;
        buildTabBar();
        toggleFab(false);
        homeScroll.setVisibility(idx == 0 ? View.VISIBLE : View.GONE);
        for (int i = 1; i < webs.length; i++) {
            if (webs[i] == null) continue;
            webs[i].setVisibility(i == idx ? View.VISIBLE : View.GONE);
        }
        if (idx > 0) {
            ensureWeb(idx);
            webs[idx].setVisibility(View.VISIBLE);
            String h = hintText(idx);
            hint.setText(h);
            hint.setVisibility(h.isEmpty() ? View.GONE : View.VISIBLE);
        } else {
            hint.setVisibility(View.GONE);
            collectAll();
        }
    }

    String hintText(int idx) {
        if ("cainiao".equals(SITE_IDS[idx])) return "菜鸟列表由原生接口取，这个页面只用来登录淘宝";
        if ("taobao".equals(SITE_IDS[idx])) return "淘宝取件码：登录后由网页抓取";
        return "";
    }

    // ---------------- WebView ----------------

    void ensureWeb(int idx) {
        if (webs[idx] != null) return;
        final String site = SITE_IDS[idx];
        WebView wv = new WebView(this);
        WebSettings s = wv.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setSupportMultipleWindows(true);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        if (!"pdd".equals(site)) s.setUserAgentString(safariUA());
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true);

        wv.addJavascriptInterface(new Bridge(site), "Pickup");
        wv.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, String url) {
                return blockScheme(url);
            }
            @Override public boolean shouldOverrideUrlLoading(WebView v, android.webkit.WebResourceRequest r) {
                return blockScheme(r.getUrl().toString());
            }
            @Override public void onPageFinished(WebView v, String url) {
                inject(v, site);
            }
        });
        wv.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                // 验证码 / 登录常走 target=_blank：在同一个 WebView 里打开，别丢
                final WebView temp = new WebView(MainActivity.this);
                temp.setWebViewClient(new WebViewClient() {
                    @Override public boolean shouldOverrideUrlLoading(WebView v, String url) {
                        if (blockScheme(url)) return true;
                        webs[idx].loadUrl(url);
                        return true;
                    }
                });
                ((WebView.WebViewTransport) resultMsg.obj).setWebView(temp);
                resultMsg.sendToTarget();
                return true;
            }
        });

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        content.addView(wv, Math.min(1, content.getChildCount()), lp);
        webs[idx] = wv;
        wv.loadUrl(ENTRIES[idx]);
    }

    boolean blockScheme(String url) {
        if (url == null) return true;
        String u = url.toLowerCase();
        // 拼多多/淘宝的 App scheme 一律不交给系统：交给系统就会跳去装好的 App，
        // 回来登录态还是没落地。
        if (u.startsWith("http://") || u.startsWith("https://") || u.startsWith("about:")) return false;
        return true;
    }

    String safariUA() {
        return "Mozilla/5.0 (Linux; Android " + Build.VERSION.RELEASE + "; " + Build.MODEL + ") "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36";
    }

    void inject(WebView wv, String site) {
        StringBuilder js = new StringBuilder();
        js.append("if(!window.__pk_injected){window.__pk_injected=1;");
        js.append(jsShim);
        if ("pdd".equals(site)) js.append(jsPdd);
        else js.append(jsTaobao);
        js.append(jsAgent);
        js.append("}");
        wv.evaluateJavascript(js.toString(), null);
    }

    void collectAll() {
        for (int i = 1; i < webs.length; i++) {
            WebView wv = webs[i];
            if (wv == null) continue;
            wv.evaluateJavascript("(function(){try{if(window.__pickupCollect)window.__pickupCollect();}catch(e){}})()", null);
        }
    }

    void doAction(String act) {
        int idx = selectedIndex;
        if (idx <= 0) return;
        ensureWeb(idx);
        WebView wv = webs[idx];
        String site = SITE_IDS[idx];
        switch (act) {
            case "login":
                wv.loadUrl(TAOBAO_LOGIN + URLEncoder.encode(ENTRIES[idx]));
                break;
            case "reload":
                wv.reload();
                break;
            case "entry":
                wv.loadUrl(ENTRIES[idx]);
                break;
            case "collect":
                wv.evaluateJavascript("(function(){try{if(window.__pickupCollect)window.__pickupCollect();}catch(e){}})()", null);
                Toast.makeText(this, "抓了一次", Toast.LENGTH_SHORT).show();
                break;
        }
    }

    // ---------------- 数据 ----------------

    void queryCainiao() {
        Mtop.call("mtop.cainiao.lpc.packageservice.xiniao.querypacklist",
                "{\"staId\":\"\",\"day\":30,\"needAuthControl\":true}", reply -> runOnUiThread(() -> {
                    if (reply.ok()) {
                        needsLogin = false;
                        store.setCollected("cainiao", reply.items, "抓到 " + reply.items.size() + " 件");
                    } else {
                        boolean sess = reply.ret.contains("SESSION_EXPIRED")
                                || reply.ret.contains("TOKEN_EMPTY")
                                || reply.ret.contains("NEED_LOGIN");
                        needsLogin = sess;
                        String shortRet = reply.ret.contains("::")
                                ? reply.ret.substring(0, reply.ret.indexOf("::")) : reply.ret;
                        store.setCollected("cainiao", new ArrayList<>(), shortRet);
                        renderHome();
                    }
                }));
    }

    void refreshAll() {
        for (int i = 1; i < webs.length; i++) if (webs[i] != null) webs[i].reload();
        queryCainiao();
        ui.postDelayed(this::collectAll, 3000);
    }

    void relogin() {
        select(1);
        ensureWeb(1);
        doAction("login");
    }

    // ---------------- 桥 ----------------

    class Bridge {
        final String site;
        Bridge(String s) { site = s; }

        @JavascriptInterface
        public void post(String json) {
            try {
                JSONObject o = new JSONObject(json);
                String st = o.optString("state", "");
                JSONArray arr = o.optJSONArray("items");
                List<PickupItem> list = new ArrayList<>();
                if (arr != null) {
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject it = arr.optJSONObject(i);
                        if (it == null) continue;
                        String code = Store.normalize(it.optString("code", ""));
                        if (code.isEmpty()) continue;
                        list.add(new PickupItem(code, site,
                                it.optString("station", ""), it.optString("place", "")));
                    }
                }
                final int n = list.size();
                if ("taobao".equals(site) && n == 0 && !st.isEmpty()) {
                    // 淘宝页没抓到就不覆盖菜鸟的数据
                    return;
                }
                runOnUiThread(() -> store.setCollected(site, list, st.isEmpty() ? null : st));
            } catch (Exception ignored) {}
        }
    }

    // ---------------- 杂项 ----------------

    void copy(String s) {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("code", s));
    }

    void showAddDialog() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(18), dp(10), dp(18), 0);

        EditText code = new EditText(this);
        code.setHint("取件码，如 122-3-12020 或 B-13016");
        code.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS);
        box.addView(code);

        EditText station = new EditText(this);
        station.setHint("驿站 / 位置（可不填）");
        box.addView(station);

        new AlertDialog.Builder(this)
                .setTitle("手动添加取件码")
                .setView(box)
                .setPositiveButton("添加", (d, w) -> {
                    boolean ok = store.addManual(code.getText().toString(),
                            station.getText().toString().trim(), "");
                    Toast.makeText(this, ok ? "已添加" : "格式不对或重复了", Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    void showDiag() {
        StringBuilder sb = new StringBuilder();
        sb.append("版本：").append(versionName()).append("\n");
        sb.append("菜鸟接口：").append(store.siteState.containsKey("cainiao")
                ? store.siteState.get("cainiao") : "还没跑").append("\n");
        for (String k : store.siteState.keySet()) {
            sb.append(store.siteLabel(k)).append("：").append(store.siteState.get(k)).append("\n");
        }
        String cookies = Mtop.cookieHeader();
        sb.append("淘宝 cookie 条数：").append(cookies.isEmpty() ? 0 : cookies.split(";").length).append("\n");
        sb.append("有 _m_h5_tk：").append(cookies.contains("_m_h5_tk")).append("\n");
        sb.append("有 unb：").append(cookies.contains("unb=")).append("\n");
        sb.append("共 ").append(store.items.size()).append(" 条：\n");
        for (PickupItem it : store.items) {
            sb.append(it.code).append("  ｜ ").append(store.siteLabel(it.site))
              .append(" ｜ ").append(it.station).append(" ｜ ").append(it.place).append("\n");
        }
        TextView tv = new TextView(this);
        tv.setText(sb.toString());
        tv.setTextSize(11);
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextIsSelectable(true);
        tv.setPadding(dp(16), dp(12), dp(16), dp(12));
        ScrollView sv = new ScrollView(this);
        sv.addView(tv);
        new AlertDialog.Builder(this)
                .setTitle("诊断")
                .setView(sv)
                .setPositiveButton("复制", (d, w) -> {
                    copy(sb.toString());
                    Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("关闭", null)
                .show();
    }

    String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "?";
        }
    }

    String readAsset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
            return bo.toString("UTF-8");
        } catch (Exception e) {
            return "/* missing " + name + " */";
        }
    }

    int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }

    @Override
    protected void onPause() {
        super.onPause();
        CookieManager.getInstance().flush();
    }
}
