package local.pickup;

import android.webkit.CookieManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

/**
 * 直接调淘宝 mtop（和 iOS 版 Mtop.swift 同一套做法）。
 *
 * 为什么不在网页里调：签名 token 存在 `.taobao.com` 域的 `_m_h5_tk` 里，
 * 菜鸟页面的 JS 跑在 `page.cainiao.com`，读不到别的域的 cookie → 签名必错 →
 * 永远 FAIL_SYS_SESSION_EXPIRED。原生这边能拿到全部 cookie，自己算签名。
 */
public class Mtop {

    public static final String APP_KEY = "12574478";

    public static class Reply {
        public String api = "";
        public String ret = "";
        public String raw = "";
        public Object data = null;
        public List<PickupItem> items = new ArrayList<>();
        public boolean ok() { return ret.startsWith("SUCCESS"); }
    }

    public interface Callback {
        void done(Reply reply);
    }

    public static void call(String api, String data, Callback cb) {
        new Thread(() -> {
            Reply r = new Reply();
            r.api = api;
            try {
                String t = String.valueOf(System.currentTimeMillis());
                String cookie = cookieHeader();
                String token = tokenOf(cookie);
                if (token.isEmpty()) {
                    r.ret = "TOKEN_EMPTY::本地没有 _m_h5_tk，先登录淘宝";
                    cb.done(r);
                    return;
                }
                String sign = md5(token + "&" + t + "&" + APP_KEY + "&" + data);
                String url = "https://acs.m.taobao.com/h5/" + api + "/1.0/"
                        + "?jsv=2.7.2"
                        + "&appKey=" + APP_KEY
                        + "&t=" + t
                        + "&sign=" + sign
                        + "&api=" + api
                        + "&v=1.0"
                        + "&type=originaljson"
                        + "&dataType=json"
                        + "&timeout=20000"
                        + "&data=" + URLEncoder.encode(data, "UTF-8");

                HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
                conn.setConnectTimeout(15000);
                conn.setReadTimeout(20000);
                conn.setRequestProperty("Cookie", cookie);
                conn.setRequestProperty("User-Agent", ua());
                conn.setRequestProperty("Referer", "https://page.cainiao.com/");
                conn.setRequestProperty("Accept", "application/json");

                StringBuilder sb = new StringBuilder();
                try (InputStream in = conn.getInputStream();
                     BufferedReader br = new BufferedReader(new InputStreamReader(in, "UTF-8"))) {
                    String line;
                    while ((line = br.readLine()) != null) sb.append(line);
                } catch (Exception e) {
                    // 非 200 时也要读错误体，mtop 的错都在 body 里
                    try (InputStream in = conn.getErrorStream();
                         BufferedReader br = new BufferedReader(new InputStreamReader(in, "UTF-8"))) {
                        String line;
                        while ((line = br.readLine()) != null) sb.append(line);
                    } catch (Exception ignored) {}
                }
                r.raw = sb.toString();
                JSONObject root = new JSONObject(r.raw);
                Object retObj = root.opt("ret");
                if (retObj instanceof JSONArray) {
                    r.ret = ((JSONArray) retObj).optString(0, "");
                } else {
                    r.ret = String.valueOf(retObj);
                }
                Object dataObj = root.opt("data");
                r.data = dataObj;
                if (r.ret.startsWith("SUCCESS") && dataObj != null) {
                    r.items = Parser.parse(dataObj);
                }
            } catch (Exception e) {
                r.ret = "ERROR::" + e;
                if (r.raw.isEmpty()) r.raw = String.valueOf(e);
            }
            cb.done(r);
        }, "mtop").start();
    }

    static String ua() {
        String v = android.os.Build.VERSION.RELEASE;
        return "Mozilla/5.0 (Linux; Android " + v + ") AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36";
    }

    /** 用 taobao.com 的 URL 去问 CookieManager，才会把 `.taobao.com` 上那些会话票带出来。 */
    static String cookieHeader() {
        String c = CookieManager.getInstance().getCookie("https://www.taobao.com");
        return c == null ? "" : c;
    }

    static String tokenOf(String cookie) {
        for (String part : cookie.split(";")) {
            String p = part.trim();
            if (p.startsWith("_m_h5_tk=")) {
                String v = p.substring("_m_h5_tk=".length());
                int i = v.indexOf('_');
                return i < 0 ? v : v.substring(0, i);
            }
        }
        return "";
    }

