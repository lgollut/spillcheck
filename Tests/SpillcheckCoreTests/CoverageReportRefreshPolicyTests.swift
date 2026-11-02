import Testing
@testable import SpillcheckCore

@Suite("Coverage report refresh interval")
struct CoverageReportRefreshPolicyTests {
    @Test func periodicRefreshWithNoVisibleReportUIWaitsThirtySeconds() {
        #expect(CoverageReportRefreshPolicy.minimumInterval(periodic: true, reportUIVisible: false, acceptanceRecovery: false) == 30)
    }

    @Test func periodicRefreshWhileReportUIIsVisibleWaitsFiveSeconds() {
        #expect(CoverageReportRefreshPolicy.minimumInterval(periodic: true, reportUIVisible: true, acceptanceRecovery: false) == 5)
    }

    @Test func nonPeriodicRefreshIsAlwaysFreshWhetherOrNotAnythingIsVisible() {
        for visible in [false, true] {
            #expect(CoverageReportRefreshPolicy.minimumInterval(periodic: false, reportUIVisible: visible, acceptanceRecovery: false) == 0)
        }
    }

    @Test func acceptanceRecoveryNeverReusesAReport() {
        for periodic in [false, true] {
            for visible in [false, true] {
                #expect(CoverageReportRefreshPolicy.minimumInterval(periodic: periodic, reportUIVisible: visible, acceptanceRecovery: true) == 0)
            }
        }
    }

    @Test func hiddenIntervalIsLongerThanVisibleButBoundedForTheMenuBarTooltip() {
        #expect(CoverageReportRefreshPolicy.hiddenInterval > CoverageReportRefreshPolicy.visibleInterval)
        #expect(CoverageReportRefreshPolicy.hiddenInterval <= 30)
    }
}
