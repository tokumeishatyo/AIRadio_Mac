import Foundation
import AIRadioCore

/// Google News RSS から最新ニュース見出しを取得する `ResearchSource`。
public struct NewsRssSource: ResearchSource {
    private let url: URL
    private let maxItems: Int
    private let http: any HTTPClient

    public init(url: String, maxItems: Int = 5, http: any HTTPClient) {
        self.url = URL(string: url) ?? URL(string: "https://news.google.com/rss?hl=ja&gl=JP&ceid=JP:ja")!
        self.maxItems = maxItems
        self.http = http
    }

    public func fetch() async throws -> String {
        do {
            let data = try await http.get(url: url, headers: [:])
            let titles = RssTitleParser().titles(from: data, limit: maxItems)
                .map(Self.cleanTitle)
                .filter { !$0.isEmpty }
            guard !titles.isEmpty else {
                throw ResearchError.newsFetchFailed("ニュース見出しが取得できませんでした")
            }
            return titles.joined(separator: "。") + "。"
        } catch let error as ResearchError {
            throw error
        } catch {
            throw ResearchError.newsFetchFailed(String(describing: error))
        }
    }

    /// `見出し - メディア名` の末尾メディア名を除去する。
    static func cleanTitle(_ title: String) -> String {
        let parts = title.components(separatedBy: " - ")
        let headline = parts.count > 1 ? parts.dropLast().joined(separator: " - ") : title
        return headline.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// RSS の `<item><title>` だけを集める XMLParser デリゲート（チャンネルタイトルは除外）。
final class RssTitleParser: NSObject, XMLParserDelegate {
    private var titles: [String] = []
    private var inItem = false
    private var inTitle = false
    private var buffer = ""

    func titles(from data: Data, limit: Int) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Array(titles.prefix(limit))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "item" { inItem = true }
        if elementName == "title", inItem { inTitle = true; buffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inTitle, let text = String(data: CDATABlock, encoding: .utf8) { buffer += text }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title", inItem, inTitle {
            inTitle = false
            titles.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if elementName == "item" { inItem = false }
    }
}