    public static String md5(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] d = md.digest(s.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    /** 诊断用：把 data.result[0] 的字段名和整条 JSON 打出来，方便看清码倒底藏在哪个字段 */
    public static String firstRecord(Object data, int max) {
        try {
            Object rec = null;
            if (data instanceof JSONObject) {
                Object r = ((JSONObject) data).opt("result");
                if (r instanceof JSONArray && ((JSONArray) r).length() > 0) rec = ((JSONArray) r).opt(0);
                else rec = data;
            } else if (data instanceof JSONArray && ((JSONArray) data).length() > 0) {
                rec = ((JSONArray) data).opt(0);
            }
            if (!(rec instanceof JSONObject)) return "";
            JSONObject o = (JSONObject) rec;
            StringBuilder keys = new StringBuilder();
            for (java.util.Iterator<String> it = o.keys(); it.hasNext(); ) {
                if (keys.length() > 0) keys.append(' ');
                keys.append(it.next());
            }
            String json = o.toString();
            if (json.length() > max) json = json.substring(0, max) + "…";
            return "首条字段：" + keys + "\n首条 JSON：" + json;
        } catch (Exception e) {
            return "";
        }
    }

    /** mtop 返回结构没有文档，只能递归扫：任何看起来像取件码的字符串都收下来。 */
    public static class Parser {
        public static List<PickupItem> parse(Object data) {
            List<PickupItem> out = new ArrayList<>();
            List<String> seen = new ArrayList<>();
            walk(data, out, seen, 0);
            return out;
        }

        static void walk(Object node, List<PickupItem> out, List<String> seen, int depth) {
            if (node == null || depth > 10) return;
            if (node instanceof JSONArray) {
                JSONArray arr = (JSONArray) node;
                for (int i = 0; i < arr.length(); i++) walk(arr.opt(i), out, seen, depth + 1);
                return;
            }
            if (!(node instanceof JSONObject)) return;
            JSONObject o = (JSONObject) node;

            String code = codeOf(o);
            if (code != null && !seen.contains(code)) {
                seen.add(code);
                // 驿站名常常藏在 feature / feature2 里那层转义过的 JSON（postName / daishouName）
                List<String> cand = new ArrayList<>();
                collect(o, cand, 0);
                out.add(new PickupItem(code, "cainiao", stationOf(cand), placeOf(cand)));
            }
            for (java.util.Iterator<String> it = o.keys(); it.hasNext(); ) {
                Object v = o.opt(it.next());
                if (v instanceof String) walkString((String) v, out, seen, depth + 1);
                else walk(v, out, seen, depth + 1);
            }
        }

        /** 字符串值本身可能是一层转义 JSON，解开继续找 */
        static void walkString(String s, List<PickupItem> out, List<String> seen, int depth) {
            if (s == null) return;
            String t = s.trim();
            if (t.length() < 2) return;
            boolean isArr = t.startsWith("[") && t.endsWith("]");
            boolean isObj = t.startsWith("{") && t.endsWith("}");
            if (!isArr && !isObj) return;
            try {
                walk(isArr ? (Object) new JSONArray(t) : new JSONObject(t), out, seen, depth + 1);
            } catch (Exception ignored) {}
        }

        /** 字段名带 code / pick 的先看，其次任意字符串 */
        static String codeOf(JSONObject o) {
            String loose = null;
            for (java.util.Iterator<String> it = o.keys(); it.hasNext(); ) {
                String k = it.next();
                Object v = o.opt(k);
                if (!(v instanceof String)) continue;
                String s = Store.normalize((String) v);
                if (!isCode(s)) continue;
                String lk = k.toLowerCase();
                if (lk.contains("code") || lk.contains("pick")) return s;
                if (loose == null) loose = s;
            }
            return loose;
        }

        /** 把这一层 + 里面转义 JSON 里的字符串都收集起来，用来挑驿站名/货位 */
        static void collect(JSONObject o, List<String> out, int depth) {
            if (depth > 2) return;
            for (java.util.Iterator<String> it = o.keys(); it.hasNext(); ) {
                Object v = o.opt(it.next());
                if (v instanceof String) {
                    String s = ((String) v).trim();
                    if (s.length() >= 2 && s.startsWith("{") && s.endsWith("}")) {
                        try { collect(new JSONObject(s), out, depth + 1); continue; }
                        catch (Exception ignored) {}
                    }
                    out.add(s);
                }
            }
        }

        static boolean isCode(String s) {
            if (s == null) return false;
            if (!s.matches("^[0-9]{1,4}-[0-9]{1,7}-[0-9]{3,7}$")) return false;
            String[] seg = s.split("-");
            return seg.length == 3 && seg[2].length() >= 3;
        }

        static final String[] ADDRESS_WORDS = {
                "省", "市", "区", "县", "镇", "街道", "路", "号", "栋", "楼", "室", "村", "小区"
        };

        static int score(String s, boolean station) {
            if (s == null || s.isEmpty() || s.length() > 40) return 0;
            int sc = 0;
            if (s.contains("驿站")) sc += 5;
            for (String w : new String[]{"服务站", "自提点", "快递柜", "超市", "便利店", "门卫", "收发室", "菜鸟"}) {
                if (s.contains(w)) sc += 3;
            }
            if (s.contains("服务中心")) sc += 1;
            for (String w : ADDRESS_WORDS) if (s.contains(w)) sc = 0;
            if (station && s.matches("^[0-9\\-]+$")) sc = 0;
            return sc;
        }

        /** 优先级：名字里明说是驿站的（postName/daishouName/stationName）> 打分 */
        static String stationOf(List<String> cand) {
            String bestStr = "";
            int bestScore = 0;
            for (String s : cand) {
                if (s.isEmpty()) continue;
                int sc = score(s, true);
                if (sc > bestScore) { bestScore = sc; bestStr = s; }
            }
            return bestScore >= 3 ? bestStr : "";
        }

        static String placeOf(List<String> cand) {
            for (String s : cand) {
                if (s.isEmpty() || s.length() > 24) continue;
                for (String w : new String[]{"货架", "货位", "取件位", "架号", "柜号"}) {
                    if (s.contains(w)) return s;
                }
            }
            return "";
        }
    }
}
