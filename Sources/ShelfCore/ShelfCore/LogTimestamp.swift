import Foundation

public enum LogTimestamp {
    public static func parse(_ line:String,timeZone:TimeZone = .current)->Date? {
        guard let regex=try? NSRegularExpression(pattern:#"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"#),
              let match=regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),
              let range=Range(match.range(at:1),in:line) else { return nil }
        let stamp=String(line[range]),formatter=DateFormatter()
        formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=timeZone
        formatter.dateFormat=stamp.contains("T") ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from:stamp)
    }
}
