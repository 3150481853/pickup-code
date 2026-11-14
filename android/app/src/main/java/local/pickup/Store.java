package local.pickup;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 首页的数据中心：把「网页抓到的」「原生 mtop 抓到的」「手动加的」按取件码合并。
 * 手动加的优先（用户自己确认过），其余按码排序。
 */
public class Store {

    public static final Map<String, String> SITE_NAME = new LinkedHashMap<>();
    static {
        SITE_NAME.put("cainiao", "菜鸟");
        SITE_NAME.put("pdd", "拼多多");
        SITE_NAME.put("taobao", "淘宝");
        SITE_NAME.put("manual", "手动");
    }

    public final List<PickupItem> items = new ArrayList<>();
    public final Map<String, String> siteState = new LinkedHashMap<>();

    private final List<PickupItem> manual = new ArrayList<>();
    private final Map<String, List<PickupItem>> collected = new LinkedHashMap<>();
    private final SharedPreferences sp;
    private Runnable onChange = () -> {};

    public Store(Context ctx) {
        sp = ctx.getSharedPreferences("pickup", Context.MODE_PRIVATE);
        loadManual();
        republish();
    }

    public void setOnChange(Runnable r) { onChange = r; }

    public String siteLabel(String site) {
        String s = SITE_NAME.get(site);
        return s == null ? site : s;
    }

    // ---- 网页抓取结果 ----

    public void setCollected(String site, List<PickupItem> list, String state) {
        collected.put(site, list);
        if (state != null) siteState.put(site, state);
        republish();
    }

    public void clearSite(String site) {
        collected.remove(site);
        siteState.remove(site);
        republish();
    }

    // ---- 手动录入 ----

    public boolean addManual(String rawCode, String station, String place) {
        String code = normalize(rawCode);
        if (!looksLikeCode(code)) return false;
        for (PickupItem it : manual) if (it.code.equals(code)) return false;
        manual.add(new PickupItem(code, "manual", station, place));
        saveManual();
        republish();
        return true;
    }

    public void removeManual(String code) {
        for (int i = manual.size() - 1; i >= 0; i--) {
            if (manual.get(i).code.equals(code)) manual.remove(i);
        }
        saveManual();
        republish();
    }

    // ---- 合并 ----

    public void republish() {
        List<PickupItem> out = new ArrayList<>();
        List<String> seen = new ArrayList<>();
        for (PickupItem it : manual) {
            out.add(it);
            seen.add(it.code);
        }
        for (List<PickupItem> list : collected.values()) {
            if (list == null) continue;
            for (PickupItem it : list) {
                if (it == null || it.code == null || it.code.isEmpty()) continue;
                if (seen.contains(it.code)) continue;
                seen.add(it.code);
                out.add(it);
            }
        }
        Collections.sort(out, (a, b) -> codeCompare(a.code, b.code));
        items.clear();
        items.addAll(out);
        onChange.run();
    }

    public static int codeCompare(String a, String b) {
        int[] pa = parts(a);
        int[] pb = parts(b);
        for (int i = 0; i < Math.min(pa.length, pb.length); i++) {
            if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1;
        }
        if (pa.length != pb.length) return pa.length < pb.length ? -1 : 1;
        return a.compareTo(b);
    }

    private static int[] parts(String code) {
        String[] seg = code.split("-");
        int[] r = new int[seg.length];
        for (int i = 0; i < seg.length; i++) {
            try { r[i] = Integer.parseInt(seg[i].replaceAll("[^0-9]", "")); }
            catch (Exception e) { r[i] = 0; }
        }
        return r;
    }

    // ---- 码的规整与判定（和 iOS 版同一套规则）----

    public static String normalize(String s) {
        if (s == null) return "";
        String t = s.toUpperCase();
        t = t.replace('\uFF0D', '-')   // －
             .replace('\u2014', '-')   // —
             .replace('\u2013', '-')   // –
             .replace('\u2212', '-')   // −
             .replace('\u3000', ' ')
             .replaceAll("\\s+", "");
        return t;
    }

    public static boolean looksLikeCode(String code) {
        if (code == null || code.isEmpty()) return false;
        // 122-3-12020 / 54-4-13021 / B-13016 / 12-3456
        return code.matches("^[A-Z]{1,3}-[0-9]{1,7}$")
            || code.matches("^[0-9]{1,4}-[0-9]{1,7}(-[0-9]{1,7})?$");
    }

    private void loadManual() {
        try {
            String raw = sp.getString("manual.v1", "");
            if (raw == null || raw.isEmpty()) return;
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                manual.add(new PickupItem(o.optString("code"), "manual",
                        o.optString("station"), o.optString("place")));
            }
        } catch (Exception ignored) {}
    }

    private void saveManual() {
        try {
            JSONArray arr = new JSONArray();
            for (PickupItem it : manual) {
                JSONObject o = new JSONObject();
                o.put("code", it.code);
                o.put("station", it.station);
                o.put("place", it.place);
                arr.put(o);
            }
            sp.edit().putString("manual.v1", arr.toString()).apply();
        } catch (Exception ignored) {}
    }
}
