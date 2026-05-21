import XCTest
@testable import MobiCureVN

/// Tests for MedicationStore — verifies medication CRUD, adherence tracking, and calendar helpers.
/// A new build passes if:
///   - Medications can be added, removed, and retrieved
///   - Taken/snoozed events are recorded correctly
///   - isTaken window check works
///   - hasMedication / dayCompletionStatus return correct values
@MainActor
final class MedicationStoreTests: XCTestCase {

    private var sut: MedicationStore!

    // Isolated UserDefaults keys so tests don't affect real app data
    private let medsKey = "MedicationStore.v1.meds"
    private let eventsKey = "MedicationStore.v1.events"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: medsKey)
        UserDefaults.standard.removeObject(forKey: eventsKey)
        sut = MedicationStore()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: medsKey)
        UserDefaults.standard.removeObject(forKey: eventsKey)
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeMedication(
        name: String = "Aspirin",
        dose: String? = "500mg",
        times: [String] = ["08:00"],
        daysFromNow: Int = 0,
        repeatsDaily: Bool = true
    ) -> Medication {
        let start = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date())!
        return Medication(name: name, dose: dose, times: times, startDate: start, repeatsDaily: repeatsDaily)
    }

    // MARK: - Add / Remove

    func testStartsEmpty() {
        XCTAssertTrue(sut.medications.isEmpty)
        XCTAssertTrue(sut.events.isEmpty)
    }

    func testAddMedicationAppearsInList() {
        let med = makeMedication(name: "Paracetamol")
        sut.add(med)
        XCTAssertEqual(sut.medications.count, 1)
        XCTAssertEqual(sut.medications[0].name, "Paracetamol")
    }

    func testAddMultipleMedications() {
        sut.add(makeMedication(name: "Drug A"))
        sut.add(makeMedication(name: "Drug B"))
        sut.add(makeMedication(name: "Drug C"))
        XCTAssertEqual(sut.medications.count, 3)
    }

    func testRemoveMedicationByOffset() {
        sut.add(makeMedication(name: "Drug A"))
        sut.add(makeMedication(name: "Drug B"))
        sut.remove(at: IndexSet(integer: 0))
        XCTAssertEqual(sut.medications.count, 1)
        XCTAssertEqual(sut.medications[0].name, "Drug B")
    }

    func testRemoveAllMedications() {
        sut.add(makeMedication())
        sut.add(makeMedication())
        sut.remove(at: IndexSet(integersIn: 0..<2))
        XCTAssertTrue(sut.medications.isEmpty)
    }

    // MARK: - Taken Events

    func testMarkTakenAddsEvent() {
        let med = makeMedication()
        sut.add(med)
        sut.markTaken(medicationId: med.id)
        XCTAssertEqual(sut.events.count, 1)
        XCTAssertEqual(sut.events[0].type, "taken")
        XCTAssertEqual(sut.events[0].medicationId, med.id)
    }

    func testMarkTakenMultipleTimesCreatesMultipleEvents() {
        let med = makeMedication()
        sut.add(med)
        sut.markTaken(medicationId: med.id)
        sut.markTaken(medicationId: med.id)
        let takenEvents = sut.events.filter { $0.type == "taken" }
        XCTAssertEqual(takenEvents.count, 2)
    }

    // MARK: - Snooze Events

    func testAddSnoozeEventCreatesSnoozeRecord() {
        let med = makeMedication()
        sut.add(med)
        sut.addSnoozeEvent(medicationId: med.id)
        XCTAssertEqual(sut.events.count, 1)
        XCTAssertEqual(sut.events[0].type, "snoozed")
    }

    // MARK: - isTaken Window Check

    func testIsTakenReturnsTrueWhenEventIsWithinWindow() {
        let med = makeMedication()
        sut.add(med)
        let scheduledTime = Date()
        sut.markTaken(medicationId: med.id, at: scheduledTime)
        XCTAssertTrue(sut.isTaken(medicationId: med.id, scheduledAt: scheduledTime, within: 60))
    }

    func testIsTakenReturnsFalseWhenEventIsOutsideWindow() {
        let med = makeMedication()
        sut.add(med)
        let scheduledTime = Date()
        let twoHoursLater = scheduledTime.addingTimeInterval(3 * 60 * 60) // 3 hours later
        sut.markTaken(medicationId: med.id, at: twoHoursLater)
        XCTAssertFalse(sut.isTaken(medicationId: med.id, scheduledAt: scheduledTime, within: 60))
    }

    func testIsTakenReturnsFalseWithNoEvents() {
        let med = makeMedication()
        sut.add(med)
        XCTAssertFalse(sut.isTaken(medicationId: med.id, scheduledAt: Date(), within: 60))
    }

    func testIsTakenReturnsFalseForDifferentMedication() {
        let med1 = makeMedication(name: "Drug A")
        let med2 = makeMedication(name: "Drug B")
        sut.add(med1)
        sut.add(med2)
        sut.markTaken(medicationId: med1.id, at: Date())
        XCTAssertFalse(sut.isTaken(medicationId: med2.id, scheduledAt: Date(), within: 60))
    }

    // MARK: - hasTakenMedication(on:)

    func testHasTakenMedicationReturnsTrueWhenTakenToday() {
        let med = makeMedication()
        sut.add(med)
        sut.markTaken(medicationId: med.id, at: Date())
        XCTAssertTrue(sut.hasTakenMedication(on: Date()))
    }

    func testHasTakenMedicationReturnsFalseWhenNothingTaken() {
        let med = makeMedication()
        sut.add(med)
        XCTAssertFalse(sut.hasTakenMedication(on: Date()))
    }

    func testHasTakenMedicationReturnsFalseForDifferentDay() {
        let med = makeMedication()
        sut.add(med)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        sut.markTaken(medicationId: med.id, at: yesterday)
        XCTAssertFalse(sut.hasTakenMedication(on: Date()))
    }

    // MARK: - hasMedication(on:)

    func testHasMedicationReturnsTrueForDailyMedOnActiveDay() {
        let med = makeMedication(repeatsDaily: true)
        sut.add(med)
        XCTAssertTrue(sut.hasMedication(on: Date()))
    }

    func testHasMedicationReturnsFalseWhenNoMedications() {
        XCTAssertFalse(sut.hasMedication(on: Date()))
    }

    func testHasMedicationReturnsTrueForOneTimeMedOnStartDate() {
        let today = Date()
        let med = Medication(name: "One-time Drug", times: ["09:00"], startDate: today, repeatsDaily: false)
        sut.add(med)
        XCTAssertTrue(sut.hasMedication(on: today))
    }

    func testHasMedicationReturnsFalseForOneTimeMedOnDifferentDay() {
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let med = Medication(name: "One-time Drug", times: ["09:00"], startDate: today, repeatsDaily: false)
        sut.add(med)
        XCTAssertFalse(sut.hasMedication(on: tomorrow))
    }

    // MARK: - dayCompletionStatus

    func testDayCompletionStatusNilWhenNoMedications() {
        XCTAssertNil(sut.dayCompletionStatus(on: Date()))
    }

    func testDayCompletionStatusFalseWhenMedNotTaken() {
        let med = makeMedication(times: ["08:00"])
        sut.add(med)
        let status = sut.dayCompletionStatus(on: Date())
        XCTAssertEqual(status, false)
    }

    // MARK: - takenDates(for:on:)

    func testTakenDatesReturnsEventsForCorrectDayAndMedication() {
        let med = makeMedication()
        sut.add(med)
        let today = Date()
        sut.markTaken(medicationId: med.id, at: today)
        let results = sut.takenDates(for: med.id, on: today)
        XCTAssertEqual(results.count, 1)
    }

    func testTakenDatesExcludesSnoozeEvents() {
        let med = makeMedication()
        sut.add(med)
        sut.markTaken(medicationId: med.id, at: Date())
        sut.addSnoozeEvent(medicationId: med.id, at: Date())
        let results = sut.takenDates(for: med.id, on: Date())
        XCTAssertEqual(results.count, 1) // only "taken", not "snoozed"
        XCTAssertEqual(results[0].type, "taken")
    }

    func testTakenDatesExcludesOtherMedications() {
        let med1 = makeMedication(name: "Drug A")
        let med2 = makeMedication(name: "Drug B")
        sut.add(med1)
        sut.add(med2)
        sut.markTaken(medicationId: med1.id, at: Date())
        let results = sut.takenDates(for: med2.id, on: Date())
        XCTAssertTrue(results.isEmpty)
    }
}

