import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

// openssl x509 -subject_hash_old → d6849034 (UTF-8 subject: CN=Collie Spike CA, O=Collie Spike, OU=örg ünïcode)
private let utf8CA = """
    -----BEGIN CERTIFICATE-----
    MIIB6TCCAY+gAwIBAgIUI4sb/P0h8EKV4kU0Fo90a4voreMwCgYIKoZIzj0EAwIw
    SjEYMBYGA1UEAwwPQ29sbGllIFNwaWtlIENBMRUwEwYDVQQKDAxDb2xsaWUgU3Bp
    a2UxFzAVBgNVBAsMDsO2cmcgw7xuw69jb2RlMB4XDTI2MTAzMDAzNDU1OFoXDTI2
    MTEyOTAzNDU1OFowSjEYMBYGA1UEAwwPQ29sbGllIFNwaWtlIENBMRUwEwYDVQQK
    DAxDb2xsaWUgU3Bpa2UxFzAVBgNVBAsMDsO2cmcgw7xuw69jb2RlMFkwEwYHKoZI
    zj0CAQYIKoZIzj0DAQcDQgAEwEPBdiAbnZvNje14d1PKMI4y3cXEimXPAfMpdIu9
    Rhg94WdHQx+MKAFA8To4GIjqtPP/OcK5z8S+kOq8Z5kFE6NTMFEwHQYDVR0OBBYE
    FFQQCEvG93If3QS5BoflSfZGgBLGMB8GA1UdIwQYMBaAFFQQCEvG93If3QS5Bofl
    SfZGgBLGMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAIcoTPfF
    2uXG88IVe8WaWOhs1kujG3oXxmX5xQMcsZlvAiAx/qqVgWTeWCLy6WCHGNlvBXHE
    sp6aphVlun41fmzgnQ==
    -----END CERTIFICATE-----
    """

// openssl x509 -subject_hash_old → c1fbc18e (serial -12345: swift-certificates refuses to parse it)
private let negativeSerialCA = """
    -----BEGIN CERTIFICATE-----
    MIIBkTCCATegAwIBAgICz8cwCgYIKoZIzj0EAwIwQDELMAkGA1UEBhMCQlIxFDAS
    BgNVBAoMC0NvbGxpZSBUZXN0MRswGQYDVQQDDBJ2MSBuZWdhdGl2ZSBzZXJpYWww
    HhcNMjYxMDMwMDQwODQxWhcNMzYxMDI3MDQwODQxWjBAMQswCQYDVQQGEwJCUjEU
    MBIGA1UECgwLQ29sbGllIFRlc3QxGzAZBgNVBAMMEnYxIG5lZ2F0aXZlIHNlcmlh
    bDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABDFGgHbV2RG3vTQwJeIls8SLc3S9
    9r9Qe9ak5fxwECA/D3IM8waUCNWadPxp8Gw1d88jzHYY8mtgpCfDCFOEcfGjITAf
    MB0GA1UdDgQWBBQh0wTVAZq2zuI3xK0KWOFkgjq/7DAKBggqhkjOPQQDAgNIADBF
    AiAsL28SpiSwYKVKcc3luYbbQlv3w9Iw439QtR/kanNwNwIhAOWsDKd8beJKtPtz
    UMFoKAsZd4xYt0381GiA9syeReIA
    -----END CERTIFICATE-----
    """

/// Serialized: its device end-to-end tests (here and `DaemonE2E`, nested) share one emulator.
@Suite(.serialized) struct NetworkSetupTests {
    @Test func subjectHashMatchesOpenSSL() {
        #expect(SubjectHash.old(pem: utf8CA) == "d6849034")
        #expect(SubjectHash.old(pem: negativeSerialCA) == "c1fbc18e")
        // Android's cacerts files wrap the PEM in `openssl x509 -text` output
        #expect(SubjectHash.old(pem: "Certificate:\n    Data: …\n" + negativeSerialCA + "\nSHA1 Fingerprint=…\n") == "c1fbc18e")
        #expect(SubjectHash.old(pem: "not a cert") == nil)
        #expect(SubjectHash.subject(der: [0x30, 0x82, 0xff, 0xff]) == nil)   // length past the end
    }

