package com.collie.helper;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.graphics.Path;
import android.graphics.Rect;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.Bundle;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Collie device helper (docs/superpowers/specs/2026-11-22-device-helper-design.md, H1).
 * An accessibility service that answers the daemon over an abstract unix socket (adb forward tcp:N localabstract:collie-helper).
 * One JSON object per line in, one per line out; the request "id" is echoed. Only uid shell (2000) and root (0) may connect:
 * what arrives through adbd. Text of password fields is masked, never sent.
 */
public class HelperService extends AccessibilityService {
    static final int VERSION = 2;
    static final String SOCKET = "collie-helper";

    private final List<Client> subscribers = new CopyOnWriteArrayList<>();
    private volatile long lastEvent;
    // The socket name is process-wide: a service that was unbound (toggled off and on, or rebound) must not keep answering
    // for a connection to the accessibility system it no longer has, so the owner is replaced on every connect.
    private static LocalServerSocket owner;
    private static final List<LocalSocket> conns = new CopyOnWriteArrayList<>();

    @Override protected void onServiceConnected() {
        closeOwner();
        Thread t = new Thread(this::serve, "collie-helper-accept");
        t.setDaemon(true);
        t.start();
    }

    private static synchronized void closeOwner() {
        if (owner != null) { try { owner.close(); } catch (IOException ignored) { } owner = null; }
        for (LocalSocket c : conns) { try { c.close(); } catch (IOException ignored) { } }
        conns.clear();
    }

    private static synchronized boolean claim(LocalServerSocket s) { owner = s; return true; }

    private void serve() {
        LocalServerSocket server;
        try { server = new LocalServerSocket(SOCKET); } catch (IOException e) { return; }
        claim(server);
        try {
            while (true) {
                LocalSocket s = server.accept();
                int uid = -1;
                try { uid = s.getPeerCredentials().getUid(); } catch (IOException ignored) { }
                if (uid != 2000 && uid != 0) { try { s.close(); } catch (IOException ignored) { } continue; }
                conns.add(s);
                Thread c = new Thread(() -> new Client(s).run(), "collie-helper-client");
                c.setDaemon(true);
                c.start();
            }
        } catch (IOException e) {
            // closed by a newer instance or the service is stopping
        } finally {
            try { server.close(); } catch (IOException ignored) { }
        }
    }

    @Override public boolean onUnbind(android.content.Intent i) { closeOwner(); return super.onUnbind(i); }
    @Override public void onInterrupt() { }

    @Override public void onAccessibilityEvent(AccessibilityEvent e) {
        if (subscribers.isEmpty()) return;
        long now = System.currentTimeMillis();
        if (now - lastEvent < 100) return;          // debounce
        lastEvent = now;
        String kind = e.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ? "window" : "content";
        try { JSONObject ev = new JSONObject().put("ev", kind).put("t", now); for (Client c : subscribers) c.send(ev); } catch (org.json.JSONException ignored) { }
    }

    final class Client {
        private final LocalSocket sock;
        private PrintStream out;
        Client(LocalSocket s) { sock = s; }

        synchronized void send(JSONObject o) { if (out != null) out.println(o.toString()); }

        void run() {
            try (BufferedReader in = new BufferedReader(new InputStreamReader(sock.getInputStream(), "UTF-8"))) {
                out = new PrintStream(sock.getOutputStream(), true, "UTF-8");
                String line;
                while ((line = in.readLine()) != null) {
                    JSONObject req;
                    try { req = new JSONObject(line); } catch (Exception e) { send(err(null, "bad json")); continue; }
                    JSONObject res;
                    try { res = handle(req); } catch (Exception e) { res = err(req, String.valueOf(e)); }
                    try { if (req.has("id")) res.put("id", req.opt("id")); } catch (org.json.JSONException ignored) { }
                    send(res);
                }
            } catch (IOException ignored) {
            } finally {
                subscribers.remove(this);
                try { sock.close(); } catch (IOException ignored) { }
            }
        }

        JSONObject handle(JSONObject r) throws Exception {
            switch (r.optString("op")) {
                case "hello": return hello();
                case "dump": return dump();
                case "tap": return gesture(r.getDouble("x"), r.getDouble("y"), r.getDouble("x"), r.getDouble("y"), 50);
                case "swipe": return gesture(r.getDouble("x1"), r.getDouble("y1"), r.getDouble("x2"), r.getDouble("y2"), r.optLong("ms", 300));
                case "click": return click(r.getJSONArray("path"));
                case "text": return text(r.getString("value"));
                case "scroll": return scroll(r.getJSONArray("path"), r.optString("dir", "fwd"));
                case "global": return global(r.getString("action"));
                case "subscribe": if (!subscribers.contains(this)) subscribers.add(this); return ok();
                default: return err(r, "unknown op");
            }
        }
    }