// MARK: - Medication Model Tests

final class MedicationModelTests: XCTestCase {

    func testMedicationEncodeDecode() throws {
        let med = Medication(
            id: UUID(),
            name: "Paracetamol",
            dose: "500mg",
            times: ["08:00", "20:00"],
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil,
            repeatsDaily: true
        )
        let data = try JSONEncoder().encode(med)
        let decoded = try JSONDecoder().decode(Medication.self, from: data)
        XCTAssertEqual(decoded.id, med.id)
        XCTAssertEqual(decoded.name, med.name)
        XCTAssertEqual(decoded.dose, med.dose)
        XCTAssertEqual(decoded.times, med.times)
        XCTAssertEqual(decoded.repeatsDaily, med.repeatsDaily)
    }

    func testMedicationEventEncodeDecode() throws {
        let event = MedicationEvent(
            id: UUID(),
            medicationId: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            type: "taken"
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(MedicationEvent.self, from: data)
        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.medicationId, event.medicationId)
        XCTAssertEqual(decoded.type, event.type)
    }

    func testMedicationWithOptionalDose() throws {
        let med = Medication(name: "Vitamin C", times: ["09:00"])
        let data = try JSONEncoder().encode(med)
        let decoded = try JSONDecoder().decode(Medication.self, from: data)
        XCTAssertNil(decoded.dose)
    }
}
