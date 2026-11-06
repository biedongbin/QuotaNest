import Foundation
import ServiceManagement
import Testing
@testable import QuotaNest

@Suite @MainActor struct LoginItemSettingsTests {
    private final class Manager: LoginItemManaging {
        var status: SMAppService.Status = .notRegistered
        var isAvailable = true
        var registrationResult: SMAppService.Status = .enabled
        var registrationError: Error?
        var unregistrationError: Error?
        var registrations = 0
        var unregistrations = 0
        var settingsOpened = false
        func register() throws {
            registrations += 1
            if let registrationError { throw registrationError }
            status = registrationResult
        }
        func unregister() throws {
            unregistrations += 1
            if let unregistrationError { throw unregistrationError }
            status = .notRegistered
        }
        func openSystemSettings() { settingsOpened = true }
    }

    @Test func initialStateAndExternalChangesComeFromTheSystem() {
        let manager = Manager()
        manager.status = .enabled
        let settings = LoginItemSettings(manager: manager)
        #expect(settings.isOn)
        manager.status = .notRegistered
        settings.refresh()
        #expect(!settings.isOn)
        #expect(manager.registrations == 0)
    }

    @Test func enablingReflectsPendingSystemApproval() {
        let manager = Manager()
        manager.registrationResult = .requiresApproval
        let settings = LoginItemSettings(manager: manager)
        settings.setEnabled(true)
        #expect(settings.status == .requiresApproval)
        #expect(settings.isOn)
        #expect(manager.registrations == 1)
        #expect(settings.errorMessage == nil)
        settings.openSystemSettings()
        #expect(manager.settingsOpened)
    }

    @Test func failedRegistrationDoesNotPretendToBeEnabled() {
        let manager = Manager()
        manager.registrationError = CocoaError(.featureUnsupported)
        let settings = LoginItemSettings(manager: manager)
        settings.setEnabled(true)
        #expect(!settings.isOn)
        #expect(settings.errorMessage != nil)
    }

    @Test func disablingAndFailedUnregisterKeepTheSystemTruth() {
        let manager = Manager()
        manager.status = .enabled
        manager.unregistrationError = CocoaError(.featureUnsupported)
        let settings = LoginItemSettings(manager: manager)
        settings.setEnabled(false)
        #expect(settings.isOn)
        #expect(settings.errorMessage != nil)
        manager.unregistrationError = nil
        settings.setEnabled(false)
        #expect(!settings.isOn)
        #expect(settings.errorMessage == nil)
    }

    @Test func unavailableContextsNeverChangeLoginItems() {
        let manager = Manager()
        manager.isAvailable = false
        let settings = LoginItemSettings(manager: manager)
        settings.setEnabled(true)
        #expect(!settings.isAvailable)
        #expect(manager.registrations == 0)
        #expect(!settings.isOn)
    }
}