    static JSONObject ok() throws Exception { return new JSONObject().put("ok", true); }
    static JSONObject err(JSONObject req, String m) { try { return new JSONObject().put("ok", false).put("error", m); } catch (Exception e) { return new JSONObject(); } }

    JSONObject hello() throws Exception {
        android.util.DisplayMetrics d = getResources().getDisplayMetrics();
        return ok().put("version", VERSION).put("sdk", Build.VERSION.SDK_INT).put("w", d.widthPixels).put("h", d.heightPixels);
    }

    JSONObject dump() throws Exception {
        JSONArray nodes = new JSONArray();
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root != null) walk(root, new int[64], 0, nodes);
        return ok().put("nodes", nodes).put("root", root != null);
    }

    private void walk(AccessibilityNodeInfo n, int[] path, int depth, JSONArray out) throws Exception {
        if (n.isVisibleToUser()) {
            Rect r = new Rect(); n.getBoundsInScreen(r);
            JSONArray p = new JSONArray(); for (int i = 0; i < depth; i++) p.put(path[i]);
            boolean pw = n.isPassword();
            out.put(new JSONObject().put("p", p)
                .put("text", pw ? "•••" : s(n.getText())).put("desc", s(n.getContentDescription()))
                .put("id", s(n.getViewIdResourceName())).put("cls", s(n.getClassName()))
                .put("b", new JSONArray().put(r.left).put(r.top).put(r.right).put(r.bottom))
                .put("clk", n.isClickable()).put("sel", n.isSelected()).put("chk", n.isChecked()).put("en", n.isEnabled())
                .put("foc", n.isFocused()).put("scr", n.isScrollable()).put("pw", pw));
        }
        if (depth >= 63) return;
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c == null) continue;
            path[depth] = i; walk(c, path, depth + 1, out);
        }
    }

    private static String s(CharSequence c) { return c == null ? "" : c.toString(); }

    private AccessibilityNodeInfo at(JSONArray path) throws Exception {
        AccessibilityNodeInfo n = getRootInActiveWindow();
        try {
            for (int i = 0; n != null && i < path.length(); i++) n = n.getChild(path.getInt(i));
        } catch (IndexOutOfBoundsException e) { n = null; }   // the screen changed since the dump: the daemon re-reads and retries
        if (n == null) throw new IllegalStateException("node gone");
        return n;
    }

    JSONObject click(JSONArray path) throws Exception {
        AccessibilityNodeInfo n = at(path);
        for (AccessibilityNodeInfo c = n; c != null; c = c.getParent())
            if (c.isClickable() && c.isEnabled() && c.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return ok().put("via", "action");
        Rect r = new Rect(); n.getBoundsInScreen(r);
        return gesture(r.exactCenterX(), r.exactCenterY(), r.exactCenterX(), r.exactCenterY(), 50).put("via", "gesture");
    }

    JSONObject text(String value) throws Exception {
        AccessibilityNodeInfo f = findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (f == null) throw new IllegalStateException("no focused field");
        Bundle b = new Bundle(); b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
        return new JSONObject().put("ok", f.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b));
    }

    JSONObject scroll(JSONArray path, String dir) throws Exception {
        AccessibilityNodeInfo n = at(path);
        for (AccessibilityNodeInfo c = n; c != null; c = c.getParent())
            if (c.isScrollable()) return new JSONObject().put("ok", c.performAction(dir.equals("back") ? AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD : AccessibilityNodeInfo.ACTION_SCROLL_FORWARD));
        throw new IllegalStateException("nothing scrollable");
    }

    JSONObject global(String a) throws Exception {
        int id;
        switch (a) {
            case "back": id = GLOBAL_ACTION_BACK; break;
            case "home": id = GLOBAL_ACTION_HOME; break;
            case "recents": id = GLOBAL_ACTION_RECENTS; break;
            case "notifications": id = GLOBAL_ACTION_NOTIFICATIONS; break;
            default: throw new IllegalArgumentException("unknown action");
        }
        return new JSONObject().put("ok", performGlobalAction(id));
    }

    JSONObject gesture(double x1, double y1, double x2, double y2, long ms) throws Exception {
        Path p = new Path(); p.moveTo((float) x1, (float) y1); if (x1 != x2 || y1 != y2) p.lineTo((float) x2, (float) y2);
        GestureDescription g = new GestureDescription.Builder().addStroke(new GestureDescription.StrokeDescription(p, 0, Math.max(1, ms))).build();
        CountDownLatch done = new CountDownLatch(1);
        boolean[] okRef = {false};
        boolean started = dispatchGesture(g, new GestureResultCallback() {
            @Override public void onCompleted(GestureDescription d) { okRef[0] = true; done.countDown(); }
            @Override public void onCancelled(GestureDescription d) { done.countDown(); }
        }, null);
        if (!started) return new JSONObject().put("ok", false).put("error", "gesture not dispatched");
        done.await(ms + 1500, TimeUnit.MILLISECONDS);
        return new JSONObject().put("ok", okRef[0]);
    }
}
