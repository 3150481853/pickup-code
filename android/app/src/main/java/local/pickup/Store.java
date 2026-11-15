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
    /** 置顶的取件码，顺序即置顶顺序 */
    public final List<String> pinned = new ArrayList<>();
    /** 左划删除的码，按站点记：源里还有它就继续藏，源里没了就自动清掉 */
    private final Map<String, List<String>> dismissed = new LinkedHashMap<>();
    /** 拿快递模式里点过的码 */
    public final List<String> picked = new ArrayList<>();
    /** 已归档（已取件 / 已出库） */
    public final List<PickupItem> archived = new ArrayList<>();
    /** 这一站上次还有、这次没了的时间点 —— 满 10 分钟才归档 */
    private final Map<String, Long> missingSince = new LinkedHashMap<>();
    private final Map<String, String> archiveNotes = new LinkedHashMap<>();
    public static final long MISSING_GRACE = 10 * 60 * 1000L;
    private final SharedPreferences sp;
    private Runnable onChange = () -> {};

    public Store(Context ctx) {
        sp = ctx.getSharedPreferences("pickup", Context.MODE_PRIVATE);
        loadManual();
        loadPrefs();
        loadArchive();
        republish();
    }

    public void setOnChange(Runnable r) { onChange = r; }

    public String siteLabel(String site) {
        String s = SITE_NAME.get(site);
        return s == null ? site : s;
    }

    // ---- 网页抓取结果 ----

    public void setCollected(String site, List<PickupItem> list, String state) {
        reconcile(site, list);          // 先跟上一次的名单比，才能看出「哪些没了」
        collected.put(site, list);
        if (state != null) siteState.put(site, state);
        pruneDismissed(site, list);
        republish();
    }

    // ---- 名单比对：少了 → 疑似已出库 → 10 分钟后归档 ----

    private void reconcile(String site, List<PickupItem> list) {
        List<String> fresh = new ArrayList<>();
        if (list != null) for (PickupItem it : list) if (it != null) fresh.add(it.code);
        List<PickupItem> before = collected.get(site);
        if (before != null) {
            for (PickupItem it : before) {
                if (it == null || fresh.contains(it.code)) continue;
                if (!missingSince.containsKey(it.code)) missingSince.put(it.code, System.currentTimeMillis());
            }
        }
        for (String c : fresh) {
            missingSince.remove(c);
            picked.remove(c);       // 又出现在名单里，说明没取走
        }
        saveArchive();
    }

    /** 由 MainActivity 的定时器调用：标记超过 10 分钟的归档掉 */
    public void archiveMissingIfNeeded() {
        if (missingSince.isEmpty()) return;
        long cut = System.currentTimeMillis() - MISSING_GRACE;
        List<String> due = new ArrayList<>();
        for (Map.Entry<String, Long> e : missingSince.entrySet()) {
            if (e.getValue() <= cut) due.add(e.getKey());
        }
        if (due.isEmpty()) return;
        for (String code : due) {
            PickupItem hit = null;
            for (PickupItem it : items) if (it.code.equals(code)) { hit = it; break; }
            if (hit != null) archiveNow(hit, "疑似已出库");
            else missingSince.remove(code);
        }
        saveArchive();
        republish();
    }

    public boolean isPicked(String code) { return picked.contains(code); }
    public boolean isMissing(String code) { return missingSince.containsKey(code); }

    public void togglePicked(PickupItem it) {
        if (picked.contains(it.code)) picked.remove(it.code);
        else picked.add(it.code);
        saveArchive();
        republish();
    }

    /** 归档一条：从各站名单 / 手动里摘掉，进 archived（不是删除，可以「放回」） */
    public void archiveNow(PickupItem it, String note) {
        for (int i = manual.size() - 1; i >= 0; i--) {
            if (manual.get(i).code.equals(it.code)) manual.remove(i);
        }
        for (Map.Entry<String, List<PickupItem>> e : collected.entrySet()) {
            List<PickupItem> l = e.getValue();
            if (l == null) continue;
            List<PickupItem> keep = new ArrayList<>();
            for (PickupItem x : l) if (x != null && !x.code.equals(it.code)) keep.add(x);
            e.setValue(keep);
        }
        missingSince.remove(it.code);
        picked.remove(it.code);
        archiveNotes.put(it.code, note);
        for (int i = archived.size() - 1; i >= 0; i--) {
            if (archived.get(i).code.equals(it.code)) archived.remove(i);
        }
        archived.add(0, it);
        while (archived.size() > 200) archived.remove(archived.size() - 1);
        saveArchive();
        saveManual();
        republish();
    }

    /** 拿快递模式收工：把所有「已拿到」的批量归档，返回条数 */
    public int archivePicked() {
        List<PickupItem> targets = new ArrayList<>();
        for (PickupItem it : items) if (picked.contains(it.code)) targets.add(it);
        for (PickupItem it : targets) archiveNow(it, "已取件");
        return targets.size();
    }

    /** 归档区「放回首页」 */
    public void restore(PickupItem it) {
        for (int i = archived.size() - 1; i >= 0; i--) {
            if (archived.get(i).code.equals(it.code)) archived.remove(i);
        }
        archiveNotes.remove(it.code);
        if ("manual".equals(it.site)) {
            manual.remove(it);
            manual.add(it);
        } else {
            List<PickupItem> l = collected.get(it.site);
            if (l == null) { l = new ArrayList<>(); collected.put(it.site, l); }
            List<PickupItem> keep = new ArrayList<>();
            for (PickupItem x : l) if (x != null && !x.code.equals(it.code)) keep.add(x);
            keep.add(it);
            collected.put(it.site, keep);
        }
        saveArchive();
        saveManual();
        republish();
    }

    public String archiveNote(String code) {
        String s = archiveNotes.get(code);
        return s == null ? "已取件" : s;
    }

    public void clearSite(String site) {
        collected.remove(site);
        siteState.remove(site);
        republish();
    }

    // ---- 置顶 / 左划删除 ----

    public boolean isPinned(String code) {
        return pinned.contains(code);
    }

    public void togglePin(String code) {
        if (pinned.contains(code)) pinned.remove(code);
        else pinned.add(code);
        savePrefs();
        republish();
    }

    /** 左划删除：手动录入的直接删掉；网页/接口抓来的记进「划走」列表，否则下次抓取又回来 */
    public void dismiss(PickupItem it) {
        if ("manual".equals(it.site)) {
            removeManual(it.code);
            return;
        }
        List<String> list = dismissed.get(it.site);
        if (list == null) { list = new ArrayList<>(); dismissed.put(it.site, list); }
        if (!list.contains(it.code)) list.add(it.code);
        savePrefs();
        republish();
    }

    /** 这次抓取里已经没这个码了，就把它从「划走」里清掉，免得以后同一个码再也出不来 */
    private void pruneDismissed(String site, List<PickupItem> list) {
        if (!dismissed.containsKey(site)) return;
        List<String> live = new ArrayList<>();
        if (list != null) for (PickupItem it : list) if (it != null) live.add(it.code);
        if (live.isEmpty()) {
            dismissed.remove(site);
        } else {
            List<String> kept = new ArrayList<>();
            for (String c : dismissed.get(site)) if (live.contains(c)) kept.add(c);
            if (kept.isEmpty()) dismissed.remove(site);
            else dismissed.put(site, kept);
        }
        savePrefs();
    }

    private void loadPrefs() {
        try {
            String raw = sp.getString("pinned.v1", "");
            if (raw != null && !raw.isEmpty()) {
                JSONArray arr = new JSONArray(raw);
                for (int i = 0; i < arr.length(); i++) pinned.add(arr.getString(i));
            }
        } catch (Exception ignored) {}
        try {
            String raw = sp.getString("dismissed.v1", "");
            if (raw != null && !raw.isEmpty()) {
                JSONObject o = new JSONObject(raw);
                java.util.Iterator<String> keys = o.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    JSONArray arr = o.optJSONArray(k);
                    List<String> list = new ArrayList<>();
                    if (arr != null) for (int i = 0; i < arr.length(); i++) list.add(arr.getString(i));
                    dismissed.put(k, list);
                }
            }
        } catch (Exception ignored) {}
    }

    private void savePrefs() {
        try {
            JSONArray arr = new JSONArray();
            for (String c : pinned) arr.put(c);
            JSONObject o = new JSONObject();
            for (Map.Entry<String, List<String>> e : dismissed.entrySet()) {
                JSONArray a = new JSONArray();
                for (String c : e.getValue()) a.put(c);
                o.put(e.getKey(), a);
            }
            sp.edit().putString("pinned.v1", arr.toString())
                     .putString("dismissed.v1", o.toString()).apply();
        } catch (Exception ignored) {}
    }

    // ---- 已拿到 / 归档 落盘 ----

    private void saveArchive() {
        try {
            JSONArray p = new JSONArray();
            for (String c : picked) p.put(c);
            JSONObject miss = new JSONObject();
            for (Map.Entry<String, Long> e : missingSince.entrySet()) miss.put(e.getKey(), e.getValue());
            JSONObject notes = new JSONObject();
            for (Map.Entry<String, String> e : archiveNotes.entrySet()) notes.put(e.getKey(), e.getValue());
            JSONArray arch = new JSONArray();
            for (PickupItem it : archived) {
                JSONObject o = new JSONObject();
                o.put("code", it.code);
                o.put("site", it.site);
                o.put("station", it.station);
                o.put("place", it.place);
                o.put("mailNo", it.mailNo == null ? "" : it.mailNo);
                o.put("img", it.img == null ? "" : it.img);
                o.put("note", archiveNote(it.code));
                arch.put(o);
            }
            sp.edit().putString("picked.v1", p.toString())
                     .putString("missing.v1", miss.toString())
                     .putString("archived.notes.v1", notes.toString())
                     .putString("archived.v1", arch.toString()).apply();
        } catch (Exception ignored) {}
    }

    private void loadArchive() {
        try {
            String raw = sp.getString("picked.v1", "");
            if (raw != null && !raw.isEmpty()) {
                JSONArray arr = new JSONArray(raw);
                for (int i = 0; i < arr.length(); i++) picked.add(arr.getString(i));
            }
        } catch (Exception ignored) {}
        try {
            String raw = sp.getString("missing.v1", "");
            if (raw != null && !raw.isEmpty()) {
                JSONObject o = new JSONObject(raw);
                java.util.Iterator<String> keys = o.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    missingSince.put(k, o.optLong(k));
                }
            }
        } catch (Exception ignored) {}
        try {
            String raw = sp.getString("archived.notes.v1", "");
            if (raw != null && !raw.isEmpty()) {
                JSONObject o = new JSONObject(raw);
                java.util.Iterator<String> keys = o.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    archiveNotes.put(k, o.optString(k));
                }
            }
        } catch (Exception ignored) {}
        try {
            String raw = sp.getString("archived.v1", "");
            if (raw == null || raw.isEmpty()) return;
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                archived.add(new PickupItem(o.optString("code"), o.optString("site"),
                        o.optString("station"), o.optString("place"),
                        o.optString("mailNo"), o.optString("img")));
            }
        } catch (Exception ignored) {}
    }

    // ---- 手动录入 ----

    public boolean addManual(String rawCode, String station, String place) {
        return addManual(rawCode, station, place, "");
    }

    public boolean addManual(String rawCode, String station, String place, String mailNo) {
        String code = normalize(rawCode);
        if (!looksLikeCode(code)) return false;
        for (PickupItem it : manual) if (it.code.equals(code)) return false;
        manual.add(new PickupItem(code, "manual", station, place,
                mailNo == null ? "" : mailNo.trim().toUpperCase(), ""));
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
                if (seen.contains(it.code)) {
                    // 同码已经有了：把空着的驿站/货位/单号补上（手动条目常常只填了码）
                    for (PickupItem had : out) {
                        if (!had.code.equals(it.code)) continue;
                        if (had.station == null || had.station.isEmpty()) had.station = it.station;
                        if (had.place == null || had.place.isEmpty()) had.place = it.place;
                        if (had.mailNo == null || had.mailNo.isEmpty()) had.mailNo = it.mailNo;
                        if (had.img == null || had.img.isEmpty()) had.img = it.img;
                        break;
                    }
                    continue;
                }
                seen.add(it.code);
                out.add(it);
            }
        }
        // 划走删除的藏起来
        List<PickupItem> kept = new ArrayList<>();
        for (PickupItem it : out) if (!isDismissed(it)) kept.add(it);
        out = kept;
        // 已取/已出库的也藏起来：菜鸟接口按近 30 天返回，取走的件会一遍遍落回来，
        // 只从 collected 里摘掉不够（下一轮轮询又灌回来，「明明都出了还在列表里」就是这么来的）
        if (!archived.isEmpty()) {
            List<String> gone = new ArrayList<>();
            for (PickupItem a : archived) if (a.code != null) gone.add(a.code);
            List<PickupItem> kept2 = new ArrayList<>();
            for (PickupItem it : out) if (!gone.contains(it.code)) kept2.add(it);
            out = kept2;
        }
        // 置顶的最前面（按置顶先后），其余按取件码排
        Collections.sort(out, (a, b) -> {
            int pa = pinned.indexOf(a.code);
            int pb = pinned.indexOf(b.code);
            if (pa < 0) pa = Integer.MAX_VALUE;
            if (pb < 0) pb = Integer.MAX_VALUE;
            if (pa != pb) return pa < pb ? -1 : 1;
            return codeCompare(a.code, b.code);
        });
        items.clear();
        items.addAll(out);
        onChange.run();
    }

    private boolean isDismissed(PickupItem it) {
        List<String> list = dismissed.get(it.site);
        return list != null && list.contains(it.code);
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
                        o.optString("station"), o.optString("place"),
                        o.optString("mailNo"), ""));
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
                o.put("mailNo", it.mailNo == null ? "" : it.mailNo);
                arr.put(o);
            }
            sp.edit().putString("manual.v1", arr.toString()).apply();
        } catch (Exception ignored) {}
    }
}
