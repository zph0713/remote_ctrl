import Foundation

public enum HIDReportParser {
    /// RC003 keyboard reports use report ID 1 and contain pairs of
    /// little-endian usages (up to three concurrent keys).
    ///
    /// Some delivery paths include the report ID as the first byte, some do not.
    public static func usages(reportID: UInt32, bytes: [UInt8]) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }
        var data = bytes
        if data.count == 7, data.first == UInt8(reportID) {
            data.removeFirst()
        }
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }

        var result = Set<UInt16>()
        for index in stride(from: 0, to: data.count, by: 2) {
            let usage = UInt16(data[index]) | UInt16(data[index + 1]) << 8
            if usage != 0 {
                result.insert(usage)
            }
        }
        return result
    }
}
