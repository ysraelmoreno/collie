import Testing
import Foundation
import CollieProtocol
@testable import CollieDevice

private let xml = """
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
<node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">
<node index="0" text="" resource-id="" class="android.widget.LinearLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">
<node index="0" text="Entrar" resource-id="app:id/login_btn" class="android.widget.Button" content-desc="" clickable="true" bounds="[400,1180][680,1240]" />
<node index="1" text="" resource-id="" class="android.widget.TextView" content-desc="" clickable="false" bounds="[0,0][10,10]" />
</node></node></hierarchy>
"""

@Test func uiTreeCompacts() {
    let (nodes, trunc) = UITree.parse(Data(xml.utf8))
    #expect(!trunc && nodes.count == 1)
    #expect(nodes[0].ref == "e1" && nodes[0].center == (540, 1210) && nodes[0].depth == 2)
    #expect(UITree.lines(nodes) == "    [e1] Button \"Entrar\" id=login_btn (540,1210) clickable")
}

@Test func uiTreeCaps() {
    var s = "<hierarchy>"
    for i in 0..<5 { s += "<node text=\"t\(i)\" class=\"android.widget.TextView\" bounds=\"[0,0][2,2]\" clickable=\"false\"/>" }
    s += "</hierarchy>"
    let (nodes, trunc) = UITree.parse(Data(s.utf8), cap: 3)
    #expect(nodes.count == 3 && trunc && nodes[2].ref == "e3")
}

@Test func devicesParses() {
    let out = """
    * daemon not running; starting now at tcp:5037
    * daemon started successfully
    List of devices attached
    emulator-5554          device product:sdk_gphone64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
    R58M                   unauthorized usb:1-1 transport_id:3

    """
    let d = AdbParsing.devices(out)
    #expect(d.count == 2)
    #expect(d[0] == AdbDevice(serial: "emulator-5554", state: "device", model: "sdk_gphone64_arm64", product: "sdk_gphone64"))
    #expect(d[1].serial == "R58M" && d[1].state == "unauthorized" && d[1].model == nil)
}

@Test func ttyDumpKeepsTheXmlAndDropsTheTrailer() {
    let out = Data((xml + "UI hierchary dumped to: /dev/tty\n").utf8)
    #expect(AdbParsing.ttyDump(out).map { String(decoding: $0, as: UTF8.self) } == xml)
    #expect(UITree.parse(AdbParsing.ttyDump(out)!).nodes.count == 1)
    #expect(AdbParsing.ttyDump(Data("ERROR: could not get idle state.\n".utf8)) == nil)   // falls back to the file dump
    #expect(AdbParsing.ttyDump(Data(xml.prefix(200).utf8)) == nil)   // cut short
    #expect(AdbParsing.ttyDump(Data()) == nil)
}

@Test func pngSizeReadsIHDR() {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
    d += Data([0, 0, 4, 0x38, 0, 0, 9, 0x60])
    #expect(AdbParsing.pngSize(d)! == (1080, 2400))
    #expect(AdbParsing.pngSize(Data([1, 2, 3])) == nil)
}

@Test func inputTextEscapesShell() throws {
    #expect(try AdbParsing.inputTextArg("a b") == "'a%sb'")
    #expect(try AdbParsing.inputTextArg("it's $(rm -rf /)") == "'it'\\''s%s$(rm%s-rf%s/)'")
    do { _ = try AdbParsing.inputTextArg("a%sb"); Issue.record("expected throw") } catch { #expect(error.code == .invalidArgs) }
    do { _ = try AdbParsing.inputTextArg("ação"); Issue.record("expected throw") } catch {
        #expect(error.code == .invalidArgs)
        #expect(error.message == "device.text supports ASCII only; use device.key or the panel for other characters")
    }
}

@Test func crashLogGroupsJavaCrash() {
    var c = CrashLog()
    var ev = c.feed(line: "E/AndroidRuntime( 123): FATAL EXCEPTION: main")
    ev += c.feed(line: "E/AndroidRuntime( 123): Process: com.foo, PID: 123")
    ev += c.feed(line: "E/AndroidRuntime( 123): java.lang.IllegalStateException: boom")
    #expect(ev.isEmpty)
    let f = c.flush()
    #expect(f.count == 1 && f[0].package == "com.foo")
    #expect(f[0].text.split(separator: "\n").count == 3 && f[0].text.utf8.count <= 4096)
    #expect(c.flush().isEmpty)
}

@Test func crashLogNativeCrash() {
    var c = CrashLog()
    let ev = c.feed(line: "F/libc    ( 456): Fatal signal 11 (SIGSEGV), code 1, fault addr 0x0 in tid 456 (main), pid 456 (com.bar)")
    #expect(ev.count + c.flush().count == 1)
    #expect((ev + c.flush()).first?.package == "com.bar")
}

@Test func annexBSplitsAndConverts() {
    let d = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 1, 0x65, 0xCC])
    #expect(AnnexB.nalUnits(d) == [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 0xCC])])
    let ps = AnnexB.parameterSets(d)
    #expect(ps?.sps == Data([0x67, 0xAA]) && ps?.pps == Data([0x68, 0xBB]))
    #expect(AnnexB.avcc(d) == Data([0, 0, 0, 2, 0x67, 0xAA, 0, 0, 0, 2, 0x68, 0xBB, 0, 0, 0, 2, 0x65, 0xCC]))
}

