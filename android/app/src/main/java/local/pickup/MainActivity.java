package local.pickup;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.provider.MediaStore;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebStorage;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

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
    static final String[] TAB_ICONS = {"🏠", "📦", "🛒", "🏷"};
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
    LinearLayout fabMenuBox;
    TextView fabMain;
    View fabLoginBtn;     // 拼多多标签下要藏起来
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
        TextView refresh = pill("刷新", INK, Color.rgb(0, 0, 0));
        refresh.setOnClickListener(v -> refreshAll());
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rlp.leftMargin = dp(6);
        head.addView(refresh, rlp);

        TextView share = pill("分享", INK, Color.rgb(0, 0, 0));
        share.setOnClickListener(v -> sharePick());
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.leftMargin = dp(6);
        head.addView(share, slp);

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

    /** 当前向左划开的那一行卡片（同时只允许开一行） */
    View openRowView;
    static final int SWIPE_W_DP = 170;   // 划开后露出的两个按钮总宽

    View row(PickupItem it) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.WHITE);
        bg.setCornerRadius(dp(12));
        card.setBackground(bg);
        card.setPadding(dp(14), dp(12), dp(12), dp(12));

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

        if (store.isPinned(it.code)) {
            TextView pinMark = new TextView(this);
            pinMark.setText("置顶");
            pinMark.setTextSize(9);
            pinMark.setTextColor(Color.WHITE);
            pinMark.setPadding(dp(4), dp(1), dp(4), dp(1));
            GradientDrawable pbg = new GradientDrawable();
            pbg.setColor(Color.rgb(51, 115, 242));
            pbg.setCornerRadius(dp(4));
            pinMark.setBackground(pbg);
            LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            plp.leftMargin = dp(5);
            meta.addView(pinMark, plp);
        }

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

        TextView copyIcon = new TextView(this);
        copyIcon.setText("复制");
        copyIcon.setTextSize(12);
        copyIcon.setTextColor(RED);
        copyIcon.setPadding(dp(8), dp(4), dp(6), dp(4));
        card.addView(copyIcon);

        // ---- 外面套一层：右侧两个按钮垫在底下，卡片可左划 ----
        FrameLayout frame = new FrameLayout(this);
        GradientDrawable fbg = new GradientDrawable();
        fbg.setColor(Color.WHITE);
        fbg.setCornerRadius(dp(12));
        frame.setBackground(fbg);
        frame.setClipToOutline(true);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        flp.bottomMargin = dp(8);
        frame.setLayoutParams(flp);

        LinearLayout acts = new LinearLayout(this);
        acts.setOrientation(LinearLayout.HORIZONTAL);
        TextView pinBtn = actionButton(store.isPinned(it.code) ? "取消置顶" : "置顶",
                Color.rgb(51, 115, 242));
        TextView delBtn = actionButton("删除", Color.rgb(229, 56, 63));
        acts.addView(pinBtn, new LinearLayout.LayoutParams(dp(SWIPE_W_DP / 2),
                ViewGroup.LayoutParams.MATCH_PARENT));
        acts.addView(delBtn, new LinearLayout.LayoutParams(dp(SWIPE_W_DP / 2),
                ViewGroup.LayoutParams.MATCH_PARENT));
        frame.addView(acts, new FrameLayout.LayoutParams(dp(SWIPE_W_DP),
                ViewGroup.LayoutParams.MATCH_PARENT, Gravity.END));

        frame.addView(card, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        pinBtn.setOnClickListener(v -> {
            store.togglePin(it.code);
            closeOpenRow();
            refreshHome();
        });
        delBtn.setOnClickListener(v -> {
            store.dismiss(it);
            closeOpenRow();
            refreshHome();
        });

        attachSwipe(card, it);
        return frame;
    }

    TextView actionButton(String label, int color) {
        TextView tv = new TextView(this);
        tv.setText(label);
        tv.setTextSize(13);
        tv.setTextColor(Color.WHITE);
        tv.setGravity(Gravity.CENTER);
        tv.setBackgroundColor(color);
        return tv;
    }

    /** 左划露按钮：横向拖动时才接管手势，纵向留给 ScrollView */
    void attachSwipe(View card, PickupItem it) {
        final int w = dp(SWIPE_W_DP);
        final float[] startX = {0}, startY = {0}, baseX = {0};
        final boolean[] dragging = {false};
        card.setOnTouchListener((v, e) -> {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    startX[0] = e.getRawX();
                    startY[0] = e.getRawY();
                    baseX[0] = v.getTranslationX();
                    dragging[0] = false;
                    return false;
                case MotionEvent.ACTION_MOVE: {
                    float dx = e.getRawX() - startX[0];
                    float dy = e.getRawY() - startY[0];
                    if (!dragging[0] && Math.abs(dx) > dp(10) && Math.abs(dx) > Math.abs(dy)) {
                        dragging[0] = true;
                        if (v.getParent() != null) {
                            v.getParent().requestDisallowInterceptTouchEvent(true);
                        }
                        if (openRowView != null && openRowView != v) closeOpenRow();
                    }
                    if (dragging[0]) {
                        float t = baseX[0] + dx;
                        if (t > 0) t = 0;
                        if (t < -w) t = -w;
                        v.setTranslationX(t);
                    }
                    return dragging[0];
                }
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL: {
                    if (!dragging[0]) return false;
                    boolean open = v.getTranslationX() < -w * 0.4f;
                    dragging[0] = false;
                    v.animate().translationX(open ? -w : 0).setDuration(140).start();
                    openRowView = open ? v : null;
                    return true;
                }
            }
            return false;
        });
        card.setOnClickListener(v -> {
            if (openRowView != null) { closeOpenRow(); return; }
            copy(it.code);
            Toast.makeText(this, "已复制 " + it.code, Toast.LENGTH_SHORT).show();
        });
    }

    void closeOpenRow() {
        if (openRowView == null) return;
        View v = openRowView;
        openRowView = null;
        v.animate().translationX(0).setDuration(140).start();
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
        // 注意：外层容器必须常显，只有里面的菜单项才收起。
        // 之前把整个容器 GONE 掉，连主按钮一起藏了，所以「看不到悬浮窗」。
        fabBox = new LinearLayout(this);
        fabBox.setOrientation(LinearLayout.VERTICAL);
        fabBox.setGravity(Gravity.END);

        fabMenuBox = new LinearLayout(this);
        fabMenuBox.setOrientation(LinearLayout.VERTICAL);
        fabMenuBox.setGravity(Gravity.END);
        fabMenuBox.setVisibility(View.GONE);

        for (String[] item : new String[][]{
                {"整页登录", "login"}, {"刷新页面", "reload"},
                {"回到入口", "entry"}, {"抓一次", "collect"},
                {"清除登录", "clearlogin"}}) {
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
            if ("login".equals(act)) fabLoginBtn = btn;
            btn.setOnClickListener(v -> { doAction(act); toggleFab(false); });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.gravity = Gravity.END;
            lp.bottomMargin = dp(8);
            fabMenuBox.addView(btn, lp);
        }
        fabBox.addView(fabMenuBox, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        fabMain = new TextView(this);
        fabMain.setText("⚙");
        fabMain.setTextSize(20);
        fabMain.setTextColor(Color.WHITE);
        fabMain.setGravity(Gravity.CENTER);
        GradientDrawable fbg = new GradientDrawable();
        fbg.setShape(GradientDrawable.OVAL);
        fbg.setColor(Color.argb(215, 30, 30, 30));
        fabMain.setBackground(fbg);
        fabMain.setElevation(dp(6));
        fabMain.setOnClickListener(v -> toggleFab(!fabOpen));
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(dp(52), dp(52));
        flp.gravity = Gravity.END;
        flp.topMargin = dp(4);
        fabBox.addView(fabMain, flp);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.END;
        lp.rightMargin = dp(14);
        lp.bottomMargin = dp(18);
        fabBox.setVisibility(View.GONE);   // 只在站点页显示，首页不需要
        content.addView(fabBox, lp);
    }

    void toggleFab(boolean open) {
        fabOpen = open;
        if (fabMenuBox != null) {
            fabMenuBox.setVisibility(open ? View.VISIBLE : View.GONE);
        }
        // 拼多多没有「整页登录」（它自己在网页里登录），别让它看着像能用
        if (fabLoginBtn != null) {
            boolean ok = selectedIndex > 0 && !"pdd".equals(SITE_IDS[selectedIndex]);
            fabLoginBtn.setVisibility(ok ? View.VISIBLE : View.GONE);
        }
        if (fabMain != null) fabMain.setText(open ? "✕" : "⚙");
    }

    void buildTabBar() {
        tabBar.removeAllViews();
        for (int i = 0; i < TABS.length; i++) {
            final int idx = i;
            boolean active = idx == selectedIndex;
            LinearLayout cell = new LinearLayout(this);
            cell.setOrientation(LinearLayout.VERTICAL);
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(0, dp(8), 0, dp(5));
            TextView ic = new TextView(this);
            ic.setText(TAB_ICONS[i]);
            ic.setTextSize(17);
            ic.setGravity(Gravity.CENTER);
            cell.addView(ic);
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
            if (fabBox != null) fabBox.setVisibility(View.VISIBLE);
            String h = hintText(idx);
            hint.setText(h);
            hint.setVisibility(h.isEmpty() ? View.GONE : View.VISIBLE);
        } else {
            if (fabBox != null) fabBox.setVisibility(View.GONE);
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

    /** 每个站点最近 40 条主框架导航（诊断里用）。 */
    final List<List<String>> navLogs = new ArrayList<List<String>>();

    {
        for (int i = 0; i < 4; i++) navLogs.add(new ArrayList<String>());
    }

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
            @Override public void onPageStarted(WebView v, String url, android.graphics.Bitmap fav) {
                List<String> log = navLogs.get(idx);
                if (log != null && url != null) {
                    log.add(url);
                    while (log.size() > 40) log.remove(0);
                }
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
                // 「整页登录」只对淘宝/菜鸟有意义（那是淘宝的登录页）。
                // 拼多多在自己的网页里登录，这里绝不能拼淘宝登录地址 ——
                // 之前没挡，结果在「拼多多」标签点了就变成淘宝登录界面。
                if ("pdd".equals(site)) {
                    Toast.makeText(this, "拼多多用自己的网页登录（手机号/扫码），不用整页登录", Toast.LENGTH_LONG).show();
                    break;
                }
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
            case "clearlogin":
                confirmClearLogin(idx);
                break;
        }
    }

    // 换号用：清掉这个站点（其实是整个 WebView 的）Cookie 与网页数据，再回入口
    void confirmClearLogin(int idx) {
        new AlertDialog.Builder(this)
                .setTitle("清除 " + SITE_NAME_CN(idx) + " 的登录状态？")
                .setMessage("会清掉 App 里的 Cookie 和网页数据，回到入口重新登录。首页已有的取件码不受影响。")
                .setPositiveButton("清除并重新登录", (d, w) -> clearLogin(idx))
                .setNegativeButton("取消", null)
                .show();
    }

    void clearLogin(int idx) {
        CookieManager cm = CookieManager.getInstance();
        cm.removeAllCookies(done -> {
            cm.flush();
            WebStorage.getInstance().deleteAllData();
            for (int i = 1; i < webs.length; i++) {
                if (webs[i] == null) continue;
                webs[i].clearCache(true);
                webs[i].clearFormData();
                webs[i].clearHistory();
            }
            runOnUiThread(() -> {
                ensureWeb(idx);
                webs[idx].loadUrl(ENTRIES[idx]);
                store.setCollected(SITE_IDS[idx], new ArrayList<>(), "已清除登录");
                Toast.makeText(this, "已清除，重新登录一次", Toast.LENGTH_SHORT).show();
            });
        });
    }

    String SITE_NAME_CN(int idx) {
        String id = SITE_IDS[idx];
        return id == null ? "首页" : store.siteLabel(id);
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

    // ---------------- 分享取件码图片 ----------------

    void sharePick() {
        if (store.items.isEmpty()) { toast("还没有取件码"); return; }
        final List<PickupItem> all = new ArrayList<>(store.items);
        final boolean[] sel = new boolean[all.size()];
        final String[] labels = new String[all.size()];
        for (int i = 0; i < all.size(); i++) {
            sel[i] = true;   // 默认全选，用户再把不要的取消
            PickupItem it = all.get(i);
            StringBuilder m = new StringBuilder(store.siteLabel(it.site));
            if (!it.station.isEmpty()) m.append(" · ").append(it.station);
            labels[i] = it.code + "\n" + m;
        }
        final AlertDialog dlg = new AlertDialog.Builder(this)
                .setTitle("选要分享的取件码")
                .setMultiChoiceItems(labels, sel, (d, which, checked) -> sel[which] = checked)
                .setNegativeButton("取消", null)
                .setNeutralButton("全选/全不选", null)
                .setPositiveButton("生成图片", null)
                .create();
        dlg.setOnShowListener(d -> {
            dlg.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                List<PickupItem> chosen = new ArrayList<>();
                for (int i = 0; i < all.size(); i++) if (sel[i]) chosen.add(all.get(i));
                if (chosen.isEmpty()) { toast("至少选一个"); return; }
                dlg.dismiss();
                shareBitmap(chosen);
            });
            dlg.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> {
                boolean anyOff = false;
                for (boolean b : sel) if (!b) anyOff = true;
                for (int i = 0; i < sel.length; i++) {
                    sel[i] = anyOff;
                    dlg.getListView().setItemChecked(i, anyOff);
                }
            });
        });
        dlg.show();
    }

    void shareBitmap(List<PickupItem> chosen) {
        try {
            android.graphics.Bitmap bmp = ShareCard.render(chosen, store);
            String name = "share_" + System.currentTimeMillis() + ".png";
            File f = new File(ShotProvider.dir(this), name);
            java.io.FileOutputStream out = new java.io.FileOutputStream(f);
            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out);
            out.close();
            Uri uri = ShotProvider.uriFor(this, name);
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("image/png");
            i.putExtra(Intent.EXTRA_STREAM, uri);
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "分享取件码图片"));
        } catch (Exception e) {
            toast("生成图片失败：" + e);
        }
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
        box.setPadding(dp(18), dp(10), dp(18), dp(6));

        TextView tip = new TextView(this);
        tip.setText("截图里的取件码可以直接识别：选一张相册里的截图，或者现在拍一张");
        tip.setTextSize(12);
        tip.setTextColor(GREY);
        tip.setLineSpacing(dp(2), 1f);
        box.addView(tip);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(10), 0, dp(4));
        TextView pick = pill("从图库选图", RED, Color.WHITE);
        TextView shot = pill("拍一张", INK, Color.rgb(0, 0, 0));
        row.addView(pick);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        slp.leftMargin = dp(8);
        row.addView(shot, slp);
        box.addView(row);

        TextView or = new TextView(this);
        or.setText("或者手打");
        or.setTextSize(12);
        or.setTextColor(GREY);
        or.setPadding(0, dp(8), 0, dp(2));
        box.addView(or);

        EditText code = new EditText(this);
        code.setHint("取件码，如 122-3-12020 或 B-13016");
        code.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS);
        box.addView(code);

        EditText station = new EditText(this);
        station.setHint("驿站 / 位置（可不填）");
        box.addView(station);

        LinearLayout row2 = new LinearLayout(this);
        row2.setOrientation(LinearLayout.HORIZONTAL);
        row2.setPadding(0, dp(12), 0, dp(2));
        TextView cancel = pill("取消", GREY, Color.rgb(0, 0, 0));
        TextView add = pill("添加", RED, Color.WHITE);
        row2.addView(cancel);
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        alp.leftMargin = dp(8);
        row2.addView(add, alp);
        box.addView(row2);

        AlertDialog dlg = new AlertDialog.Builder(this)
                .setTitle("添加取件码")
                .setView(box)
                .create();

        pick.setOnClickListener(v -> { dlg.dismiss(); pickImage(); });
        shot.setOnClickListener(v -> { dlg.dismiss(); shotImage(); });
        cancel.setOnClickListener(v -> dlg.dismiss());
        add.setOnClickListener(v -> {
            boolean ok = store.addManual(code.getText().toString(),
                    station.getText().toString().trim(), "");
            Toast.makeText(this, ok ? "已添加" : "格式不对或重复了", Toast.LENGTH_SHORT).show();
            if (ok) dlg.dismiss();
        });
        dlg.show();
    }

    // ---------------- 截图识别 ----------------

    static final int REQ_PICK = 101, REQ_SHOT = 102;

    static final Pattern CODE_LOOSE = Pattern.compile(
            "[0-9A-Za-z]{1,4}\\s*[-－—–−]\\s*[0-9]{1,7}(?:\\s*[-－—–−]\\s*[0-9]{1,7})?");

    static final Pattern STATION_RE = Pattern.compile(
            "([\\u4e00-\\u9fa5A-Za-z0-9·（）()]{2,14}(?:驿站|快递柜|服务站|自提点))");

    private File pendingShot;

    void pickImage() {
        // 别用 ACTION_GET_CONTENT：它会调起「文件」App，默认按文件名升序，看起来就是老照片在前。
        // Android 13+ 用系统照片选择器（网格、最近的在前、不要存储权限）；更低版本用相册 ACTION_PICK。
        try {
            Intent i;
            if (Build.VERSION.SDK_INT >= 33) {
                i = new Intent(MediaStore.ACTION_PICK_IMAGES);
                i.setType("image/*");
            } else {
                i = new Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI);
                i.setType("image/*");
            }
            startActivityForResult(i, REQ_PICK);
        } catch (Exception e) {
            try {
                Intent g = new Intent(Intent.ACTION_GET_CONTENT);
                g.setType("image/*");
                g.addCategory(Intent.CATEGORY_OPENABLE);
                startActivityForResult(Intent.createChooser(g, "选一张取件列表截图"), REQ_PICK);
            } catch (Exception e2) {
                toast("这台机没有能挑图片的应用");
            }
        }
    }

    void shotImage() {
        try {
            File f = new File(ShotProvider.dir(this), "shot_" + System.currentTimeMillis() + ".jpg");
            pendingShot = f;
            Uri out = ShotProvider.uriFor(this, f.getName());
            Intent i = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            i.putExtra(MediaStore.EXTRA_OUTPUT, out);
            i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivityForResult(i, REQ_SHOT);
        } catch (Exception e) {
            toast("打不开相机");
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (res != RESULT_OK) return;
        Uri uri = null;
        if (req == REQ_PICK && data != null) uri = data.getData();
        if (req == REQ_SHOT && pendingShot != null && pendingShot.length() > 0) uri = Uri.fromFile(pendingShot);
        if (uri != null) ocr(uri);
    }

    void ocr(Uri uri) {
        final InputImage img;
        try {
            img = InputImage.fromFilePath(this, uri);
        } catch (Exception e) {
            toast("这张图读不了");
            return;
        }
        toast("识别中…");
        TextRecognition.getClient(new ChineseTextRecognizerOptions.Builder().build())
                .process(img)
                .addOnSuccessListener(t -> showOcrResult(t.getText()))
                .addOnFailureListener(e -> toast("识别失败：" + e.getMessage()));
    }

    void showOcrResult(String raw) {
        final List<String> found = new ArrayList<>();
        String text = raw == null ? "" : raw;
        Matcher m = CODE_LOOSE.matcher(text);
        while (m.find()) {
            String c = Store.normalize(m.group());
            if (!c.isEmpty() && Store.looksLikeCode(c) && !found.contains(c)) found.add(c);
        }
        if (found.isEmpty()) {
            toast("没认出取件码，换张清楚点的图试试");
            return;
        }
        String station = "";
        Matcher sm = STATION_RE.matcher(text);
        if (sm.find()) station = sm.group(1);
        final String st = station;

        final boolean[] sel = new boolean[found.size()];
        for (int i = 0; i < sel.length; i++) sel[i] = true;

        new AlertDialog.Builder(this)
                .setTitle("认出 " + found.size() + " 个取件码")
                .setMultiChoiceItems(found.toArray(new String[0]), sel,
                        (d, which, checked) -> sel[which] = checked)
                .setPositiveButton("加入首页", (d, w) -> {
                    int n = 0;
                    for (int i = 0; i < found.size(); i++) {
                        if (sel[i] && store.addManual(found.get(i), st, "")) n++;
                    }
                    toast(n > 0 ? ("已加入 " + n + " 个") : "这些都已经在列表里了");
                })
                .setNegativeButton("取消", null)
                .show();
    }

    void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show();
    }

    void showDiag() {
        StringBuilder head = new StringBuilder();
        head.append("版本：").append(versionName()).append("\n");
        head.append("设备：").append(Build.MANUFACTURER).append(' ').append(Build.MODEL)
            .append(" / Android ").append(Build.VERSION.RELEASE).append("\n");
        head.append("壳 UA：").append(safariUA()).append("\n");

        String[][] probes = {{"www.taobao.com", "https://www.taobao.com"},
                {"m.taobao.com", "https://m.taobao.com"},
                {"page.cainiao.com", "https://page.cainiao.com"},
                {"m.pinduoduo.net", "https://m.pinduoduo.net"},
                {"acs.m.taobao.com", "https://acs.m.taobao.com"}};
        CookieManager cm = CookieManager.getInstance();
        for (String[] p : probes) {
            String c = cm.getCookie(p[1]);
            int n = (c == null || c.trim().isEmpty()) ? 0 : c.split(";").length;
            head.append("cookie ").append(p[0]).append("：").append(n).append(" 条\n");
        }
        String tc = cm.getCookie("https://www.taobao.com");
        if (tc == null) tc = "";
        StringBuilder have = new StringBuilder();
        StringBuilder miss = new StringBuilder();
        for (String n : new String[]{"cookie2", "_tb_token_", "unb", "_l_g_", "sgcookie",
                "lgc", "tracknick", "_m_h5_tk", "cna"}) {
            if (tc.contains(n + "=")) have.append(n).append(' ');
            else miss.append(n).append(' ');
        }
        head.append("淘宝会话 cookie 有：").append(have.toString().trim()).append("\n");
        head.append("淘宝会话 cookie 缺：").append(
                miss.toString().trim().isEmpty() ? "（无）" : miss.toString().trim()).append("\n");
        for (String k : store.siteState.keySet()) {
            head.append(store.siteLabel(k)).append("：").append(store.siteState.get(k)).append("\n");
        }

        final String[] siteDiag = new String[4];
        final java.util.concurrent.atomic.AtomicInteger done =
                new java.util.concurrent.atomic.AtomicInteger(0);
        final int total = 3;
        for (int i = 1; i <= 3; i++) {
            final int idx = i;
            WebView wv = webs[idx];
            if (wv == null) {
                siteDiag[idx] = "{\"err\":\"这个标签还没打开过（先点进去一次）\"}";
                if (done.incrementAndGet() == total) diagMtopAndShow(head, siteDiag);
                continue;
            }
            String js = "(function(){try{var d=window.__pickupDiagnostics?window.__pickupDiagnostics()"
                    + ":{err:'agent 没注入'};return JSON.stringify(d);}catch(e){return JSON.stringify({err:String(e)});}})()";
            wv.evaluateJavascript(js, value -> {
                siteDiag[idx] = jsonUnquote(value);
                if (done.incrementAndGet() == total) diagMtopAndShow(head, siteDiag);
            });
        }
    }

    void diagMtopAndShow(final StringBuilder head, final String[] siteDiag) {
        Mtop.call("mtop.cainiao.lpc.packageservice.xiniao.querypacklist",
                "{\"staId\":\"\",\"day\":30,\"needAuthControl\":true}", reply -> {
                    final StringBuilder sb = new StringBuilder(head);
                    for (int i = 1; i <= 3; i++) {
                        sb.append("\n===== ").append(TABS[i]).append(" =====\n");
                        sb.append(pretty(siteDiag[i])).append("\n");
                        List<String> nav = navLogs.get(i);
                        if (nav == null || nav.isEmpty()) {
                            sb.append("nav：还没有导航记录\n");
                        } else {
                            sb.append("nav(").append(nav.size()).append(")：\n");
                            for (int k = Math.max(0, nav.size() - 8); k < nav.size(); k++) {
                                sb.append("  ").append(k + 1).append(". ").append(nav.get(k)).append("\n");
                            }
                        }
                    }
                    sb.append("\n===== 菜鸟原生接口 =====\n");
                    sb.append("ret：").append(reply.ret).append("\n");
                    sb.append("原生抓到：").append(reply.items.size()).append(" 件\n");
                    int n = 0;
                    for (PickupItem it : reply.items) {
                        if (n++ >= 8) break;
                        sb.append(it.code).append("  ｜ ").append(it.station)
                          .append(" ｜ ").append(it.place).append("\n");
                    }
                    if (reply.items.isEmpty() && reply.raw != null && !reply.raw.isEmpty()) {
                        sb.append("raw：").append(reply.raw.length() > 1200
                                ? reply.raw.substring(0, 1200) + "…" : reply.raw).append("\n");
                    }
                    String firstRec = Mtop.firstRecord(reply.data, 1500);
                    if (!firstRec.isEmpty()) {
                        sb.append(firstRec).append("\n");
                    }
                    sb.append("\n首页共 ").append(store.items.size()).append(" 条\n");
                    for (PickupItem it : store.items) {
                        sb.append(it.code).append("  ｜ ").append(store.siteLabel(it.site))
                          .append(" ｜ ").append(it.station).append(" ｜ ").append(it.place).append("\n");
                    }
                    runOnUiThread(() -> showDiagText(sb.toString()));
                });
    }

    String pretty(String json) {
        if (json == null || json.trim().isEmpty()) return "（空）";
        try {
            JSONObject o = new JSONObject(json);
            StringBuilder sb = new StringBuilder();
            java.util.Iterator<String> it = o.keys();
            while (it.hasNext()) {
                String k = it.next();
                String v = String.valueOf(o.opt(k));
                if (v.length() > 900) v = v.substring(0, 900) + "…";
                sb.append(k).append("：").append(v).append("\n");
            }
            return sb.toString();
        } catch (Exception e) {
            return json.length() > 1200 ? json.substring(0, 1200) : json;
        }
    }

    String jsonUnquote(String v) {
        if (v == null) return "";
        v = v.trim();
        if (v.length() > 1 && v.startsWith("\"") && v.endsWith("\"")) {
            try {
                return new JSONArray("[" + v + "]").getString(0);
            } catch (Exception e) {
                return v;
            }
        }
        return v;
    }

    void showDiagText(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
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
                    copy(text);
                    Toast.makeText(this, "已复制 " + text.length() + " 字", Toast.LENGTH_SHORT).show();
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
