import CoreGraphics
import Foundation

enum KeyNames {
    static func name(for code: CGKeyCode) -> String {
        switch Int(code) {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 32: return "U"
        case 34: return "I"
        case 31: return "O"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "空格"
        case 51: return "⌫"
        case 53: return "⎋"
        case 55: return "⌘"
        case 56: return "⇧"
        case 57: return "⇪"
        case 58: return "⌥"
        case 59: return "⌃"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "键码 \(code)"
        }
    }

    static func label(keyCode: UInt16, flags: UInt) -> String {
        let eventFlags = CGEventFlags(rawValue: UInt64(flags))
        var text = ""
        if eventFlags.contains(.maskControl) { text += "⌃" }
        if eventFlags.contains(.maskAlternate) { text += "⌥" }
        if eventFlags.contains(.maskShift) { text += "⇧" }
        if eventFlags.contains(.maskCommand) { text += "⌘" }
        if eventFlags.contains(.maskSecondaryFn) { text += "Fn+" }
        text += name(for: CGKeyCode(keyCode))
        return text
    }
}
