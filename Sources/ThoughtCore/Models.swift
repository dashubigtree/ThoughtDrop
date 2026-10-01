import Foundation
import CryptoKit

public enum ClipStatus: String, Codable { case recording, recorded, transcribed, complete, failed }

public struct Clip: Codable, Identifiable {
    public var id: String
    public var date: Date
    public var day: String
    public var duration: Double
    public var status: ClipStatus
    public var raw: String
    public var corrected: String?
    public var error: String?
    public var text: String { corrected ?? raw }

    public init(date: Date = Date(), calendar: Calendar = .current) {
        id = UUID().uuidString.lowercased()
        self.date = date
        day = Day.key(date, calendar: calendar)
        duration = 0
        status = .recording
        raw = ""
    }
}

public enum Day {
    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func isDue(_ day: String, now: Date, calendar: Calendar = .current) -> Bool {
        let today = key(now, calendar: calendar)
        return day < today || (day == today && calendar.component(.hour, from: now) >= 17)
    }

    public static func fingerprint(_ clips: [Clip]) -> String {
        digest(clips.sorted { $0.id < $1.id }.map {
            "\($0.id)|\($0.status.rawValue)|\($0.text)"
        }.joined(separator: "\n"))
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct WikiNote: Codable {
    public let title: String
    public let kind: String
    public let content: String
    public let sources: [String]
    public init(title: String, kind: String, content: String, sources: [String]) {
        self.title = title; self.kind = kind; self.content = content; self.sources = sources
    }
}

public struct DailyReport: Codable {
    public let review: String
    public let tomorrow: String
    public let notes: [WikiNote]
    public init(review: String, tomorrow: String, notes: [WikiNote]) {
        self.review = review; self.tomorrow = tomorrow; self.notes = notes
    }
}

public struct SavedReport: Codable {
    public let day: String
    public let revision: String
    public let generatedAt: Date
    public let report: DailyReport
    public let clips: [Clip]
}

public enum ThoughtError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
