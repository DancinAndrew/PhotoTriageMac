import Foundation

public struct OCRLine: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.confidence = confidence; self.x = x; self.y = y
        self.width = width; self.height = height
    }
}

public struct SongEvidence: Codable, Equatable, Sendable {
    public var assetID: String
    public var lineIndices: [Int]
    public var originalText: [String]
    public var parser: String
}

public struct SongCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var confidence: String
    public var needsReview = true
    public var evidence: [SongEvidence]
    public var spotifySearchURL: String {
        Self.searchURL("https://open.spotify.com/search/", title + " " + (artist ?? ""))
    }
    public var youtubeSearchURL: String {
        "https://www.youtube.com/results?search_query=" + Self.encoded(title + " " + (artist ?? ""))
    }
    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    private static func searchURL(_ prefix: String, _ value: String) -> String { prefix + encoded(value) }
}

public struct SongParseResult: Codable, Equatable, Sendable {
    public var candidates: [SongCandidate]
    public var unresolvedLineIndices: [Int]
    public var detectedMusicInterface: Bool
}

public enum SongExtractor {
    private static let exactControls: Set<String> = [
        "shazam", "shazams", "my shazam", "my shazams", "my music", "library", "home", "search", "settings",
        "spotify", "apple music", "youtube music", "我的音樂", "我的音乐", "音樂", "音乐", "資料庫", "資料庫", "返回", "搜尋",
        "播放", "全部", "分享", "探索", "歌曲", "歌手", "取消", "完成", "最近", "歌詞", "歌词", "更多", "推薦",
        "open in spotify", "open in apple music", "listen on spotify", "listen on apple music", "新增至", "加入播放清單",
        "播放清單", "播放列表", "認識這首歌", "识别", "聆聽", "shazam it", "tap to shazam", "auto shazam", "識別記錄"
    ]
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func isControl(_ text: String) -> Bool {
        let value = normalize(text)
        if value.isEmpty || exactControls.contains(value) { return true }
        if value.range(of: "^[0-9:.,%+ /-]+$", options: .regularExpression) != nil { return true }
        if ["open in ", "listen on ", "在 apple music", "在 spotify", "加入播放", "新增至播放", "已識別", "shazams ·", "shazams •"].contains(where: { value.hasPrefix($0) }) { return true }
        return ["lte", "5g", "4g", "wi-fi", "wifi", "正在播放", "已下載", "隨機播放"].contains(value)
    }
    private static func isMusicContext(_ lines: [OCRLine]) -> Bool {
        let text = normalize(lines.map(\.text).joined(separator: " "))
        return ["shazam", "spotify", "apple music", "播放清單", "播放列表", "my music", "我的音樂"].contains { text.contains($0) }
    }
    public static func parse(_ lines: [OCRLine], assetID: String) -> SongParseResult {
        let musicContext = isMusicContext(lines)
        let usable = lines.indices.filter { !isControl(lines[$0].text) && lines[$0].confidence >= 0.35 }
        var consumed: Set<Int> = []
        var result: [SongCandidate] = []
        func candidate(title: String, artist: String?, indices: [Int], parser: String, confidence: String) -> SongCandidate {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SongCandidate(id: normalize(cleanTitle) + "\u{1F}" + normalize(cleanArtist ?? ""),
                                 title: cleanTitle, artist: cleanArtist, confidence: confidence,
                                 evidence: [SongEvidence(assetID: assetID, lineIndices: indices,
                                                       originalText: indices.map { lines[$0].text }, parser: parser)])
        }
        // Explicit separators remain review candidates: title/artist order is not guaranteed.
        for index in usable {
            let text = lines[index].text
            for separator in [" — ", " – ", " - ", " ／ ", " | "] {
                let parts = text.components(separatedBy: separator)
                if parts.count == 2, !isControl(parts[0]), !isControl(parts[1]) {
                    result.append(candidate(title: parts[0], artist: parts[1], indices: [index],
                                            parser: "explicit-separator-order-needs-review", confidence: musicContext ? "medium" : "low"))
                    consumed.insert(index); break
                }
            }
        }
        // Pair only geometrically adjacent rows in a music interface. Never pair arbitrary screenshot text.
        if musicContext {
            var position = 0
            while position + 1 < usable.count {
                let a = usable[position], b = usable[position + 1]
                let first = lines[a], second = lines[b]
                let verticalGap = first.y - second.y
                if !consumed.contains(a), !consumed.contains(b), abs(first.x - second.x) <= 0.10,
                   verticalGap > 0, verticalGap <= 0.085, first.height >= second.height * 0.75,
                   first.confidence >= 0.55, second.confidence >= 0.55 {
                    result.append(candidate(title: first.text, artist: second.text, indices: [a, b],
                                            parser: "music-interface-adjacent-pair-needs-review", confidence: "medium"))
                    consumed.formUnion([a, b]); position += 2
                } else { position += 1 }
            }
        }
        return SongParseResult(candidates: result, unresolvedLineIndices: usable.filter { !consumed.contains($0) },
                               detectedMusicInterface: musicContext)
    }
    /// Exact normalized title AND artist only. Remixes/live versions and unknown artists stay separate.
    public static func deduplicate(_ candidates: [SongCandidate]) -> [SongCandidate] {
        var result: [String: SongCandidate] = [:]
        for candidate in candidates {
            if var existing = result[candidate.id] {
                for evidence in candidate.evidence where !existing.evidence.contains(evidence) { existing.evidence.append(evidence) }
                if candidate.confidence == "low" { existing.confidence = "low" }
                result[candidate.id] = existing
            } else { result[candidate.id] = candidate }
        }
        return result.values.sorted { normalize($0.title) < normalize($1.title) }
    }
    public static func csv(_ songs: [SongCandidate]) -> String {
        func cell(_ value: String) -> String {
            var text = value
            if let first = text.first, "=+-@".contains(first) { text = "'" + text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = "song,artist,confidence,needs_review,evidence_count,source_asset_ids,original_ocr,spotify_search_url,youtube_search_url"
        return header + "\n" + songs.map { song in
            [song.title, song.artist ?? "", song.confidence, "true", String(song.evidence.count),
             song.evidence.map(\.assetID).joined(separator: " | "),
             song.evidence.flatMap(\.originalText).joined(separator: " | "), song.spotifySearchURL, song.youtubeSearchURL]
                .map(cell).joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }
}
