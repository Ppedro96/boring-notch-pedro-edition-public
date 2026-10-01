import Foundation

enum PedroActivityState: String, Codable {
    case running, waiting, completed, failed, cancelled, unknown

    var title: String {
        switch self {
        case .running: "Em andamento"
        case .waiting: "Precisa de voce"
        case .completed: "Concluido"
        case .failed: "Falhou"
        case .cancelled: "Cancelado"
        case .unknown: "Sem confirmacao"
        }
    }
    var isFinished: Bool { self != .running && self != .waiting }
}

struct PedroActivityEvent: Codable, Equatable, Identifiable {
    let id: String
    var revision: String
    var kind: String
    var title: String
    var detail: String
    var state: PedroActivityState
    var updatedAt: Date
    var progress: Double?
    var url: String?
    var outputPath: String?

    var fingerprint: String { id + ":" + revision }
    var isDot: Bool { kind == "dot" }
    var safeURL: URL? {
        guard let url, let result = URL(string: url),
              let scheme = result.scheme?.lowercased(), ["https", "http"].contains(scheme),
              result.host != nil, result.user == nil, result.password == nil else { return nil }
        return result
    }

    func isValid(now: Date = Date()) -> Bool {
        !id.isEmpty && id.count <= 200 && !revision.isEmpty && revision.count <= 200 &&
        ["dot", "transfer", "job", "download"].contains(kind) &&
        !title.isEmpty && title.count <= 300 && detail.count <= 4000 &&
        updatedAt <= now.addingTimeInterval(300) &&
        now.timeIntervalSince(updatedAt) < 30 * 24 * 3600 &&
        (progress.map { $0.isFinite && (0...100).contains($0) } ?? true)
    }

    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .secondsSince1970
        return value
    }()
}

enum PedroActivityDisk {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pedroops/activity/events", isDirectory: true)
    }

    static func read(directory: URL = directory, now: Date = Date()) -> [PedroActivityEvent] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        return files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 65_536 else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(250).compactMap { url, _ in
            guard let data = try? Data(contentsOf: url), data.count <= 65_536,
                  let event = try? PedroActivityEvent.decoder.decode(PedroActivityEvent.self, from: data),
                  event.isValid(now: now) else { return nil }
            return event
        }
    }
}

struct PedroDownloadReading: Equatable {
    let partial: URL
    let destination: URL
    let bytes: Int64
    let modifiedAt: Date
    var originalDestinationDate: Date?

    var confirmedFinished: Bool {
        guard let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) >= bytes,
              let date = values.contentModificationDate else { return false }
        return originalDestinationDate == nil || date != originalDestinationDate
    }
}

enum PedroDownloadScanner {
    static func scan(directory: URL) -> [PedroDownloadReading] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: .skipsHiddenFiles)) ?? []
        return files.prefix(1000).compactMap { url in
            guard ["crdownload", "part", "download"].contains(url.pathExtension) else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true else { return nil }
            var size = values.isRegularFile == true ? values.fileSize ?? 0 : 0
            var modifiedAt = values.contentModificationDate ?? .distantPast
            if url.pathExtension == "download", values.isDirectory == true {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
                size = children.prefix(20).reduce(0) { total, child in
                    guard child.lastPathComponent != "Info.plist", let value = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                          value.isRegularFile == true, value.isSymbolicLink != true else { return total }
                    modifiedAt = max(modifiedAt, value.contentModificationDate ?? .distantPast)
                    return total + (value.fileSize ?? 0)
                }
            }
            let destination = url.deletingPathExtension()
            return PedroDownloadReading(partial: url, destination: destination, bytes: Int64(size), modifiedAt: modifiedAt,
                originalDestinationDate: (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
    }
}
