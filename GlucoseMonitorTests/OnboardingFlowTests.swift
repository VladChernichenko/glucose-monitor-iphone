import XCTest
@testable import GlucoseMonitor

// MARK: - RegistrationFormViewModel

@MainActor
final class RegistrationFormViewModelTests: XCTestCase {

    private var vm: RegistrationFormViewModel!

    override func setUp() {
        super.setUp()
        vm = RegistrationFormViewModel()
    }

    // MARK: canSubmit

    func test_canSubmit_false_whenAllEmpty() {
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_false_whenMissingFullName() {
        fill(fullName: "", username: "user1", email: "a@b.com", password: "secret", confirm: "secret")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_false_whenMissingUsername() {
        fill(fullName: "Alice", username: "", email: "a@b.com", password: "secret", confirm: "secret")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_false_whenPasswordTooShort() {
        fill(fullName: "Alice", username: "alice", email: "a@b.com", password: "abc", confirm: "abc")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_false_whenPasswordsMismatch() {
        fill(fullName: "Alice", username: "alice", email: "a@b.com", password: "secret1", confirm: "secret2")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_false_whenEmailInvalid() {
        fill(fullName: "Alice", username: "alice", email: "notanemail", password: "secret", confirm: "secret")
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_true_whenAllValid() {
        fill(fullName: "Alice", username: "alice", email: "alice@example.com", password: "secret", confirm: "secret")
        XCTAssertTrue(vm.canSubmit)
    }

    func test_canSubmit_false_whenBusy() {
        fill(fullName: "Alice", username: "alice", email: "alice@example.com", password: "secret", confirm: "secret")
        vm.isBusy = true
        XCTAssertFalse(vm.canSubmit)
    }

    // MARK: passwordMismatch

    func test_passwordMismatch_false_whenConfirmEmpty() {
        vm.password = "abc"
        vm.confirmPassword = ""
        XCTAssertFalse(vm.passwordMismatch)
    }

    func test_passwordMismatch_true_whenConfirmDiffers() {
        vm.password = "abc"
        vm.confirmPassword = "xyz"
        XCTAssertTrue(vm.passwordMismatch)
    }

    func test_passwordMismatch_false_whenMatch() {
        vm.password = "secret"
        vm.confirmPassword = "secret"
        XCTAssertFalse(vm.passwordMismatch)
    }

    // MARK: isEmailValid

    func test_isEmailValid_false_forPlainString() {
        vm.email = "notanemail"
        XCTAssertFalse(vm.isEmailValid)
    }

    func test_isEmailValid_false_forMissingDotInDomain() {
        vm.email = "user@nodot"
        XCTAssertFalse(vm.isEmailValid)
    }

    func test_isEmailValid_true_forValidEmail() {
        vm.email = "user@example.com"
        XCTAssertTrue(vm.isEmailValid)
    }

    func test_isEmailValid_false_forMultipleAtSigns() {
        vm.email = "a@b@c.com"
        XCTAssertFalse(vm.isEmailValid)
    }

    // MARK: helpers

    private func fill(fullName: String, username: String, email: String,
                      password: String, confirm: String) {
        vm.fullName = fullName
        vm.username = username
        vm.email = email
        vm.password = password
        vm.confirmPassword = confirm
    }
}

// MARK: - DataSourceSetupViewModel

@MainActor
final class DataSourceSetupViewModelTests: XCTestCase {

    private var vm: DataSourceSetupViewModel!

    override func setUp() {
        super.setUp()
        vm = DataSourceSetupViewModel()
    }

    // MARK: default state

    func test_defaultSource_isLibre() {
        XCTAssertEqual(vm.selectedSource, .libre)
    }

    func test_defaultLibreRegion_isEU() {
        XCTAssertEqual(vm.libreRegion, "en-EU")
    }

    func test_libreRegions_containsEightEntries() {
        XCTAssertEqual(DataSourceSetupViewModel.libreRegions.count, 8)
    }

    // MARK: canContinue — libre

    func test_canContinue_libre_false_whenBothEmpty() {
        vm.selectedSource = .libre
        XCTAssertFalse(vm.canContinue)
    }

    func test_canContinue_libre_false_whenOnlyEmailFilled() {
        vm.selectedSource = .libre
        vm.libreEmail = "user@libre.com"
        XCTAssertFalse(vm.canContinue)
    }

    func test_canContinue_libre_false_whenOnlyPasswordFilled() {
        vm.selectedSource = .libre
        vm.librePassword = "pass"
        XCTAssertFalse(vm.canContinue)
    }

    func test_canContinue_libre_true_whenBothFilled() {
        vm.selectedSource = .libre
        vm.libreEmail = "user@libre.com"
        vm.librePassword = "pass"
        XCTAssertTrue(vm.canContinue)
    }

    // MARK: canContinue — nightscout

    func test_canContinue_nightscout_false_whenEmpty() {
        vm.selectedSource = .nightscout
        XCTAssertFalse(vm.canContinue)
    }

    func test_canContinue_nightscout_false_whenNoScheme() {
        vm.selectedSource = .nightscout
        vm.nightscoutURL = "my.nightscout.com"
        XCTAssertFalse(vm.canContinue)
    }

    func test_canContinue_nightscout_true_whenHttpsURL() {
        vm.selectedSource = .nightscout
        vm.nightscoutURL = "https://my.nightscout.com"
        XCTAssertTrue(vm.canContinue)
    }

    func test_canContinue_nightscout_true_whenHttpURL() {
        vm.selectedSource = .nightscout
        vm.nightscoutURL = "http://my.nightscout.com"
        XCTAssertTrue(vm.canContinue)
    }

    // MARK: isNightscoutURLValid

    func test_isNightscoutURLValid_false_forEmpty() {
        vm.nightscoutURL = ""
        XCTAssertFalse(vm.isNightscoutURLValid)
    }

    func test_isNightscoutURLValid_false_forFTPScheme() {
        vm.nightscoutURL = "ftp://nightscout.example.com"
        XCTAssertFalse(vm.isNightscoutURLValid)
    }

    func test_isNightscoutURLValid_true_forHttps() {
        vm.nightscoutURL = "https://nightscout.example.com"
        XCTAssertTrue(vm.isNightscoutURLValid)
    }

    // MARK: Source enum

    func test_sourceDisplayName_libre() {
        XCTAssertEqual(DataSourceSetupViewModel.Source.libre.displayName, "LibreLinkUp")
    }

    func test_sourceDisplayName_nightscout() {
        XCTAssertEqual(DataSourceSetupViewModel.Source.nightscout.displayName, "Nightscout")
    }

    func test_sourceCases_count() {
        XCTAssertEqual(DataSourceSetupViewModel.Source.allCases.count, 2)
    }

    // MARK: switching source resets canContinue

    func test_switchingToNightscout_doesNotCarryOverLibreState() {
        vm.selectedSource = .libre
        vm.libreEmail = "user@libre.com"
        vm.librePassword = "pass"
        XCTAssertTrue(vm.canContinue)

        vm.selectedSource = .nightscout
        // nightscoutURL still empty — canContinue must be false
        XCTAssertFalse(vm.canContinue)
    }
}
