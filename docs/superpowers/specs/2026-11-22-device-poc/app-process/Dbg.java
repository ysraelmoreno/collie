import android.app.UiAutomation;
import android.os.HandlerThread;
import java.lang.reflect.*;
public class Dbg { public static void main(String[] a) throws Exception {
  System.out.println("1"); HandlerThread ht = new HandlerThread("ui"); ht.start();
  Class<?> connC = Class.forName("android.app.UiAutomationConnection");
  for (Constructor<?> k : UiAutomation.class.getConstructors()) System.out.println("ctor " + k);
  Object conn = connC.getConstructor().newInstance(); System.out.println("2");
  Class<?> iuac = Class.forName("android.app.IUiAutomationConnection");
  UiAutomation ua = UiAutomation.class.getConstructor(android.os.Looper.class, iuac).newInstance(ht.getLooper(), conn); System.out.println("3");
  UiAutomation.class.getMethod("connect").invoke(ua); System.out.println("4 connected");
  System.out.println(ua.getRootInActiveWindow() != null);
  System.exit(0);
} }
