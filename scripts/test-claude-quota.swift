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
        assert(app.sameAccount == nil)
        let shared = try ClaudeQuotaDecoder.app(Data(#"{"version":2,"samples":[{"t":3000000,"u":{"fh":2,"sd":85}}],"sameAccount":true}"#.utf8))!
        assert(shared.sameAccount == true)
        // Newer wins; a sample whose reset passed loses to an older live one.
        assert(UsageSnapshot.fresher(app, cli, at: Date(timeIntervalSince1970: 2050))?.title == "Claude CLI")
        assert(UsageSnapshot.fresher(app, cli, at: Date(timeIntervalSince1970: 2200))?.title == "Claude App")
        assert(UsageSnapshot.fresher(shared, cli, at: Date(timeIntervalSince1970: 3100))?.title == "Claude App")
        assert(UsageSnapshot.fresher(nil, cli, at: Date())?.title == "Claude CLI")
        print("Passed: account separation, sample order, timestamp units, expiry, retained values, missing data, legacy format, unsupported format, same-account merge")
    }
}
