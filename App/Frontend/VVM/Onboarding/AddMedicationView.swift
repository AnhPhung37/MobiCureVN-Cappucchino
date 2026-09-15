import SwiftUI

struct AddMedicationView: View {
    @EnvironmentObject var store: MedicationStore
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var dose: String = ""
    @State private var time: Date = Date()
    @State private var repeatsDaily: Bool = true
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Medication")) {
                    TextField("Name", text: $name)
                    TextField("Dose (optional)", text: $dose)
                }

                Section(header: Text("Schedule")) {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("Repeats daily", isOn: $repeatsDaily)

                    if repeatsDaily {
                        DatePicker("Start date", selection: $startDate, displayedComponents: .date)

                        DatePicker("End date", selection: $endDate, displayedComponents: .date)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reminder date")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            DatePicker("Select date", selection: $startDate, displayedComponents: .date)
                        }
                    }
                }
            }
            .navigationTitle("Add Medication")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let df = DateFormatter()
                        df.dateFormat = "HH:mm"
                        let timeStr = df.string(from: time)
                        let finalStartDate = startDate
                        let finalEndDate = repeatsDaily ? endDate : nil
                        let med = Medication(name: name, dose: dose.isEmpty ? nil : dose, times: [timeStr], startDate: finalStartDate, endDate: finalEndDate, repeatsDaily: repeatsDaily)
                        store.add(med)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct AddMedicationView_Previews: PreviewProvider {
    static var previews: some View {
        AddMedicationView().environmentObject(MedicationStore())
    }
}
