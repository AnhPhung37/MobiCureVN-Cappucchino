import SwiftUI

struct HomeContentView: View {
    @StateObject private var medStore = MedicationStore()
    @State private var displayedDate: Date = Date()
    @State private var showingMedList = false
    @State private var showingDayDetail = false
    @State private var selectedDateForDetail: Date = Date()
    private var calendar: Calendar { Calendar.current }

    // MARK: - Date Helpers

    private func monthYearString(for date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "LLLL yyyy"
        return df.string(from: date)
    }

    private func generateMonthDays(for date: Date) -> [Int?] {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: components) else { return [] }

        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        let leadingEmpty = (weekdayOfFirst + 5) % 7

        let daysCount = calendar.range(of: .day, in: .month, for: date)?.count ?? 0

        var days: [Int?] = Array(repeating: nil, count: leadingEmpty)
        days += (1...daysCount).map { Optional($0) }

        while days.count < 42 { days.append(nil) }
        return days
    }

    private func isToday(day: Int, in monthDate: Date) -> Bool {
        let today = Date()
        guard calendar.isDate(today, equalTo: monthDate, toGranularity: .month) &&
              calendar.isDate(today, equalTo: monthDate, toGranularity: .year)
        else { return false }
        return calendar.component(.day, from: today) == day
    }

    private func firstOfMonth(for date: Date) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components)
    }

    private func dateFor(day: Int, in monthDate: Date) -> Date? {
        guard let first = firstOfMonth(for: monthDate) else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: first)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    greetingCard
                    calendarSection
                    journeySection
                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .navigationTitle("MobiCureVN")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    menuButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingMedList = true }) {
                        Image(systemName: "pills.fill")
                    }
                }
            }
            .sheet(isPresented: $showingMedList) {
                MedicationListView().environmentObject(medStore)
            }
            .sheet(isPresented: $showingDayDetail) {
                DayDetailView(date: selectedDateForDetail).environmentObject(medStore)
            }
        }
    }

    // MARK: - Menu Button

    private var menuButton: some View {
        Button(action: {}) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Color(.label))
        }
    }

    // MARK: - Greeting Card

    private var greetingCard: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Chào Nam,")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("Hôm nay bạn cảm thấy\nnhư thế nào ?")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))

                Button(action: {}) {
                    Text("Xem phân tích")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(.label))
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white)
                        )
                }
                .padding(.top, 4)
            }

            Spacer()

            Image("doctor")
                .resizable()
                .scaledToFit()
                .padding()
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.7), Color.blue.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Calendar Section

    private var calendarSection: some View {
        VStack(spacing: 16) {
            sectionHeader("Remind Calendar")
            calendarCard
        }
    }

    private var calendarCard: some View {
        VStack(spacing: 12) {
            monthNavigationHeader
            weekdayHeaders
            calendarGrid
            appointmentCard
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }

    private var monthNavigationHeader: some View {
        HStack(spacing: 12) {
            Button(action: {
                if let prev = calendar.date(byAdding: .month, value: -1, to: displayedDate) {
                    displayedDate = prev
                }
            }) {
                Image(systemName: "chevron.left")
            }

            Spacer()

            Text(monthYearString(for: displayedDate))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(.label))

            Spacer()

            Button(action: {
                if let next = calendar.date(byAdding: .month, value: 1, to: displayedDate) {
                    displayedDate = next
                }
            }) {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.top, 16)
    }

    private var weekdayHeaders: some View {
        HStack(spacing: 0) {
            ForEach(["mo", "tu", "we", "th", "fr", "sa", "su"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
    }

    private var calendarGrid: some View {
        VStack(spacing: 8) {
            let monthDays = generateMonthDays(for: displayedDate)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let index = week * 7 + weekday
                        if index < monthDays.count, let dayNumber = monthDays[index] {
                            calendarCell(dayNumber: dayNumber)
                        } else {
                            Text("")
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func calendarCell(dayNumber: Int) -> some View {
        let todayMark = isToday(day: dayNumber, in: displayedDate)
        let dayDate = dateFor(day: dayNumber, in: displayedDate)
        return VStack(spacing: 4) {
            Text("\(dayNumber)")
                .font(.system(size: 14, weight: todayMark ? .bold : .regular))
                .foregroundColor(todayMark ? .accentColor : Color(.label))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    todayMark ? Circle().fill(Color.accentColor.opacity(0.12)) : nil
                )

            if let dayDate, medStore.hasMedication(on: dayDate) {
                Circle()
                    .fill(medStore.dayCompletionStatus(on: dayDate) == true ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
            } else {
                Color.clear.frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if let dayDate {
                selectedDateForDetail = dayDate
                showingDayDetail = true
            }
        }
    }

    private var appointmentCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 24))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Appointment")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(.label))
                Text("Dr. Schmitz")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                Text("11:30 - 12:00")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.tertiaryLabel))
            }

            Spacer()

            Image(systemName: "calendar")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            Text("Done")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.green)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.top, 8)
    }

    // MARK: - Journey Section

    private var journeySection: some View {
        VStack(spacing: 16) {
            sectionHeader("Your Journey")
            journeyCard
        }
    }

    private var journeyCard: some View {
        HStack(spacing: 24) {
            Image("fire")
                .resizable()
                .scaledToFit()
                .padding()

            VStack(alignment: .leading, spacing: 8) {
                Text("256 days STRONG")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(.label))
                Text("Tuyệt vời, hãy tiếp tục nhé!")
                    .font(.system(size: 14))
                    .foregroundColor(Color(.secondaryLabel))
            }

            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Shared Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color(.label))
                .padding(.horizontal, 12)
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
        }
    }
}

#Preview {
    HomeContentView()
}
