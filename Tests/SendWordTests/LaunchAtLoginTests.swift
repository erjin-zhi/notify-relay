import ServiceManagement
import XCTest
@testable import SendWord

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testEnableAndDisableFollowSystemStatus() async {
        let service = StubLoginService()
        let model = makeModel(service)
        XCTAssertTrue(model.isAvailable)
        XCTAssertFalse(model.isEnabled)

        model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.errorMessage)

        model.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertFalse(model.isEnabled)
    }

    func testEnableFailureKeepsActualDisabledStateAndCanRetry() async {
        let service = StubLoginService()
        service.registerError = StubError.failed
        let model = makeModel(service)

        model.setEnabled(true)
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.errorMessage?.contains("无法开启") == true)

        service.registerError = nil
        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.errorMessage)
    }

    func testDisableFailureKeepsActualEnabledState() async {
        let service = StubLoginService(status: .enabled)
        service.unregisterError = StubError.failed
        let model = makeModel(service)

        model.setEnabled(false)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.errorMessage?.contains("无法关闭") == true)
    }

    func testFailureStillRefreshesStateChangedBySystem() async {
        let service = StubLoginService()
        service.registerError = StubError.failed
        service.statusBeforeRegisterError = .requiresApproval
        let model = makeModel(service)

        model.setEnabled(true)
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNotNil(model.errorMessage)
    }

    func testApprovalPendingCanOpenSettingsAndBeDisabled() async {
        let service = StubLoginService()
        service.statusAfterRegister = .requiresApproval
        let model = makeModel(service)

        model.setEnabled(true)
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertTrue(model.isEnabled)
        model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1, "等待批准时不重复注册")

        model.openSystemSettings()
        XCTAssertEqual(service.openSettingsCalls, 1)
        model.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(model.isEnabled)
    }

    func testRefreshPicksUpExternalChanges() async {
        let service = StubLoginService(status: .enabled)
        let model = makeModel(service)

        service.currentStatus = .requiresApproval
        model.refresh()
        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertTrue(model.isEnabled)

        service.currentStatus = .notRegistered
        model.refresh()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testExternalStatusChangeClearsPreviousFailure() async {
        let service = StubLoginService()
        service.registerError = StubError.failed
        let model = makeModel(service)
        model.setEnabled(true)
        XCTAssertNotNil(model.errorMessage)

        // 用户随后在系统设置中成功启用，返回应用时不再展示旧错误。
        service.currentStatus = .enabled
        model.refresh()
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.errorMessage)
    }

    func testToggleReadsLatestSystemStateBeforeDecidingWhetherToRegister() async {
        let service = StubLoginService(status: .enabled)
        let model = makeModel(service)

        // 用户在系统设置关闭登录项后，应用还没收到刷新事件。
        service.currentStatus = .notRegistered
        model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(model.isEnabled)

        model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1, "已启用时不重复注册")
        model.setEnabled(false)
        model.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1, "已关闭时不重复注销")
    }

    func testSuccessfulRegisterWithoutEnabledStatusIsNotReportedAsEnabled() async {
        let service = StubLoginService()
        service.statusAfterRegister = .notRegistered
        let model = makeModel(service)

        model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertFalse(model.isEnabled)
    }

    func testUnavailableModesNeverAccessOrModifySystemService() async {
        for (bundlePath, environment) in [
            ("/tmp/SendWord", [String: String]()),
            ("/Applications/SendWord.app", ["SEND_WORD_SNAPSHOT": "/tmp/screenshots"]),
            ("/Applications/SendWord.app", ["SEND_WORD_SNAPSHOT": ""]),
        ] {
            let service = StubLoginService(status: .enabled)
            let model = makeModel(service, bundlePath: bundlePath, environment: environment)
            XCTAssertFalse(model.isAvailable)
            XCTAssertFalse(model.isEnabled)
            model.setEnabled(true)
            model.setEnabled(false)
            model.refresh()
            model.openSystemSettings()
            XCTAssertEqual(service.statusReads, 0)
            XCTAssertEqual(service.registerCalls, 0)
            XCTAssertEqual(service.unregisterCalls, 0)
            XCTAssertEqual(service.openSettingsCalls, 0)
        }
    }

    private func makeModel(
        _ service: StubLoginService,
        bundlePath: String = "/Applications/SendWord.app",
        environment: [String: String] = [:]
    ) -> LaunchAtLogin {
        LaunchAtLogin(service: service, bundleURL: URL(fileURLWithPath: bundlePath), environment: environment)
    }
}

@MainActor
private final class StubLoginService: LaunchAtLoginServicing {
    var currentStatus: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var statusBeforeRegisterError: SMAppService.Status?
    var registerError: Error?
    var unregisterError: Error?
    var statusReads = 0
    var registerCalls = 0
    var unregisterCalls = 0
    var openSettingsCalls = 0

    init(status: SMAppService.Status = .notRegistered) { currentStatus = status }

    var status: SMAppService.Status {
        statusReads += 1
        return currentStatus
    }

    func register() throws {
        registerCalls += 1
        if let registerError {
            if let statusBeforeRegisterError { currentStatus = statusBeforeRegisterError }
            throw registerError
        }
        currentStatus = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        currentStatus = .notRegistered
    }

    func openSystemSettings() { openSettingsCalls += 1 }
}

private enum StubError: LocalizedError {
    case failed
    var errorDescription: String? { "系统拒绝了本次操作" }
}
