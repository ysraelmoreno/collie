package com.collie.fixture;

import android.app.Activity;
import android.content.Context;
import android.graphics.*;
import android.os.Bundle;
import android.view.*;
import android.webkit.WebView;
import android.widget.*;

/** Screens whose accessibility tree is poor, for the OCR fallback corpus. Pick one with: am start -n com.collie.fixture/.MainActivity --es screen <name> [--ez dark true]
 *  canvas | surface | webcanvas | hidden | photo | normal (control: good tree) */
public class MainActivity extends Activity {
    boolean dark;
    int bg() { return dark ? 0xFF121212 : 0xFFFFFFFF; }
    int fg() { return dark ? 0xFFEEEEEE : 0xFF111111; }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        dark = getIntent().getBooleanExtra("dark", false);
        String s = getIntent().getStringExtra("screen"); if (s == null) s = "normal";
        View v;
        switch (s) {
            case "canvas": v = new CanvasScreen(this); break;
            case "surface": v = new SurfaceScreen(this); break;
            case "webcanvas": v = web(); break;
            case "hidden": v = hidden(); break;
            case "photo": v = new PhotoScreen(this); break;
            default: v = normal();
        }
        setContentView(v);
    }

    /** Drawn text and shapes on a plain View: no accessibility nodes, like a canvas or game UI. */
    class CanvasScreen extends View {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        CanvasScreen(Context c) { super(c); }
        @Override protected void onDraw(Canvas c) {
            c.drawColor(bg());
            p.setColor(fg()); p.setTextSize(64); c.drawText("Configurações", 40, 200, p);
            p.setTextSize(40); c.drawText("Olá, Ysrael! Bem-vindo de volta", 40, 290, p);
            p.setTextSize(28); c.drawText("Texto pequeno de apoio, versão 2.4.1 (build 318)", 40, 350, p);
            String[] items = {"Entrar", "Criar conta", "Esqueci a senha"};
            for (int i = 0; i < items.length; i++) {
                int top = 400 + i * 150;
                p.setColor(0xFF1A73E8); c.drawRoundRect(new RectF(60, top, 660, top + 110), 24, 24, p);
                p.setColor(0xFFFFFFFF); p.setTextSize(44); c.drawText(items[i], 120, top + 70, p);
            }
            p.setColor(0xFFE91E63); c.drawCircle(600, 960, 60, p);          // "+" button: no text on purpose
            p.setColor(0xFFFFFFFF); p.setStrokeWidth(12); c.drawLine(570, 960, 630, 960, p); c.drawLine(600, 930, 600, 990, p);
            p.setColor(fg()); p.setTextSize(36); c.drawText("Total: R$ 1.234,56", 40, 975, p);
        }
    }

    /** SurfaceView with a game-like HUD. */
    class SurfaceScreen extends SurfaceView implements SurfaceHolder.Callback {
        SurfaceScreen(Context c) { super(c); getHolder().addCallback(this); }
        public void surfaceCreated(SurfaceHolder h) {
            Canvas c = h.lockCanvas(); Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
            c.drawColor(0xFF0B1020);
            p.setColor(0xFFFFD54F); p.setTextSize(56); c.drawText("SCORE 001240", 40, 120, p);
            p.setColor(0xFFFFFFFF); p.setTextSize(44); c.drawText("Vidas: 3", 520, 120, p); c.drawText("Nível 7", 40, 190, p);
            p.setColor(0xFF4CAF50); c.drawRoundRect(new RectF(160, 700, 560, 840), 40, 40, p);
            p.setColor(0xFFFFFFFF); p.setTextSize(64); c.drawText("JOGAR", 260, 790, p);
            p.setColor(0xFFB0BEC5); p.setTextSize(30); c.drawText("Toque para continuar", 200, 900, p);
            h.unlockCanvasAndPost(c);
        }
        public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) {}
        public void surfaceDestroyed(SurfaceHolder h) {}
    }

    /** Text rendered inside an HTML canvas in a WebView: not in the DOM, so not in the accessibility tree. */
    View web() {
        WebView w = new WebView(this); w.getSettings().setJavaScriptEnabled(true);
        String html = "<html><body style='margin:0;background:" + (dark ? "#121212" : "#fff") + "'><canvas id=c width=720 height=1280 style='width:100%'></canvas><script>"
            + "var x=document.getElementById('c').getContext('2d');x.fillStyle='" + (dark ? "#eee" : "#111") + "';"
            + "x.font='bold 60px sans-serif';x.fillText('Resumo do pedido',40,160);x.font='40px sans-serif';"
            + "x.fillText('Cerveja Pilsen 350ml  x12',40,280);x.fillText('Refrigerante Cola 2L  x6',40,350);"
            + "x.fillText('Subtotal: R$ 189,90',40,470);x.fillStyle='#1a73e8';x.fillRect(60,600,600,120);"
            + "x.fillStyle='#fff';x.font='bold 48px sans-serif';x.fillText('Finalizar pedido',160,675);"
            + "</script></body></html>";
        w.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
        return w;
    }

    /** Ordinary views, but hidden from accessibility: an app that ships no semantics. */
    View hidden() {
        LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); l.setBackgroundColor(bg()); l.setPadding(40, 160, 40, 40);
        l.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        l.addView(label("Meus pedidos", 34, true)); l.addView(label("Pedido #48213 - Entregue", 20, false));
        l.addView(label("Pedido #48210 - Em transporte", 20, false));
        Button b = new Button(this); b.setText("Ver detalhes"); l.addView(b); l.addView(label("Atualizado há 3 minutos", 14, false));
        return l;
    }

    /** Light text over a photo-like background: the hard case for OCR. */
    class PhotoScreen extends View {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        PhotoScreen(Context c) { super(c); }
        @Override protected void onDraw(Canvas c) {
            p.setShader(new LinearGradient(0, 0, 720, 1280, new int[]{0xFF2E7D32, 0xFFF9A825, 0xFF6A1B9A, 0xFF0277BD}, null, Shader.TileMode.CLAMP));
            c.drawRect(0, 0, getWidth(), getHeight(), p); p.setShader(null);
            java.util.Random r = new java.util.Random(7);
            for (int i = 0; i < 400; i++) { p.setColor(Color.argb(60, r.nextInt(255), r.nextInt(255), r.nextInt(255))); c.drawCircle(r.nextInt(720), r.nextInt(1280), 10 + r.nextInt(50), p); }
            p.setColor(0xFFFFFFFF); p.setTextSize(72); c.drawText("Promoção da semana", 40, 300, p);
            p.setTextSize(44); c.drawText("Até 30% de desconto", 40, 400, p); p.setTextSize(30); c.drawText("Válido até 30/11 ou enquanto durarem os estoques", 40, 470, p);
            p.setColor(0xFF000000); p.setTextSize(44); c.drawText("Aproveite agora", 40, 620, p);
        }
    }

    /** Control: normal accessible views (a good tree), to check the fallback stays off. */
    View normal() {
        LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); l.setBackgroundColor(bg()); l.setPadding(40, 160, 40, 40);
        l.addView(label("Tela normal", 34, true)); l.addView(label("Todos os elementos têm acessibilidade", 20, false));
        Button b = new Button(this); b.setText("Continuar"); l.addView(b); l.addView(label("Rodapé de exemplo", 14, false));
        return l;
    }

    TextView label(String t, int sp, boolean bold) {
        TextView v = new TextView(this); v.setText(t); v.setTextSize(sp); v.setTextColor(fg()); if (bold) v.setTypeface(null, Typeface.BOLD); v.setPadding(0, 16, 0, 16); return v;
    }
}
