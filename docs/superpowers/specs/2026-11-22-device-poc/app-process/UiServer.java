import android.app.UiAutomation;
import android.os.HandlerThread;
import android.view.accessibility.AccessibilityNodeInfo;
import android.graphics.Rect;
import java.io.*;
import java.lang.reflect.*;

/** Spike: resident UI tree dumper. stdin line "dump" -> uiautomator-style XML then a line "\u0001END". */
public class UiServer {
    static StringBuilder sb;
    static String esc(CharSequence s) {
        if (s == null) return "";
        return s.toString().replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }
    static void walk(AccessibilityNodeInfo n, int idx) {
        if (n == null) return;
        Rect r = new Rect(); n.getBoundsInScreen(r);
        sb.append("<node index=\"").append(idx).append("\" text=\"").append(esc(n.getText()))
          .append("\" resource-id=\"").append(esc(n.getViewIdResourceName()))
          .append("\" class=\"").append(esc(n.getClassName()))
          .append("\" content-desc=\"").append(esc(n.getContentDescription()))
          .append("\" clickable=\"").append(n.isClickable())
          .append("\" bounds=\"[").append(r.left).append(",").append(r.top).append("][").append(r.right).append(",").append(r.bottom).append("]\">");
        for (int i = 0; i < n.getChildCount(); i++) { AccessibilityNodeInfo c = n.getChild(i); walk(c, i); if (c != null) c.recycle(); }
        sb.append("</node>");
    }
    public static void main(String[] a) throws Exception {
        HandlerThread ht = new HandlerThread("ui"); ht.start();
        Class<?> connC = Class.forName("android.app.UiAutomationConnection");
        Object conn = connC.getConstructor().newInstance();
        Class<?> iuac = Class.forName("android.app.IUiAutomationConnection");
        UiAutomation ua = UiAutomation.class.getConstructor(android.os.Looper.class, iuac).newInstance(ht.getLooper(), conn);
        UiAutomation.class.getMethod("connect").invoke(ua);
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        out.println("READY");
        String line;
        while ((line = in.readLine()) != null) {
            if (line.equals("quit")) break;
            long t0 = System.nanoTime();
            sb = new StringBuilder("<?xml version='1.0' encoding='UTF-8'?><hierarchy>");
            AccessibilityNodeInfo root = ua.getRootInActiveWindow();
            walk(root, 0);
            sb.append("</hierarchy>");
            out.println(sb);
            out.println("\u0001END " + (System.nanoTime() - t0) / 1000000 + "ms");
        }
        UiAutomation.class.getMethod("disconnect").invoke(ua);
        System.exit(0);
    }
}
