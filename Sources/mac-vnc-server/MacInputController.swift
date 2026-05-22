import ApplicationServices
import CoreGraphics
import Foundation

final class MacInputController: InputController {
    private var lastButtonMask: UInt8 = 0
    private var modifierFlags: CGEventFlags = []

    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        let point = layout.globalPoint(framebufferX: Int(x), framebufferY: Int(y))

        if buttonMask & 0b00001000 != 0 {
            postScroll(deltaY: 4)
        }
        if buttonMask & 0b00010000 != 0 {
            postScroll(deltaY: -4)
        }

        postButtonIfChanged(mask: buttonMask, bit: 0, button: .left, downType: .leftMouseDown, upType: .leftMouseUp, point: point)
        postButtonIfChanged(mask: buttonMask, bit: 1, button: .center, downType: .otherMouseDown, upType: .otherMouseUp, point: point)
        postButtonIfChanged(mask: buttonMask, bit: 2, button: .right, downType: .rightMouseDown, upType: .rightMouseUp, point: point)

        let type: CGEventType = (buttonMask & 0b00000111) == 0 ? .mouseMoved : .leftMouseDragged
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        lastButtonMask = buttonMask
    }

    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        if let modifier = KeySymMapper.modifier(for: keysym, mapAltToCommand: mapAltToCommand) {
            updateModifier(modifier.flag, down: down)
            postKeyCode(modifier.keyCode, down: down, flags: modifierFlags)
            return
        }

        if let mapped = KeySymMapper.keyStroke(for: keysym) {
            var flags = modifierFlags
            if mapped.needsShift {
                flags.insert(.maskShift)
            }
            postKeyCode(mapped.keyCode, down: down, flags: flags)
            return
        }

        guard down, let scalar = UnicodeScalar(keysym), !isControlScalar(scalar) else {
            return
        }

        var chars = [UniChar(scalar.value)]
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        event?.flags = modifierFlags
        event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        event?.post(tap: .cghidEventTap)
    }

    private func updateModifier(_ flag: CGEventFlags, down: Bool) {
        if down {
            modifierFlags.insert(flag)
        } else {
            modifierFlags.remove(flag)
        }
    }

    private func postKeyCode(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func postButtonIfChanged(
        mask: UInt8,
        bit: UInt8,
        button: CGMouseButton,
        downType: CGEventType,
        upType: CGEventType,
        point: CGPoint
    ) {
        let flag: UInt8 = 1 << bit
        let wasDown = lastButtonMask & flag != 0
        let isDown = mask & flag != 0
        guard wasDown != isDown else {
            return
        }

        let type = isDown ? downType : upType
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func postScroll(deltaY: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func isControlScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7f
    }
}

enum KeySymMapper {
    struct Modifier {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    struct KeyStroke {
        let keyCode: CGKeyCode
        let needsShift: Bool
    }

    static func modifier(for keysym: UInt32, mapAltToCommand: Bool = false) -> Modifier? {
        if mapAltToCommand, let modifier = appleScreenSharingModifiers[keysym] {
            return modifier
        }
        return modifiers[keysym]
    }

    static func keyStroke(for keysym: UInt32) -> KeyStroke? {
        if let special = specialKeys[keysym] {
            return special
        }
        if let scalar = UnicodeScalar(keysym) {
            return printable[String(scalar)]
        }
        return nil
    }

    static func keyCode(for keysym: UInt32) -> CGKeyCode? {
        keyStroke(for: keysym)?.keyCode ?? modifier(for: keysym)?.keyCode
    }

    private static let modifiers: [UInt32: Modifier] = [
        0xffe1: Modifier(keyCode: 56, flag: .maskShift),
        0xffe2: Modifier(keyCode: 60, flag: .maskShift),
        0xffe3: Modifier(keyCode: 59, flag: .maskControl),
        0xffe4: Modifier(keyCode: 62, flag: .maskControl),
        0xffe7: Modifier(keyCode: 55, flag: .maskCommand),
        0xffe8: Modifier(keyCode: 54, flag: .maskCommand),
        0xffe9: Modifier(keyCode: 58, flag: .maskAlternate),
        0xffea: Modifier(keyCode: 61, flag: .maskAlternate)
    ]

    private static let appleScreenSharingModifiers: [UInt32: Modifier] = [
        0xffe1: Modifier(keyCode: 56, flag: .maskShift),
        0xffe2: Modifier(keyCode: 60, flag: .maskShift),
        0xffe3: Modifier(keyCode: 59, flag: .maskControl),
        0xffe4: Modifier(keyCode: 62, flag: .maskControl),
        0xffe7: Modifier(keyCode: 58, flag: .maskAlternate),
        0xffe8: Modifier(keyCode: 61, flag: .maskAlternate),
        0xffe9: Modifier(keyCode: 55, flag: .maskCommand),
        0xffea: Modifier(keyCode: 54, flag: .maskCommand)
    ]

    private static let specialKeys: [UInt32: KeyStroke] = [
        0xff08: KeyStroke(keyCode: 51, needsShift: false),
        0xff09: KeyStroke(keyCode: 48, needsShift: false),
        0xff0d: KeyStroke(keyCode: 36, needsShift: false),
        0xff1b: KeyStroke(keyCode: 53, needsShift: false),
        0xffff: KeyStroke(keyCode: 117, needsShift: false),
        0xff50: KeyStroke(keyCode: 115, needsShift: false),
        0xff51: KeyStroke(keyCode: 123, needsShift: false),
        0xff52: KeyStroke(keyCode: 126, needsShift: false),
        0xff53: KeyStroke(keyCode: 124, needsShift: false),
        0xff54: KeyStroke(keyCode: 125, needsShift: false),
        0xff55: KeyStroke(keyCode: 116, needsShift: false),
        0xff56: KeyStroke(keyCode: 121, needsShift: false),
        0xff57: KeyStroke(keyCode: 119, needsShift: false),
        0xffbe: KeyStroke(keyCode: 122, needsShift: false),
        0xffbf: KeyStroke(keyCode: 120, needsShift: false),
        0xffc0: KeyStroke(keyCode: 99, needsShift: false),
        0xffc1: KeyStroke(keyCode: 118, needsShift: false),
        0xffc2: KeyStroke(keyCode: 96, needsShift: false),
        0xffc3: KeyStroke(keyCode: 97, needsShift: false),
        0xffc4: KeyStroke(keyCode: 98, needsShift: false),
        0xffc5: KeyStroke(keyCode: 100, needsShift: false),
        0xffc6: KeyStroke(keyCode: 101, needsShift: false),
        0xffc7: KeyStroke(keyCode: 109, needsShift: false),
        0xffc8: KeyStroke(keyCode: 103, needsShift: false),
        0xffc9: KeyStroke(keyCode: 111, needsShift: false)
    ]

    private static let printable: [String: KeyStroke] = [
        "a": KeyStroke(keyCode: 0, needsShift: false), "A": KeyStroke(keyCode: 0, needsShift: true),
        "s": KeyStroke(keyCode: 1, needsShift: false), "S": KeyStroke(keyCode: 1, needsShift: true),
        "d": KeyStroke(keyCode: 2, needsShift: false), "D": KeyStroke(keyCode: 2, needsShift: true),
        "f": KeyStroke(keyCode: 3, needsShift: false), "F": KeyStroke(keyCode: 3, needsShift: true),
        "h": KeyStroke(keyCode: 4, needsShift: false), "H": KeyStroke(keyCode: 4, needsShift: true),
        "g": KeyStroke(keyCode: 5, needsShift: false), "G": KeyStroke(keyCode: 5, needsShift: true),
        "z": KeyStroke(keyCode: 6, needsShift: false), "Z": KeyStroke(keyCode: 6, needsShift: true),
        "x": KeyStroke(keyCode: 7, needsShift: false), "X": KeyStroke(keyCode: 7, needsShift: true),
        "c": KeyStroke(keyCode: 8, needsShift: false), "C": KeyStroke(keyCode: 8, needsShift: true),
        "v": KeyStroke(keyCode: 9, needsShift: false), "V": KeyStroke(keyCode: 9, needsShift: true),
        "b": KeyStroke(keyCode: 11, needsShift: false), "B": KeyStroke(keyCode: 11, needsShift: true),
        "q": KeyStroke(keyCode: 12, needsShift: false), "Q": KeyStroke(keyCode: 12, needsShift: true),
        "w": KeyStroke(keyCode: 13, needsShift: false), "W": KeyStroke(keyCode: 13, needsShift: true),
        "e": KeyStroke(keyCode: 14, needsShift: false), "E": KeyStroke(keyCode: 14, needsShift: true),
        "r": KeyStroke(keyCode: 15, needsShift: false), "R": KeyStroke(keyCode: 15, needsShift: true),
        "y": KeyStroke(keyCode: 16, needsShift: false), "Y": KeyStroke(keyCode: 16, needsShift: true),
        "t": KeyStroke(keyCode: 17, needsShift: false), "T": KeyStroke(keyCode: 17, needsShift: true),
        "1": KeyStroke(keyCode: 18, needsShift: false), "!": KeyStroke(keyCode: 18, needsShift: true),
        "2": KeyStroke(keyCode: 19, needsShift: false), "@": KeyStroke(keyCode: 19, needsShift: true),
        "3": KeyStroke(keyCode: 20, needsShift: false), "#": KeyStroke(keyCode: 20, needsShift: true),
        "4": KeyStroke(keyCode: 21, needsShift: false), "$": KeyStroke(keyCode: 21, needsShift: true),
        "6": KeyStroke(keyCode: 22, needsShift: false), "^": KeyStroke(keyCode: 22, needsShift: true),
        "5": KeyStroke(keyCode: 23, needsShift: false), "%": KeyStroke(keyCode: 23, needsShift: true),
        "=": KeyStroke(keyCode: 24, needsShift: false), "+": KeyStroke(keyCode: 24, needsShift: true),
        "9": KeyStroke(keyCode: 25, needsShift: false), "(": KeyStroke(keyCode: 25, needsShift: true),
        "7": KeyStroke(keyCode: 26, needsShift: false), "&": KeyStroke(keyCode: 26, needsShift: true),
        "-": KeyStroke(keyCode: 27, needsShift: false), "_": KeyStroke(keyCode: 27, needsShift: true),
        "8": KeyStroke(keyCode: 28, needsShift: false), "*": KeyStroke(keyCode: 28, needsShift: true),
        "0": KeyStroke(keyCode: 29, needsShift: false), ")": KeyStroke(keyCode: 29, needsShift: true),
        "]": KeyStroke(keyCode: 30, needsShift: false), "}": KeyStroke(keyCode: 30, needsShift: true),
        "o": KeyStroke(keyCode: 31, needsShift: false), "O": KeyStroke(keyCode: 31, needsShift: true),
        "u": KeyStroke(keyCode: 32, needsShift: false), "U": KeyStroke(keyCode: 32, needsShift: true),
        "[": KeyStroke(keyCode: 33, needsShift: false), "{": KeyStroke(keyCode: 33, needsShift: true),
        "i": KeyStroke(keyCode: 34, needsShift: false), "I": KeyStroke(keyCode: 34, needsShift: true),
        "p": KeyStroke(keyCode: 35, needsShift: false), "P": KeyStroke(keyCode: 35, needsShift: true),
        "l": KeyStroke(keyCode: 37, needsShift: false), "L": KeyStroke(keyCode: 37, needsShift: true),
        "j": KeyStroke(keyCode: 38, needsShift: false), "J": KeyStroke(keyCode: 38, needsShift: true),
        "'": KeyStroke(keyCode: 39, needsShift: false), "\"": KeyStroke(keyCode: 39, needsShift: true),
        "k": KeyStroke(keyCode: 40, needsShift: false), "K": KeyStroke(keyCode: 40, needsShift: true),
        ";": KeyStroke(keyCode: 41, needsShift: false), ":": KeyStroke(keyCode: 41, needsShift: true),
        "\\": KeyStroke(keyCode: 42, needsShift: false), "|": KeyStroke(keyCode: 42, needsShift: true),
        ",": KeyStroke(keyCode: 43, needsShift: false), "<": KeyStroke(keyCode: 43, needsShift: true),
        "/": KeyStroke(keyCode: 44, needsShift: false), "?": KeyStroke(keyCode: 44, needsShift: true),
        "n": KeyStroke(keyCode: 45, needsShift: false), "N": KeyStroke(keyCode: 45, needsShift: true),
        "m": KeyStroke(keyCode: 46, needsShift: false), "M": KeyStroke(keyCode: 46, needsShift: true),
        ".": KeyStroke(keyCode: 47, needsShift: false), ">": KeyStroke(keyCode: 47, needsShift: true),
        "`": KeyStroke(keyCode: 50, needsShift: false), "~": KeyStroke(keyCode: 50, needsShift: true),
        " ": KeyStroke(keyCode: 49, needsShift: false)
    ]
}
