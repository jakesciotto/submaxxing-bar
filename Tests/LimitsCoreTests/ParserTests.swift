import Foundation
import Testing
@testable import LimitsCore

@Test func claudeReadsWindowsScopedLimitsAndSpendWithoutLettingSpendDriveThePeak() throws {
    let json = """
    {"five_hour":{"utilization":13.0,"resets_at":"2026-11-10T18:00:00.123456+00:00"},
     "seven_day":{"utilization":7.0,"resets_at":"2026-11-16T22:00:00.075606+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_oauth_apps":null,
     "extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":31240.0,"utilization":62.48,
                    "currency":"USD","decimal_places":2},
     "limits":[{"kind":"session","percent":13},
               {"kind":"weekly_scoped","percent":7,"resets_at":"2026-11-16T22:00:00.075813+00:00",
                "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
    """
    let snapshot = try ClaudeParser.parse(Data(json.utf8), plan: "Max 5x", now: Date())
    #expect(snapshot.meters.map(\.label) == ["Session", "Weekly", "Fable weekly", "Extra usage"])
    #expect(snapshot.meters[3].kind == .spend)
    #expect(snapshot.meters[3].detail == "$312 / $500")
    #expect(snapshot.peakPercent == 13)
    let expected = Date(timeIntervalSince1970: 1_794_333_600.123)
    #expect(abs(snapshot.meters[0].resetsAt!.timeIntervalSince(expected)) < 0.001)
}

@Test func claudePlanLabelPrefersSubscriptionTypeOverTier() {
    #expect(ClaudeParser.planLabel(type: "team", tier: "default_claude_max_5x") == "Team")
    #expect(ClaudeParser.planLabel(type: "max", tier: "default_claude_max_20x") == "Max 20x")
}

@Test func codexLabelsWindowsByLengthAndResolvesBothResetForms() throws {
    let json = """
    {"plan_type":"team","rate_limit":{"allowed":false,"limit_reached":true,
      "primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_at":1794000000},
      "secondary_window":{"used_percent":16,"limit_window_seconds":604800,"reset_after_seconds":3600}},
     "spend_control":{"reached":false,"individual_limit":{"unit":"credit","limit":"20000",
      "used":"1240.3","reset_at":1796083200}}}
    """
    let now = Date(timeIntervalSince1970: 1_793_990_000)
    let snapshot = try CodexParser.parse(Data(json.utf8), planFallback: nil, now: now)
    #expect(snapshot.plan == "Team")
    #expect(snapshot.meters.map(\.label) == ["Session", "Weekly", "Credits"])
    #expect(snapshot.meters[0].resetsAt == Date(timeIntervalSince1970: 1_794_000_000))
    #expect(snapshot.meters[1].resetsAt == now.addingTimeInterval(3600))
    #expect(snapshot.meters[2].kind == .spend)
    #expect(snapshot.meters[2].detail == "1,240 / 20,000")
}

@Test func cursorComputesPercentFromCentsAndSkipsDisabledOnDemand() throws {
    let json = """
    {"billingCycleEnd":"2026-11-22T00:00:00.000Z","membershipType":"pro",
     "individualUsage":{"plan":{"enabled":true,"used":1480,"limit":2000},
                        "onDemand":{"enabled":false,"used":0,"limit":null}}}
    """
    let snapshot = try CursorParser.parse(Data(json.utf8), membership: nil, now: Date())
    #expect(snapshot.plan == "Pro")
    #expect(snapshot.meters.count == 1)
    #expect(snapshot.meters[0].usedPercent == 74)
    #expect(snapshot.meters[0].detail == "$15 / $20")
}

@Test func cursorRejectsAnUnknownFormatInsteadOfShowingZero() {
    #expect(throws: FetchError.self) {
        try CursorParser.parse(Data(#"{"startOfMonth":"2026-11-01"}"#.utf8), membership: nil, now: Date())
    }
}
