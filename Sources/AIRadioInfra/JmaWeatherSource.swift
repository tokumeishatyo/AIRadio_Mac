import Foundation
import AIRadioCore

/// 気象庁 予報 API から当日の天気を取得する `ResearchSource`。
public struct JmaWeatherSource: ResearchSource {
    private let areaCode: String
    private let areaName: String
    private let http: any HTTPClient

    public init(areaCode: String, areaName: String, http: any HTTPClient) {
        self.areaCode = areaCode
        self.areaName = areaName
        self.http = http
    }

    public func fetch() async throws -> String {
        do {
            let url = URL(string: "https://www.jma.go.jp/bosai/forecast/data/forecast/\(areaCode).json")!
            let data = try await http.get(url: url, headers: [:])
            let forecasts = try JSONDecoder().decode([Forecast].self, from: data)
            guard let weather = Self.extractWeather(forecasts, areaName: areaName) else {
                throw ResearchError.weatherFetchFailed("天気予報が取得できませんでした")
            }
            return "\(areaName)は、\(weather)、という予報です。"
        } catch let error as ResearchError {
            throw error
        } catch {
            throw ResearchError.weatherFetchFailed(String(describing: error))
        }
    }

    static func extractWeather(_ forecasts: [Forecast], areaName: String) -> String? {
        guard let first = forecasts.first else { return nil }
        for series in first.timeSeries {
            let area = series.areas.first(where: { $0.area.name == areaName && ($0.weathers?.isEmpty == false) })
                ?? series.areas.first(where: { $0.weathers?.isEmpty == false })
            if let weather = area?.weathers?.first {
                return normalize(weather)
            }
        }
        return nil
    }

    /// 気象庁の天気文字列は全角空白で区切られる（例: `くもり　夕方　から　雨`）。読み上げ用に除去する。
    static func normalize(_ weather: String) -> String {
        weather.replacingOccurrences(of: "\u{3000}", with: "")
    }

    struct Forecast: Decodable {
        let timeSeries: [TimeSeries]
        struct TimeSeries: Decodable {
            let areas: [Area]
            struct Area: Decodable {
                let area: AreaInfo
                let weathers: [String]?
                struct AreaInfo: Decodable { let name: String }
            }
        }
    }
}
