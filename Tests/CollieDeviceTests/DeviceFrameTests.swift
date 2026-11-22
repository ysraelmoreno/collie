import Testing
import Foundation
@testable import CollieDevice

@Suite struct DeviceFrameTests {
    @Test func androidKinds() {
        #expect(DeviceFrame.android(hwDeviceName: "pixel_8", emulator: true) == .phone)
        #expect(DeviceFrame.android(hwDeviceName: "pixel_fold", emulator: true) == .fold)
        #expect(DeviceFrame.android(hwDeviceName: "pixel_tablet", emulator: true) == .tablet)
        #expect(DeviceFrame.android(hwDeviceName: "medium_tablet", emulator: true) == .tablet)
        #expect(DeviceFrame.android(hwDeviceName: "pixel_c", emulator: true) == .tablet)
        #expect(DeviceFrame.android(hwDeviceName: nil, emulator: true) == .phone)
        #expect(DeviceFrame.android(hwDeviceName: "pixel_8", emulator: false) == .bare)
        #expect(DeviceFrame.android(hwDeviceName: nil, emulator: false) == .bare)
    }

    @Test func iosKinds() {
        let p = "com.apple.CoreSimulator.SimDeviceType."
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "iPad-Air-13-inch-M2") == .ipad)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "iPhone-SE-3rd-generation") == .classic)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "iPhone-8-Plus") == .classic)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "iPhone-6s") == .classic)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "iPhone-16-Pro") == .island)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "iPhone-16e") == .island)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: p + "Apple-Watch-Series-10-46mm") == .bare)
        #expect(DeviceFrame.ios(deviceTypeIdentifier: nil) == .bare)
    }

    @Test func configIniDeviceName() {
        #expect(DeviceFrame.hwDeviceName(configIni: "avd.ini.encoding=UTF-8\nhw.device.name = pixel_fold\nhw.lcd.width=1080\n") == "pixel_fold")
        #expect(DeviceFrame.hwDeviceName(configIni: "hw.device.name=\n") == nil)
        #expect(DeviceFrame.hwDeviceName(configIni: "") == nil)
    }
}
