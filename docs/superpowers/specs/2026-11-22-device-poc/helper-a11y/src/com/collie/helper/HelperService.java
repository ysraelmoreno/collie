package com.collie.helper;
import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.graphics.Path;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.*;
import java.net.*;

public class HelperService extends AccessibilityService {
    static String esc(CharSequence s) { return s == null ? "" : s.toString().replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace("\"","&quot;"); }
    void walk(AccessibilityNodeInfo n, StringBuilder sb, int idx) {
        if (n == null) return;
        Rect r = new Rect(); n.getBoundsInScreen(r);
        sb.append("<node index=\"").append(idx).append("\" text=\"").append(esc(n.getText()))
          .append("\" resource-id=\"").append(esc(n.getViewIdResourceName()))
          .append("\" class=\"").append(esc(n.getClassName()))
          .append("\" content-desc=\"").append(esc(n.getContentDescription()))
          .append("\" clickable=\"").append(n.isClickable()).append("\" selected=\"").append(n.isSelected())
          .append("\" scrollable=\"").append(n.isScrollable())
          .append("\" bounds=\"[").append(r.left).append(",").append(r.top).append("][").append(r.right).append(",").append(r.bottom).append("]\">");
        for (int i = 0; i < n.getChildCount(); i++) { AccessibilityNodeInfo c = n.getChild(i); walk(c, sb, i); }
        sb.append("</node>");
    }
    @Override protected void onServiceConnected() {
        new Thread(() -> {
            try (ServerSocket ss = new ServerSocket(7788, 1, InetAddress.getByName("127.0.0.1"))) {
                while (true) {
                    try (Socket s = ss.accept()) {
                        BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream()));
                        PrintStream out = new PrintStream(s.getOutputStream(), true, "UTF-8");
                        String line;
                        while ((line = in.readLine()) != null) {
                            long t0 = System.nanoTime();
                            if (line.equals("dump")) {
                                StringBuilder sb = new StringBuilder("<hierarchy>");
                                walk(getRootInActiveWindow(), sb, 0);
                                sb.append("</hierarchy>");
                                out.println(sb); out.println("END " + (System.nanoTime() - t0) / 1000000 + "ms");
                            } else if (line.startsWith("tap ")) {
                                String[] p = line.split(" "); Path path = new Path(); path.moveTo(Float.parseFloat(p[1]), Float.parseFloat(p[2]));
                                dispatchGesture(new GestureDescription.Builder().addStroke(new GestureDescription.StrokeDescription(path, 0, 50)).build(), null, null);
                                out.println("OK tap");
                            } else if (line.equals("back")) { performGlobalAction(GLOBAL_ACTION_BACK); out.println("OK back"); }
                            else if (line.equals("quit")) break;
                        }
                    } catch (IOException e) { /* next client */ }
                }
            } catch (IOException e) { e.printStackTrace(); }
        }).start();
    }
    @Override public void onAccessibilityEvent(AccessibilityEvent e) {}
    @Override public void onInterrupt() {}
}
