import Foundation

/// Lê fontes (repositórios) nos formatos AltStore (v1/v2), ESign, Scarlet e Legado.
struct SourceService {

    enum SourceError: LocalizedError {
        case network, decode
        var errorDescription: String? {
            switch self {
            case .network: return L.tr("source.error.network")
            case .decode:  return L.tr("source.error.decode")
            }
        }
    }

    /// Baixa e interpreta uma fonte a partir da URL.
    func fetch(url: URL, existingID: UUID? = nil) async throws -> (source: Source, apps: [SourceApp]) {
        let data: Data
        do {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            req.setValue("XSign/1.0 (iOS; AltStore/ESign Compatible)", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SourceError.network
            }
            data = d
        } catch {
            throw SourceError.network
        }

        let sourceID = existingID ?? UUID()
        guard let result = Self.parseAnyRepo(data: data, url: url, sourceID: sourceID) else {
            throw SourceError.decode
        }
        return result
    }

    // MARK: - Parser Universal (AltStore v1/v2, ESign, Scarlet, Feather, JSON Array)

    private static func parseAnyRepo(data: Data, url: URL, sourceID: UUID) -> (Source, [SourceApp])? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }

        if let dict = raw as? [String: Any] {
            let repoName = (dict["name"] as? String)
                ?? ((dict["META"] as? [String: Any])?["repoName"] as? String)
                ?? ((dict["META"] as? [String: Any])?["name"] as? String)
                ?? url.host
                ?? "Source"

            let subtitle = (dict["subtitle"] as? String) ?? (dict["description"] as? String)
            let repoIcon = parseURL(dict["iconURL"] ?? dict["icon"] ?? (dict["META"] as? [String: Any])?["icon"])

            var format: SourceFormat = .altstore
            var rawApps: [[String: Any]] = []

            if let apps = dict["apps"] as? [[String: Any]] {
                rawApps = apps
                format = .altstore
            } else if dict["META"] != nil {
                format = .scarlet
                for (key, value) in dict where key != "META" {
                    if let arr = value as? [[String: Any]] {
                        rawApps.append(contentsOf: arr)
                    }
                }
            } else if let dataArr = dict["data"] as? [[String: Any]] {
                format = .legacy
                rawApps = dataArr
            }

            let parsedApps = rawApps.compactMap { parseAppDict($0, sourceID: sourceID, sourceName: repoName) }
            guard !parsedApps.isEmpty || dict["apps"] != nil else { return nil }

            let source = Source(
                id: sourceID,
                url: url,
                name: repoName,
                subtitle: subtitle,
                iconURL: repoIcon,
                format: format,
                lastFetched: Date(),
                lastError: nil,
                order: 0,
                appCount: parsedApps.count
            )
            return (source, parsedApps)
        } else if let array = raw as? [[String: Any]] {
            let repoName = url.host ?? "Source"
            let parsedApps = array.compactMap { parseAppDict($0, sourceID: sourceID, sourceName: repoName) }
            guard !parsedApps.isEmpty else { return nil }
            let source = Source(
                id: sourceID,
                url: url,
                name: repoName,
                format: .legacy,
                lastFetched: Date(),
                order: 0,
                appCount: parsedApps.count
            )
            return (source, parsedApps)
        }

        return nil
    }

    private static func parseAppDict(_ d: [String: Any], sourceID: UUID, sourceName: String) -> SourceApp? {
        guard let name = (d["name"] as? String) ?? (d["appName"] as? String),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        let bundleID = (d["bundleIdentifier"] as? String)
            ?? (d["bundleID"] as? String)
            ?? (d["bundleId"] as? String)
            ?? "com.repo.\(name.lowercased().replacingOccurrences(of: " ", with: ""))"

        let developer = (d["developerName"] as? String)
            ?? (d["developer"] as? String)
            ?? (d["author"] as? String)

        let subtitle = (d["subtitle"] as? String) ?? (d["localizedDescription"] as? String)
        let iconURL = parseURL(d["iconURL"] ?? d["icon"] ?? d["image"])

        var versions: [AppVersion] = []
        if let rawVersions = d["versions"] as? [[String: Any]], !rawVersions.isEmpty {
            versions = rawVersions.compactMap { v in
                guard let dl = parseURL(v["downloadURL"] ?? v["down"] ?? v["url"]) else { return nil }
                let ver = String(describing: v["version"] ?? d["version"] ?? "1.0")
                let size = parseSize(v["size"] ?? d["size"])
                let date = parseDate(v["date"] ?? v["versionDate"] ?? d["versionDate"])
                let notes = (v["localizedDescription"] as? String) ?? (v["notes"] as? String) ?? (d["localizedDescription"] as? String)
                let sha = v["sha256"] as? String
                return AppVersion(version: ver, downloadURL: dl, size: size, date: date, notes: notes, sha256: sha)
            }
        }

        if versions.isEmpty, let dl = parseURL(d["downloadURL"] ?? d["down"] ?? d["url"]) {
            let ver = String(describing: d["version"] ?? "1.0")
            let size = parseSize(d["size"])
            let date = parseDate(d["versionDate"] ?? d["date"] ?? d["fullDate"])
            let notes = (d["localizedDescription"] as? String) ?? (d["description"] as? String)
            versions = [AppVersion(version: ver, downloadURL: dl, size: size, date: date, notes: notes)]
        }

        guard !versions.isEmpty else { return nil }

        return SourceApp(
            name: name,
            bundleID: bundleID,
            developer: developer,
            subtitle: subtitle,
            category: d["category"] as? String,
            iconURL: iconURL,
            sourceID: sourceID,
            sourceName: sourceName,
            versions: versions
        )
    }

    private static func parseURL(_ raw: Any?) -> URL? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed) { return u }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded)
        }
        return nil
    }

    private static func parseSize(_ raw: Any?) -> Int64? {
        if let i = raw as? Int64 { return i }
        if let i = raw as? Int { return Int64(i) }
        if let d = raw as? Double { return Int64(d) }
        if let s = raw as? String {
            let digits = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Int64(digits) { return v }
        }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let t = raw as? TimeInterval {
            return t > 10_000_000_000 ? Date(timeIntervalSince1970: t / 1000) : Date(timeIntervalSince1970: t)
        }
        guard let str = raw as? String, !str.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: str) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "dd/MM/yyyy", "MM/dd/yyyy"] {
            df.dateFormat = fmt
            if let d = df.date(from: str) { return d }
        }
        return nil
    }
}
