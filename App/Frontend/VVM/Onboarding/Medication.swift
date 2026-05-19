import SwiftUI
import Foundation
import Combine
import UserNotifications

struct Medication: Identifiable, Codable {
    let id: UUID
    var name: String
    var dose: String?
    var times: [String] // "HH:mm"
    var startDate: Date
    var endDate: Date?
    var repeatsDaily: Bool

    init(id: UUID = UUID(), name: String, dose: String? = nil, times: [String], startDate: Date = Date(), endDate: Date? = nil, repeatsDaily: Bool = true) {
        self.id = id
        self.name = name
        self.dose = dose
        self.times = times
        self.startDate = startDate
        self.endDate = endDate
        self.repeatsDaily = repeatsDaily
    }
}

struct MedicationEvent: Identifiable, Codable {
    let id: UUID
    let medicationId: UUID
    let timestamp: Date
    let type: String // "taken" | "snoozed"

    init(id: UUID = UUID(), medicationId: UUID, timestamp: Date = Date(), type: String) {
        self.id = id
        self.medicationId = medicationId
        self.timestamp = timestamp
        self.type = type
    }
}

final class MedicationStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var medications: [Medication] = []
    @Published var events: [MedicationEvent] = []

    private let medsKey = "MedicationStore.v1.meds"
    private let eventsKey = "MedicationStore.v1.events"

    override init() {
        super.init()
        load()
        setupNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: medsKey), let decoded = try? JSONDecoder().decode([Medication].self, from: data) {
            medications = decoded
        }
        if let data = UserDefaults.standard.data(forKey: eventsKey), let decoded = try? JSONDecoder().decode([MedicationEvent].self, from: data) {
            events = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(medications) {
            UserDefaults.standard.set(data, forKey: medsKey)
        }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: eventsKey)
        }
    }

    func add(_ med: Medication) {
        medications.append(med)
        save()
        scheduleNotifications(for: med)
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let med = medications[index]
            cancelNotifications(for: med)
        }
        medications.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Events
    func markTaken(medicationId: UUID, at timestamp: Date = Date()) {
        let ev = MedicationEvent(medicationId: medicationId, timestamp: timestamp, type: "taken")
        events.append(ev)
        save()
    }

    func addSnoozeEvent(medicationId: UUID, at timestamp: Date = Date()) {
        let ev = MedicationEvent(medicationId: medicationId, timestamp: timestamp, type: "snoozed")
        events.append(ev)
        save()
    }

    func takenDates(for medicationId: UUID, on day: Date) -> [MedicationEvent] {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.medicationId == medicationId && $0.timestamp >= start && $0.timestamp < end && $0.type == "taken" }
    }

    // MARK: - Notifications
    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // handle if needed
        }
    }

    private func setupNotificationCategories() {
        let take = UNNotificationAction(identifier: "TAKE_ACTION", title: "Taken", options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: "SNOOZE_ACTION", title: "Snooze 10m", options: [])
        let category = UNNotificationCategory(identifier: "MEDICATION_CATEGORY", actions: [take, snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func scheduleNotifications(for med: Medication) {
        let center = UNUserNotificationCenter.current()

        for time in med.times {
            let components = timeComponents(from: time)
            var dateComponents = DateComponents()
            dateComponents.hour = components.hour
            dateComponents.minute = components.minute

            let content = UNMutableNotificationContent()
            content.title = "Uống thuốc: \(med.name)"
            if let dose = med.dose { content.body = dose }
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = "MEDICATION_CATEGORY"
            content.userInfo = ["medId": med.id.uuidString, "time": time]

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: med.repeatsDaily)
            let id = "med_\(med.id.uuidString)_\(time)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            center.add(request) { error in
                // handle error optionally
            }

        }
    }

    private func cancelNotifications(for med: Medication) {
        let ids = med.times.map { "med_\(med.id.uuidString)_\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func timeComponents(from hhmm: String) -> (hour: Int, minute: Int) {
        let parts = hhmm.split(separator: ":").map { Int($0) ?? 0 }
        let h = parts.count > 0 ? parts[0] : 0
        let m = parts.count > 1 ? parts[1] : 0
        return (h, m)
    }

    // Handle action responses
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        if let medIdStr = userInfo["medId"] as? String, let medId = UUID(uuidString: medIdStr) {
            switch response.actionIdentifier {
            case "TAKE_ACTION":
                markTaken(medicationId: medId)
            case "SNOOZE_ACTION":
                // schedule a single notification 10 minutes later
                let snoozeInterval: TimeInterval = 10 * 60
                let newId = "snooze_\(medId.uuidString)_\(Date().timeIntervalSince1970)"
                let content = UNMutableNotificationContent()
                content.title = response.notification.request.content.title
                content.body = response.notification.request.content.body
                content.sound = UNNotificationSound.default
                content.categoryIdentifier = "MEDICATION_CATEGORY"
                content.userInfo = ["medId": medId.uuidString]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: snoozeInterval, repeats: false)
                let req = UNNotificationRequest(identifier: newId, content: content, trigger: trigger)
                center.add(req)
                addSnoozeEvent(medicationId: medId)
            default:
                break
            }
        }
        completionHandler()
    }

    // schedule a snooze notification programmatically (e.g., from UI)
    func scheduleSnooze(for medicationId: UUID, minutes: Int = 10) {
        guard let med = medications.first(where: { $0.id == medicationId }) else { return }
        let center = UNUserNotificationCenter.current()
        let snoozeInterval: TimeInterval = TimeInterval(minutes * 60)
        let newId = "snooze_\(medicationId.uuidString)_\(Date().timeIntervalSince1970)"
        let content = UNMutableNotificationContent()
        content.title = "Uống thuốc: \(med.name)"
        if let dose = med.dose { content.body = dose }
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "MEDICATION_CATEGORY"
        content.userInfo = ["medId": medicationId.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: snoozeInterval, repeats: false)
        let req = UNNotificationRequest(identifier: newId, content: content, trigger: trigger)
        center.add(req)
        addSnoozeEvent(medicationId: medicationId)
    }

    func isTaken(medicationId: UUID, scheduledAt: Date, within minutesWindow: Int = 60) -> Bool {
        let windowStart = scheduledAt.addingTimeInterval(TimeInterval(-minutesWindow * 60))
        let windowEnd = scheduledAt.addingTimeInterval(TimeInterval(minutesWindow * 60))
        return events.contains { ev in
            ev.medicationId == medicationId && ev.type == "taken" && ev.timestamp >= windowStart && ev.timestamp <= windowEnd
        }
    }

    func hasTakenMedication(on date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return false }
        return events.contains { ev in
            ev.type == "taken" && ev.timestamp >= day && ev.timestamp < end
        }
    }

    func dayCompletionStatus(on date: Date) -> Bool? {
        let day = Calendar.current.startOfDay(for: date)
        let scheduledMedications = medications.filter { med in
            if med.repeatsDaily {
                guard day >= Calendar.current.startOfDay(for: med.startDate) else { return false }
                if let end = med.endDate, day > Calendar.current.startOfDay(for: end) { return false }
                return true
            } else {
                return Calendar.current.isDate(day, inSameDayAs: med.startDate)
            }
        }

        guard !scheduledMedications.isEmpty else { return nil }

        for med in scheduledMedications {
            for time in med.times {
                guard let scheduled = scheduledDate(for: day, timeString: time) else { return false }
                if !isTaken(medicationId: med.id, scheduledAt: scheduled) {
                    return false
                }
            }
        }

        return true
    }

    private func scheduledDate(for day: Date, timeString: String) -> Date? {
        let parts = timeString.split(separator: ":").map { Int($0) ?? 0 }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = parts.count > 0 ? parts[0] : 0
        comps.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: comps)
    }

    // MARK: - Helpers for calendar
    func hasMedication(on date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        for med in medications {
            if med.repeatsDaily {
                if day >= Calendar.current.startOfDay(for: med.startDate) {
                    if let end = med.endDate, day > Calendar.current.startOfDay(for: end) { continue }
                    return true
                }
            } else {
                if Calendar.current.isDate(day, inSameDayAs: med.startDate) {
                    return true
                }
            }
        }
        return false
    }
}
