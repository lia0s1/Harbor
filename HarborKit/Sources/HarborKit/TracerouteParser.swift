import Foundation

/// One hop from `traceroute -n`: the hop number, the first responding address
/// ("" when every probe timed out — the `* * *` line) and each probe's RTT in
/// milliseconds.
public struct TracerouteHop: Equatable, Sendable, Identifiable {
    public let number: Int
    public let address: String
    public let rttMs: [Double]

    public init(number: Int, address: String, rttMs: [Double]) {
        self.number = number
        self.address = address
        self.rttMs = rttMs
    }

    public var id: Int { number }
    /// True when no probe answered (`*`-only line).
    public var isLoss: Bool { rttMs.isEmpty }
    /// Best (minimum) RTT of the hop's probes, for compact display.
    public var bestRttMs: Double? { rttMs.min() }
}

/// Pure parser for macOS (`/usr/sbin/traceroute -n -q 1 -w 2`) hop lines.
/// Fed line-by-line by TracerouteService as the process streams output.
///
/// Line shapes handled:
///   ` 2  10.0.0.1  5.123 ms`                    (one probe, -q 1)
///   ` 2  10.0.0.1  2.1 ms  2.4 ms  2.3 ms`      (three probes)
///   ` 5  1.2.3.4  10 ms  5.6.7.8  11 ms`        (different responders)
///   ` 3  *` / ` 3  * * *`                       (all lost)
///   ` 4  172.16.0.1  20.5 ms !H`                (reachability annotation)
/// Header ("traceroute to …"), blank and garbage lines return nil.
public enum TracerouteParser {
    /// Parses one line of traceroute output; nil when the line is not a hop.
    public static func parseLine(_ line: String) -> TracerouteHop? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first, let number = Int(first), number > 0 else { return nil }
        var address = ""
        var rtts: [Double] = []
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "*" {
                index += 1
                continue
            }
            // "<addr> <rtt> ms": the address token is followed by a numeric
            // rtt and an "ms" unit (which may carry a trailing "!H"/"!N").
            if index + 2 < tokens.count,
               let rtt = Double(tokens[index + 1]), rtt.isFinite,
               tokens[index + 2].hasPrefix("ms") {
                if address.isEmpty { address = token }
                rtts.append(rtt)
                index += 3
                continue
            }
            // Additional probe of the same hop: bare "<rtt> ms".
            if index + 1 < tokens.count,
               let rtt = Double(token), rtt.isFinite,
               tokens[index + 1].hasPrefix("ms") {
                rtts.append(rtt)
                index += 2
                continue
            }
            index += 1
        }
        return TracerouteHop(number: number, address: address, rttMs: rtts)
    }

    /// Whole-text variant (tests, one-shot callers): every hop line in order.
    public static func parse(_ text: String) -> [TracerouteHop] {
        text.split(separator: "\n").compactMap { parseLine(String($0)) }
    }
}
