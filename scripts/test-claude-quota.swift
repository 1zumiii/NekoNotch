import Foundation

@main
struct ClaudeQuotaTests {
    static func main() throws {
        let appData = Data(#"{"version":2,"samples":[{"t":1000000,"u":{"fh":98,"sd":21}},{"t":500000,"u":{"fh":1,"sd":2}}]}"#.utf8)
        let cliData = Data(#"{"t":2000,"five_hour":{"used":35,"resets_at":2100},"seven_day":{"used":67,"resets_at":9000}}"#.utf8)
        let app = try ClaudeQuotaDecoder.app(appData)!
        let cli = try ClaudeQuotaDecoder.cli(cliData)!
        assert(app.windows.map(\.formattedValue) == ["98%", "21%"])
        assert(cli.windows.map(\.formattedValue) == ["35%", "67%"])
        assert(app.lastUpdatedDate == Date(timeIntervalSince1970: 1000))
        assert(!cli.isStale(at: Date(timeIntervalSince1970: 2050)))
        assert(cli.isStale(at: Date(timeIntervalSince1970: 2101)))
        assert(cli.windows.first?.formattedValue == "35%", "Expired usage must not become zero")
        assert(app.isStale(at: Date(timeIntervalSince1970: 1901)))
        let empty = try ClaudeQuotaDecoder.app(Data(#"{"version":2,"samples":[]}"#.utf8))
        assert(empty == nil, "Missing App data must not fall back to CLI")
        let v1 = try ClaudeQuotaDecoder.app(Data(#"{"version":1,"samples":[{"t":1000,"fh":4,"sd":5}]}"#.utf8))!
        assert(v1.windows.map(\.formattedValue) == ["4%", "5%"])
        let unsupported = try ClaudeQuotaDecoder.app(Data(#"{"version":3,"samples":[]}"#.utf8))
        assert(unsupported == nil)
        print("Passed: account separation, sample order, timestamp units, expiry, retained values, missing data, legacy format, unsupported format")
    }
}
