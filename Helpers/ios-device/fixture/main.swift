import UIKit
import SpriteKit
import WebKit

// Telas com árvore de acessibilidade boa e pobre, para o corpus do OCR.
// Uso: xcrun simctl launch <udid> com.collie.fixture.ios --screen <nome> [--dark]
// nomes: normal | canvas | game | webcanvas | hidden | photo | list | form
let args = CommandLine.arguments
let screenName = args.firstIndex(of: "--screen").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "normal"
let dark = args.contains("--dark")
let BG: UIColor = dark ? UIColor(white: 0.07, alpha: 1) : .white
let FG: UIColor = dark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.07, alpha: 1)

func label(_ t: String, _ size: CGFloat = 17, bold: Bool = false) -> UILabel {
    let l = UILabel(); l.text = t; l.textColor = FG; l.numberOfLines = 0
    l.font = .systemFont(ofSize: size, weight: bold ? .bold : .regular); return l
}
func stack(_ v: [UIView]) -> UIStackView {
    let s = UIStackView(arrangedSubviews: v); s.axis = .vertical; s.spacing = 14; s.alignment = .leading; return s
}
func pin(_ v: UIView, in c: UIView, top: CGFloat = 16) {
    v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v)
    let g = c.safeAreaLayoutGuide
    NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: g.topAnchor, constant: top),
        v.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20), v.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20)])
}
func button(_ t: String) -> UIButton {
    var c = UIButton.Configuration.filled(); c.title = t
    return UIButton(configuration: c)
}

class Base: UIViewController {
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = BG; overrideUserInterfaceStyle = dark ? .dark : .light }
}

// 1. normal: acessibilidade boa
final class Normal: Base {
    override func viewDidLoad() {
        super.viewDidLoad()
        let s = stack([label("Painel de Vendas", 28, bold: true),
            label("Total do mês: R$ 1.234,56 em 42 pedidos"),
            button("Confirmar pedido"),
            label("Atualizado às 14:35. Versão 2.0.1", 11)])
        pin(s, in: view)
    }
}

// 2. canvas: tudo desenhado com Core Graphics, sem elementos de acessibilidade
final class CanvasView: UIView {
    override func draw(_ r: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()!
        func text(_ t: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: UIColor, bold: Bool = false) {
            (t as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), .foregroundColor: c])
        }
        let top = safeAreaInsets.top + 16
        text("Relatório Anual", 20, top, 28, FG, bold: true)
        text("Receita: R$ 1.234,56 · 42 pedidos", 20, top + 50, 17, FG)
        func btn(_ t: String, _ y: CGFloat) {
            let b = CGRect(x: 20, y: y, width: 220, height: 48)
            ctx.setFillColor(UIColor.systemBlue.cgColor); UIBezierPath(roundedRect: b, cornerRadius: 10).fill()
            text(t, 40, y + 13, 18, .white)
        }
        btn("Exportar dados", top + 100); btn("Configurações", top + 168)
        // botão "+" só com ícone desenhado
        let c = CGRect(x: 20, y: top + 248, width: 56, height: 56)
        ctx.setFillColor(UIColor.systemGreen.cgColor); ctx.fillEllipse(in: c)
        ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: c.midX - 12, y: c.midY)); ctx.addLine(to: CGPoint(x: c.midX + 12, y: c.midY))
        ctx.move(to: CGPoint(x: c.midX, y: c.midY - 12)); ctx.addLine(to: CGPoint(x: c.midX, y: c.midY + 12)); ctx.strokePath()
        text("Rodapé: atualizado às 14:35", 20, top + 330, 11, FG)
    }
}
final class Canvas: Base {
    override func viewDidLoad() { super.viewDidLoad(); let v = CanvasView(frame: view.bounds); v.backgroundColor = BG
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(v) }
}

