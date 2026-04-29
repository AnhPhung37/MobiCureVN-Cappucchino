//
//  HomeView.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

struct HomeView: View {
    
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Home Tab
            HomeContentView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .tag(0)
            
            // Chat Tab
            ChatView(llmService: AppConfig.llmService)
                .tabItem {
                    Image(systemName: "message.fill")
                    Text("Chat")
                }
                .tag(1)
        }
        .tint(.accentColor)
    }
}

// MARK: - Home Content View

struct HomeContentView: View {
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Greeting Card
                    greetingCard
                    
                    // Remind Calendar Section
                    calendarSection
                    
                    // Your Journey Section
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
            }
        }
    }
    
    // MARK: - Menu Button
    
    private var menuButton: some View {
        Button(action: {
            // Menu action
        }) {
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
                
                Button(action: {
                    // Navigate to feedback
                }) {
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
            
            // Placeholder doctor illustration
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
            // Section Header
            HStack {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1)
                
                Text("Remind Calendar")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(.label))
                    .padding(.horizontal, 12)
                
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1)
            }
            
            // Calendar Placeholder
            calendarPlaceholder
        }
    }
    
    private var calendarPlaceholder: some View {
        VStack(spacing: 12) {
            // Month Header
            Text("September")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(.label))
                .padding(.top, 16)
            
            // Weekday Headers
            HStack(spacing: 0) {
                ForEach(["mo", "tu", "we", "th", "fr", "sa", "su"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            
            // Calendar Grid (Simplified)
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { day in
                            let dayNumber = week * 7 + day + 1
                            if dayNumber <= 30 {
                                Text("\(dayNumber)")
                                    .font(.system(size: 14, weight: dayNumber == 13 ? .bold : .regular))
                                    .foregroundColor(dayNumber == 13 ? .accentColor : Color(.label))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .background(
                                        dayNumber == 13 ? 
                                        Circle().fill(Color.accentColor.opacity(0.1)) : nil
                                    )
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
            
            // Appointment Card
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Journey Section
    
    private var journeySection: some View {
        VStack(spacing: 16) {
            // Section Header
            HStack {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1)
                
                Text("Your Journey")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(.label))
                    .padding(.horizontal, 12)
                
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1)
            }
            
            // Journey Stats
            HStack(spacing: 24) {
                // Placeholder water drop icon
                
                    
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
    }
}

#Preview {
    HomeView()
}
