import Foundation

enum PedroMeetingLink {
    static func resolve(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first(where: isMeeting)
    }
    static func isMeeting(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        let path = url.path.lowercased()
        if host == "meet.google.com" { return path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com") {
            return path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/")
        }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") {
            return path.contains("/meet/") || path.contains("/join/") || path.hasSuffix("/j.php")
        }
        return false
    }
    static func status(start: Date, end: Date, now: Date) -> String? {
        guard end > now else { return nil }
        if start <= now { return "Agora" }
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        return minutes <= 60 ? "Em \(minutes) min" : nil
    }
}