// 3. game: SpriteKit com HUD
final class Game: Base {
    override func viewDidLoad() {
        super.viewDidLoad()
        let v = SKView(frame: view.bounds); v.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(v)
        let s = SKScene(size: view.bounds.size); s.backgroundColor = dark ? .black : UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        func n(_ t: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, align: SKLabelHorizontalAlignmentMode = .left) {
            let l = SKLabelNode(text: t); l.fontName = "Helvetica-Bold"; l.fontSize = size; l.fontColor = .white
            l.horizontalAlignmentMode = align; l.position = CGPoint(x: x, y: s.size.height - y); s.addChild(l)
        }
        let top: CGFloat = 100
        n("SCORE: 12.450", 20, top, 22); n("Vidas: 3", s.size.width - 20, top, 22, align: .right)
        n("Nível 7", s.size.width / 2, top + 50, 20, align: .center)
        let b = SKShapeNode(rect: CGRect(x: s.size.width / 2 - 90, y: s.size.height / 2 - 30, width: 180, height: 60), cornerRadius: 12)
        b.fillColor = .systemOrange; b.strokeColor = .clear; s.addChild(b)
        let j = SKLabelNode(text: "JOGAR"); j.fontName = "Helvetica-Bold"; j.fontSize = 28; j.fontColor = .white
        j.verticalAlignmentMode = .center; j.position = CGPoint(x: s.size.width / 2, y: s.size.height / 2); s.addChild(j)
        v.presentScene(s)
    }
}

// 4. webcanvas: texto dentro de <canvas>
final class WebCanvas: Base {
    override func viewDidLoad() {
        super.viewDidLoad()
        let w = WKWebView(frame: view.bounds); w.autoresizingMask = [.flexibleWidth, .flexibleHeight]; w.isOpaque = false; view.addSubview(w)
        let bg = dark ? "#121212" : "#ffffff", fg = dark ? "#eeeeee" : "#111111"
        w.loadHTMLString("""
        <html><head><meta name=viewport content='width=device-width,initial-scale=1'></head>
        <body style='margin:0;background:\(bg)'><canvas id=c style='width:100vw;height:100vh'></canvas><script>
        var c=document.getElementById('c');var d=window.devicePixelRatio||1;c.width=innerWidth*d;c.height=innerHeight*d;
        var x=c.getContext('2d');x.scale(d,d);x.fillStyle='\(fg)';
        x.font='bold 28px -apple-system';x.fillText('Gráfico de Vendas',20,110);
        x.font='17px -apple-system';x.fillText('Total: R$ 1.234,56',20,150);x.fillText('Região Sul · 42 pedidos',20,180);
        x.fillStyle='#0a84ff';x.fillRect(20,210,200,48);x.fillStyle='#fff';x.font='18px -apple-system';x.fillText('Baixar relatório',40,241);
        x.fillStyle='\(fg)';x.font='11px -apple-system';x.fillText('Rodapé: atualizado às 14:35',20,300);
        </script></body></html>
        """, baseURL: nil)
    }
}

// 5. hidden: views comuns, mas escondidas da acessibilidade
final class Hidden: Base {
    override func viewDidLoad() {
        super.viewDidLoad()
        let s = stack([label("Área Restrita", 28, bold: true), label("Saldo: R$ 1.234,56"), button("Entrar agora"), label("Termos de uso, versão 3", 11)])
        s.accessibilityElementsHidden = true; s.isAccessibilityElement = false
        s.arrangedSubviews.forEach { $0.isAccessibilityElement = false; $0.accessibilityElementsHidden = true }
        pin(s, in: view)
    }
}

