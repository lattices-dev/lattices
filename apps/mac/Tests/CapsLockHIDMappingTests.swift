import XCTest
@testable import Lattices

final class CapsLockHIDMappingTests: XCTestCase {
    func testStaleOtherServiceCannotProveReconnectedKeyboardIsMapped() {
        let mapped = """
        RegistryID  Key Value
        100000001 UserKeyMapping (
          { HIDKeyboardModifierMappingDst = 30064771181; HIDKeyboardModifierMappingSrc = 30064771129; }
        )
        """
        XCTAssertEqual(CapsLockHIDMapping.parse(mapped, registryID: 0x100000001), [.init(src: 30064771129, dst: 30064771181)])
        XCTAssertNil(CapsLockHIDMapping.parse(mapped, registryID: 0x100000002))
        let newKeyboard = "RegistryID Key Value\n100000002 UserKeyMapping (null)\n"
        let current = CapsLockHIDMapping.parse(newKeyboard, registryID: 0x100000002)
        XCTAssertEqual(current, [])
        XCTAssertEqual(current.flatMap(CapsLockHIDMapping.enabling), [CapsLockHIDMapping.transport])
        XCTAssertNil(CapsLockHIDMapping.parse(mapped + "\n" + newKeyboard, registryID: 0x100000002))
    }

    func testDoesNotReplaceExistingCapsMappingOrDuplicateTransport() {
        let existing = HIDKeyboardModifierMapping(src: CapsLockHIDMapping.caps, dst: 123)
        XCTAssertNil(CapsLockHIDMapping.enabling([existing]))
        XCTAssertEqual(CapsLockHIDMapping.enabling([CapsLockHIDMapping.transport]), [CapsLockHIDMapping.transport])
    }

    func testEnableAndDisablePreserveUnrelatedAndLaterMappings() {
        let original = HIDKeyboardModifierMapping(src: 10, dst: 20)
        let later = HIDKeyboardModifierMapping(src: 30, dst: 40)
        let enabled = CapsLockHIDMapping.enabling([original])!
        XCTAssertEqual(enabled, [original, CapsLockHIDMapping.transport])
        XCTAssertEqual(CapsLockHIDMapping.restoring(enabled + [later]), [original, later])
        let changedCaps = HIDKeyboardModifierMapping(src: CapsLockHIDMapping.caps, dst: 456)
        XCTAssertEqual(CapsLockHIDMapping.restoring([original, changedCaps]), [original, changedCaps])
    }

    func testUnreadableOutputIsNotTreatedAsEmpty() {
        for output in ["", "hidutil failed", "100000001 UserKeyMapping (broken)",
                       "100000001 UserKeyMapping ({ HIDKeyboardModifierMappingSrc = 3; })"] {
            XCTAssertNil(CapsLockHIDMapping.parse(output, registryID: 0x100000001))
        }
        XCTAssertEqual(CapsLockHIDMapping.parse("100000001 UserKeyMapping ()", registryID: 0x100000001), [])
    }
}
