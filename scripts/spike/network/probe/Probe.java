import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;

/** Spike probe, run on the device with app_process: GETs a URL every few seconds through the system proxy and prints
 *  the status, or the TLS error. One long-lived process, so a CA added mid-run shows whether a running app picks it up. */
public class Probe {
    public static void main(String[] a) throws Exception {
        // app_process has no ActivityThread, so the global http_proxy is not applied: name the proxy (args[2] = port)
        Proxy proxy = new Proxy(Proxy.Type.HTTP, new InetSocketAddress("127.0.0.1", Integer.parseInt(a[2])));
        for (int i = 0; i < Integer.parseInt(a[1]); i++) {
            try {
                HttpsURLConnection c = (HttpsURLConnection) new URL(a[0] + "?probe=" + i).openConnection(proxy);
                c.setConnectTimeout(5000); c.setReadTimeout(5000);
                System.out.println(i + " " + c.getResponseCode() + " " + c.getClass().getName() + " via " + proxy);
                c.disconnect();
            } catch (Exception e) {
                System.out.println(i + " FAIL " + e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()).split("\n")[0]);
            }
            Thread.sleep(4000);
        }
    }
}