// 6. photo: texto claro sobre gradiente com ruído
final class Photo: Base {
    override func viewDidLoad() {
        super.viewDidLoad()
        let size = view.bounds.size
        let img = UIGraphicsImageRenderer(size: size).image { r in
            let c = r.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            let g = CGGradient(colorsSpace: cs, colors: [UIColor(red: 0.1, green: 0.35, blue: 0.55, alpha: 1).cgColor, UIColor(red: 0.85, green: 0.5, blue: 0.2, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<6000 {
                c.setFillColor(UIColor(white: CGFloat.random(in: 0...1, using: &rng), alpha: 0.18).cgColor)
                c.fill(CGRect(x: CGFloat.random(in: 0...size.width, using: &rng), y: CGFloat.random(in: 0...size.height, using: &rng), width: 3, height: 3))
            }
            let top: CGFloat = 76
            func t(_ s: String, _ y: CGFloat, _ sz: CGFloat, bold: Bool = false) {
                let sh = NSShadow(); sh.shadowColor = UIColor.black.withAlphaComponent(0.4); sh.shadowBlurRadius = 3
                (s as NSString).draw(at: CGPoint(x: 20, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: sz, weight: bold ? .bold : .regular), .foregroundColor: UIColor.white, .shadow: sh])
            }
            t("Férias em Floripa", top, 30, bold: true); t("A partir de R$ 1.234,56 por pessoa", top + 50, 18)
            t("Reserve até 30/12 e ganhe desconto", top + 85, 18); t("Condições sujeitas a alteração", top + 130, 11)
        }
        let iv = UIImageView(image: img); iv.frame = view.bounds; iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(iv)
    }
}

// 7. list: 80 itens + 2 abas + busca
final class ListVC: UITableViewController, UISearchResultsUpdating {
    var shown = (1...80).map { String(format: "Produto %03d", $0) }
    override func viewDidLoad() {
        super.viewDidLoad(); tableView.backgroundColor = BG; overrideUserInterfaceStyle = dark ? .dark : .light
        title = "Catálogo"
        let sc = UISearchController(searchResultsController: nil); sc.searchResultsUpdater = self; sc.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = sc
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
    }
    func updateSearchResults(for s: UISearchController) {
        let q = s.searchBar.text ?? ""; let all = (1...80).map { String(format: "Produto %03d", $0) }
        shown = q.isEmpty ? all : all.filter { $0.lowercased().contains(q.lowercased()) }; tableView.reloadData()
    }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { shown.count }
    override func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "c", for: i); c.textLabel?.text = shown[i.row]
        c.textLabel?.textColor = FG; c.backgroundColor = BG; return c
    }
}
func listRoot() -> UIViewController {
    let tb = UITabBarController()
    let a = UINavigationController(rootViewController: ListVC()); a.tabBarItem = UITabBarItem(title: "Produtos", image: UIImage(systemName: "list.bullet"), tag: 0)
    a.navigationBar.prefersLargeTitles = true
    let b = Base(); b.view.addSubview({ let l = label("Favoritos: nenhum item"); l.frame = CGRect(x: 20, y: 140, width: 300, height: 30); return l }())
    b.tabBarItem = UITabBarItem(title: "Favoritos", image: UIImage(systemName: "star"), tag: 1)
    tb.viewControllers = [a, b]; tb.overrideUserInterfaceStyle = dark ? .dark : .light; return tb
}

// 8. form
final class Form: Base {
    override func viewDidLoad() {
        super.viewDidLoad()
        let name = UITextField(); name.placeholder = "Nome completo"; name.borderStyle = .roundedRect
        let mail = UITextField(); mail.placeholder = "E-mail"; mail.borderStyle = .roundedRect
        let sw = UISwitch(); let row = UIStackView(arrangedSubviews: [label("Receber novidades"), sw]); row.spacing = 12
        let pk = UISegmentedControl(items: ["Mensal", "Anual", "Vitalício"]); pk.selectedSegmentIndex = 0
        let ok = button("Enviar cadastro")
        ok.addAction(UIAction { [weak self] _ in
            let a = UIAlertController(title: "Cadastro enviado", message: "Obrigado! Total: R$ 1.234,56", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Fechar", style: .default)); self?.present(a, animated: true) }, for: .touchUpInside)
        let sh = button("Ver termos")
        sh.addAction(UIAction { [weak self] _ in
            let v = Base(); v.view.addSubview({ let l = label("Termos de uso", 24, bold: true); l.frame = CGRect(x: 20, y: 40, width: 300, height: 40); return l }())
            v.modalPresentationStyle = .pageSheet; self?.present(v, animated: true) }, for: .touchUpInside)
        let s = stack([label("Cadastro", 28, bold: true), name, mail, row, pk, ok, sh])
        s.alignment = .fill; pin(s, in: view)
    }
}

final class App: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ a: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.overrideUserInterfaceStyle = dark ? .dark : .light
        switch screenName {
        case "canvas": w.rootViewController = Canvas()
        case "game": w.rootViewController = Game()
        case "webcanvas": w.rootViewController = WebCanvas()
        case "hidden": w.rootViewController = Hidden()
        case "photo": w.rootViewController = Photo()
        case "list": w.rootViewController = listRoot()
        case "form": w.rootViewController = Form()
        default: w.rootViewController = Normal()
        }
        w.makeKeyAndVisible(); window = w; return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(App.self))