@Test func avdsSkipsLogLines() {
    let out = "INFO    | Storing crashdata in: /tmp/x\nPixel_7_API_34\n\nTablet_API_33\nPixel_7_API_34\n"
    #expect(AdbParsing.avds(out) == ["Pixel_7_API_34", "Tablet_API_33"])
}

@Test func uiTreeCompactDropsIdOnlyNodesAndKeepsRefs() {
    let s = """
    <hierarchy>
    <node text="" resource-id="app:id/root" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">
    <node text="Deals" resource-id="" class="android.widget.TextView" content-desc="" clickable="false" bounds="[0,0][100,100]" />
    <node text="" resource-id="app:id/frame" class="android.view.ViewGroup" content-desc="" clickable="false" bounds="[0,0][10,10]" />
    <node text="" resource-id="app:id/configuration_fab" class="android.widget.Button" content-desc="" clickable="true" bounds="[600,100][664,172]" />
    <node text="" resource-id="" class="android.widget.ImageView" content-desc="Close" clickable="false" bounds="[0,0][20,20]" />
    </node></hierarchy>
    """
    let (nodes, trunc) = UITree.parse(Data(s.utf8))
    let compact = UITree.compact(nodes)
    #expect(compact.map(\.ref) == ["e2", "e4", "e5"])   // e1 and e3 only have an id
    #expect(UITree.lines(compact).contains("[e4] Button id=configuration_fab (632,136) clickable"))
    // same refs with and without --all: every compact node is the same node in the full tree
    for n in compact { #expect(nodes.first(where: { $0.ref == n.ref }) == n) }
    guard case .object(let c) = UITree.result(nodes, truncated: trunc, all: false),
          case .object(let a) = UITree.result(nodes, truncated: trunc, all: true) else { Issue.record("not an object"); return }
    #expect(c["nodes"] == .number(3) && c["total"] == .number(5) && a["nodes"] == .number(5) && a["total"] == .number(5))
    #expect(c["tree"] == .string(UITree.lines(compact)) && a["tree"] == .string(UITree.lines(nodes)))
}

@Test func humanizeIdCases() {
    #expect(humanizeId("configuration_fab") == "configuration fab")
    #expect(humanizeId("topBarMenu") == "top bar menu")
    #expect(humanizeId("ICON-btn") == "icon btn")
    #expect(humanizeId("") == "")
}

/// The BEES Offers dump (2026-11-21): configuration_fab is a clickable Button with no text or desc.
@Test func findByHumanizedId() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/offers-ui.xml")
    let nodes = UITree.parse(try Data(contentsOf: url)).nodes
    let fab = try UITree.target(nodes, text: "configuration fab", id: nil, nth: 1)   // what `device find` runs
    #expect(fab.id == "configuration_fab")
    #expect(try UITree.target(nodes, text: "Configuration", id: nil, nth: nil).id == "configuration_fab")   // contains
    #expect(throws: ProtocolError.self) { try UITree.target(nodes, text: "toolbar", id: nil, nth: nil) }   // not clickable: no id match
    do { _ = try UITree.target(nodes, text: "+", id: nil, nth: 1); Issue.record("found") } catch {
        #expect(error.code == .notFound && error.message.contains("; unlabeled: ") && error.message.contains("\(fab.ref) id=configuration_fab"), "\(error.message)")
    }
}
