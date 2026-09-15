import SwiftUI

struct DayDetailView: View {
    @EnvironmentObject var store: MedicationStore
    @Environment(\.dismiss) private var dismiss
    let date: Date

    private var medsForDay: [Medication] {
        return store.medications.filter { med in
            let startOfDay = Calendar.current.startOfDay(for: date)

            if med.repeatsDaily {
                if startOfDay >= Calendar.current.startOfDay(for: med.startDate) {
                    if let end = med.endDate, startOfDay > Calendar.current.startOfDay(for: end) { return false }
                    return true
                }
            } else {
                return Calendar.current.isDate(startOfDay, inSameDayAs: med.startDate)
            }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if medsForDay.isEmpty {
                    Text("No medications scheduled for this day.")
                } else {
                    ForEach(medsForDay) { med in
                        Section(header: Text(med.name)) {
                            ForEach(med.times, id: \.self) { timeStr in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(timeStr).font(.body)
                                        if let dose = med.dose { Text(dose).font(.caption) }
                                    }
                                    Spacer()
                                    if let scheduled = store.scheduledDate(for: date, timeString: timeStr) {
                                        if store.isTaken(medicationId: med.id, scheduledAt: scheduled) {
                                            Text("Taken").foregroundColor(.green)
                                        } else {
                                            HStack(spacing: 8) {
                                                Button("Mark as taken") {
                                                    store.markTaken(medicationId: med.id, at: scheduled)
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .tint(.green)

                                                Button("Snooze") {
                                                    store.scheduleSnooze(for: med.id, minutes: 10)
                                                }
                                                .buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DayDetailView_Previews: PreviewProvider {
    static var previews: some View {
        DayDetailView(date: Date()).environmentObject(MedicationStore())
    }
}