    @Test func zygoteTargetsAreZygotesAndTheirChildren() {
        let ps = """
            PID  PPID NAME
              1     0 init
            436     1 zygote64
            437     1 zygote
            900   436 com.android.chrome
            901   437 com.example.app32
            950   436 webview_zygote
            951   950 com.android.chrome:sandboxed_process0
            980   900 child_of_an_app
            """
        #expect(NetShell.zygoteTargets(ps).sorted() == [436, 437, 900, 901, 950, 951])
    }

    @Test func probeParsesWithAndWithoutState() {
        let fresh = NetShell.parseProbe("uid: 2000\nsdk: 37\nproxy: null\nhash: \nport: \nprevious: \nlayer: 0\napex: 1\n")
        #expect(fresh == .init(uid: 2000, sdk: 37, proxy: "null", hash: nil, port: nil, previous: nil, layer: false, apex: true))
        let attached = NetShell.parseProbe("uid: 0\r\nsdk: 33\r\nproxy: 127.0.0.1:8899\r\nhash: c8750f0d\r\nport: 8899\r\nprevious: 192.168.1.2:9090\r\nuserAdded: c8750f0d.1\r\nlayer: 1\r\napex: 0\r\n")
        #expect(attached == .init(uid: 0, sdk: 33, proxy: "127.0.0.1:8899", hash: "c8750f0d", port: 8899, previous: "192.168.1.2:9090",
                                   userAdded: "c8750f0d.1", layer: true, apex: false))
    }

    @Test func injectCommandsTargetOurLayerOnly() {
        let sys = NetShell.systemInject(hash: "c8750f0d", file: "c8750f0d.1")
        #expect(sys.contains("grep -q '^collie-ca /system/etc/security/cacerts ' /proc/mounts"))   // idempotent: present → no second mount
        #expect(sys.contains("mount -t tmpfs -o mode=755 collie-ca /system/etc/security/cacerts"))
        #expect(sys.contains("[ -d /apex/com.android.conscrypt/cacerts ] && src=/apex/com.android.conscrypt/cacerts"))
        #expect(sys.contains("cp /data/local/tmp/collie-ca/c8750f0d.0 /data/local/tmp/collie-ca/all/c8750f0d.1"))
        #expect(sys.contains("echo c8750f0d.1 > /data/local/tmp/collie-ca/sys-file"))
        #expect(sys.contains("chcon u:object_r:system_file:s0"))
        let user = NetShell.userInject(hash: "c8750f0d", file: "c8750f0d.2")
        #expect(user.contains("cp /data/local/tmp/collie-ca/c8750f0d.0 /data/misc/user/0/cacerts-added/c8750f0d.2"))
        #expect(user.contains("echo c8750f0d.2 > /data/local/tmp/collie-ca/user-added"))
        #expect(NetShell.eject.contains("rm -f /data/misc/user/0/cacerts-added/$(cat /data/local/tmp/collie-ca/user-added);"))
    }

    @Test func apexCommandsLoopOverPids() {
        #expect(NetShell.apexBind(pids: []) == "true")
        let bind = NetShell.apexBind(pids: [436, 900])
        #expect(bind.hasPrefix("for p in 436 900; do"))
        #expect(bind.contains("grep -q '^collie-ca /apex/com.android.conscrypt/cacerts ' /proc/$p/mounts"))
        #expect(bind.contains("nsenter --mount=/proc/$p/ns/mnt -- mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts"))
        #expect(NetShell.apexUnbind(pids: [436]).contains("nsenter --mount=/proc/$p/ns/mnt -- umount /apex/com.android.conscrypt/cacerts"))
        #expect(NetShell.counts("436 bound\n900 already\n901 gone\n902 bound\n") == ["bound": 2, "already": 1, "gone": 1])
    }

    @Test func proxyValuesAndQuoting() {
        #expect(NetShell.proxy(8899) == "127.0.0.1:8899")
        #expect(NetShell.restoreValue(nil) == ":0" && NetShell.restoreValue("") == ":0" && NetShell.restoreValue("null") == ":0")
        #expect(NetShell.restoreValue("192.168.18.198:9090") == "192.168.18.198:9090")
        #expect(NetShell.shq("a'b") == "'a'\\''b'")
        #expect(NetShell.savePrevious("x';reboot;'") == "echo 'x'\\'';reboot;'\\''' > /data/local/tmp/collie-ca/prev-proxy")
        #expect(NetShell.mark(hash: "c8750f0d", port: 51234) == "echo c8750f0d > /data/local/tmp/collie-ca/hash; echo 51234 > /data/local/tmp/collie-ca/port")
    }

    @Test func reverseListAndValues() {
        #expect(NetShell.hasReverse("host-19 tcp:8899 tcp:8899\n", port: 8899))
        #expect(!NetShell.hasReverse("host-19 tcp:18899 tcp:18899\n", port: 8899))
        #expect(!NetShell.hasReverse("", port: 8899))
        #expect(NetShell.value("system", in: "system: mounted 146 CAs\n") == "mounted 146 CAs")
        #expect(NetShell.value("user", in: "system: present\n") == nil)
    }

    @Test func listingParses() {
        let out = "ours aaa\nsystem c8750f0d.0 bbb\nsystem c8750f0d.1 aaa\nuser c8750f0d.0 ccc\ngarbage\n"
        #expect(NetShell.parseListing(out) == .init(ours: "aaa", system: ["c8750f0d.0": "bbb", "c8750f0d.1": "aaa"], user: ["c8750f0d.0": "ccc"]))
        #expect(NetShell.parseListing("") == .init(ours: nil))
        #expect(NetShell.listing(hash: "c8750f0d").contains("for f in /data/misc/user/0/cacerts-added/c8750f0d.*"))
    }

    /// Every mitmproxy CA has the subject "CN=mitmproxy, O=mitmproxy", so `c8750f0d.0` may hold someone else's.
    @Test func slotSkipsAnotherCAWithTheSameHash() {
        #expect(NetShell.slot(hash: "c8750f0d", ours: "aaa", existing: [:]) == ("c8750f0d.0", false))
        #expect(NetShell.slot(hash: "c8750f0d", ours: "aaa", existing: ["c8750f0d.0": "bbb"]) == ("c8750f0d.1", false))
        #expect(NetShell.slot(hash: "c8750f0d", ours: "aaa", existing: ["c8750f0d.0": "bbb", "c8750f0d.1": "ccc", "c8750f0d.3": "ddd"]) == ("c8750f0d.2", false))
        #expect(NetShell.slot(hash: "c8750f0d", ours: "aaa", existing: ["c8750f0d.0": "bbb", "c8750f0d.1": "aaa"]) == ("c8750f0d.1", true))
    }

    @Test func userPlanLeavesOtherCAsAlone() {
        // none there: a new file
        #expect(NetShell.userPlan(hash: "h", ours: "aaa", existing: [:], added: nil) == .write("h.0", replacing: false))
        // the user's own mitmproxy CA holds h.0: ours goes next to it
        #expect(NetShell.userPlan(hash: "h", ours: "aaa", existing: ["h.0": "bbb"], added: nil) == .write("h.1", replacing: false))
        // ours, written by us: present; the same CA installed by the user: left alone (and never removed by eject)
        #expect(NetShell.userPlan(hash: "h", ours: "aaa", existing: ["h.0": "bbb", "h.1": "aaa"], added: "h.1") == .present("h.1"))
        #expect(NetShell.userPlan(hash: "h", ours: "aaa", existing: ["h.0": "aaa"], added: nil) == .preexisting("h.0"))
        // the file we wrote before holds our previous CA (rotated): replaced in place
        #expect(NetShell.userPlan(hash: "h", ours: "aaa", existing: ["h.0": "bbb", "h.1": "old"], added: "h.1") == .write("h.1", replacing: true))
    }

    @Test func emulatorsOnly() {
        #expect(throws: ProtocolError.self) { try DeviceNetworkSetup.guardEmulator("R58N12ABCDE") }
        #expect(throws: Never.self) { try DeviceNetworkSetup.guardEmulator("emulator-5560") }
    }

    /// Against a real rootable emulator: `COLLIE_E2E_SERIAL=emulator-5560 COLLIE_E2E_CA=<mitmproxy-ca-cert.pem> swift test --filter NetworkSetupTests`.
    /// Attaches twice (idempotent), checks the device, detaches twice; leaves the device as it found it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLIE_E2E_SERIAL"] != nil))
    func endToEndOnEmulator() async throws {
        let env = ProcessInfo.processInfo.environment, serial = env["COLLIE_E2E_SERIAL"]!
        let ca = URL(fileURLWithPath: env["COLLIE_E2E_CA"] ?? "")
        let adb = try #require(Adb.locate(env: env, home: NSHomeDirectory()))
        let setup = DeviceNetworkSetup(adb: Adb(url: adb)), port = 18899
        let before = try await setup.probe(serial)
        let first = try await setup.attach(serial: serial, port: port, caCert: ca)
        #expect(first.system.hasPrefix("mounted") || first.system == "present")
        let second = try await setup.attach(serial: serial, port: port, caCert: ca)
        #expect(second.system == "present" && second.apexBound == 0 && second.user != "added")
        #expect(second.previousProxy == first.previousProxy)
        let on = try await setup.probe(serial)
        #expect(on.proxy == "127.0.0.1:\(port)" && on.layer && on.port == port)
        #expect(try await setup.reconcile(serial: serial, activePort: port, caCert: ca) == .none)
        _ = try await Adb(url: adb).run(["reverse", "--remove", "tcp:\(port)"], serial: serial, timeout: .seconds(10))
        #expect(try await setup.reconcile(serial: serial, activePort: port, caCert: ca) == .reverseRestored)
        // daemon "restarted" without the session: the orphan is cleaned up
        #expect(try await setup.reconcile(serial: serial, activePort: nil, caCert: nil) == .detached)
        let off = try await setup.probe(serial)
        #expect(!off.layer && off.hash == nil && off.proxy == NetShell.restoreValue(before.proxy == "null" ? nil : before.proxy))
        let again = try await setup.detach(serial: serial, port: port)
        #expect(again.contains("ca: absent"))
        #expect(try await setup.reconcile(serial: serial, activePort: nil, caCert: nil) == .none)
    }

    /// The reboot case (`COLLIE_E2E_REBOOT=1` as well): the user-store CA and the staging dir survive (the proxy setting
    /// too, once written to disk); the tmpfs, the binds, root and the reverse do not. A live session re-attaches;
    /// without one the leftovers are cleaned.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLIE_E2E_SERIAL"] != nil && ProcessInfo.processInfo.environment["COLLIE_E2E_REBOOT"] != nil))
    func rebootIsReconciled() async throws {
        let env = ProcessInfo.processInfo.environment, serial = env["COLLIE_E2E_SERIAL"]!
        let ca = URL(fileURLWithPath: env["COLLIE_E2E_CA"] ?? "")
        let adb = Adb(url: try #require(Adb.locate(env: env, home: NSHomeDirectory())))
        let setup = DeviceNetworkSetup(adb: adb), port = 18899
        func booted() async -> Bool {
            (try? await adb.run(["shell", "getprop sys.boot_completed"], serial: serial, timeout: .seconds(10)))?.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        func reboot() async throws {
            _ = try await adb.run(["reboot"], serial: serial, timeout: .seconds(30))
            for _ in 0..<60 where await booted() { try await Task.sleep(for: .milliseconds(500)) }   // `adb reboot` returns before it goes down
            for _ in 0..<90 where !(await booted()) { try await Task.sleep(for: .seconds(2)) }
        }
        _ = try await setup.attach(serial: serial, port: port, caCert: ca)
        try await reboot()
        let after = try await setup.probe(serial)
        // the proxy setting usually survives, but not when the reboot beats its write to disk: either way reconcile re-attaches
        #expect(["127.0.0.1:\(port)", ":0"].contains(after.proxy), "\(after)")
        #expect(!after.layer && after.hash != nil, "\(after)")
        #expect(try await setup.reconcile(serial: serial, activePort: port, caCert: ca) == .reattached)
        #expect(try await setup.probe(serial).layer)
        try await reboot()
        #expect(try await setup.reconcile(serial: serial, activePort: nil, caCert: nil) == .detached)
        let clean = try await setup.probe(serial)
        #expect(!clean.layer && clean.hash == nil && clean.proxy == ":0")
        let userStore = try await adb.run(["shell", "ls \(NetShell.user) 2>/dev/null | wc -l"], serial: serial, timeout: .seconds(10)).stdout
        #expect(userStore.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}
