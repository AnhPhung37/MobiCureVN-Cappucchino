import SwiftUI

struct MedicationListView: View {
    @EnvironmentObject var store: MedicationStore
    @Environment(\.dismiss) var dismiss
    @State private var showingAdd = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.medications) { med in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(med.name)
                                    .font(.headline)
                                if !med.repeatsDaily {
                                    Text("One-time")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                                }
                            }

                            if let dose = med.dose {
                                Text(dose).font(.subheadline)
                            }

                            Text(med.times.joined(separator: ", "))
                                .font(.subheadline)

                            if !med.repeatsDaily {
                                Text(DateFormatter.localizedString(from: med.startDate, dateStyle: .medium, timeStyle: .none))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button(role: .destructive) {
                            if let index = store.medications.firstIndex(where: { $0.id == med.id }) {
                                store.remove(at: IndexSet(integer: index))
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Medications")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAdd = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showingAdd) {
                AddMedicationView().environmentObject(store)
            }
        }
    }
}

struct MedicationListView_Previews: PreviewProvider {
    static var previews: some View {
        MedicationListView().environmentObject(MedicationStore())
    }
}
