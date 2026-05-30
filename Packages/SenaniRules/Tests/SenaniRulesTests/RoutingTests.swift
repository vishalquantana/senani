import Testing
@testable import SenaniRules

@Suite struct RoutingTests {
    @Test func outboundAlwaysQueuesRegardlessOfAutonomy() {
        for autonomy in [Autonomy.ask, .prepare, .auto] {
            #expect(ActionRouter.route(.reply(body: "x"), autonomy: autonomy) == .queuedForApproval)
            #expect(ActionRouter.route(.markSpam, autonomy: autonomy) == .queuedForApproval)
        }
    }

    @Test func reversibleUnderAutoExecutes() {
        #expect(ActionRouter.route(.label("x"), autonomy: .auto) == .executed)
    }

    @Test func reversibleUnderPrepareIsPrepared() {
        #expect(ActionRouter.route(.draft(body: "hi"), autonomy: .prepare) == .prepared)
    }

    @Test func reversibleUnderAskQueues() {
        #expect(ActionRouter.route(.archive, autonomy: .ask) == .queuedForApproval)
    }
}
