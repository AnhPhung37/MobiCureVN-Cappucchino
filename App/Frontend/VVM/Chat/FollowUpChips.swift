import SwiftUI

/// A next step the patient can take from the chat with one tap.
struct FollowUpSuggestion: Identifiable {
    enum Action {
        /// Sends `prompt` — a Localizable.xcstrings key — as the patient's next message.
        case ask(prompt: String)
        case takePhoto
    }

    /// Localizable.xcstrings key (Vietnamese source text).
    let title: String
    var systemImage: String? = nil
    let action: Action

    var id: String { title }
}

/// A row of follow-up chips above the composer, so the usual next questions after an answer
/// are one tap rather than typing on a phone keyboard.
///
/// Outlined rather than filled, so they read as buttons for the patient to press and not as
/// part of the answer card above them.
struct FollowUpChips: View {
    let suggestions: [FollowUpSuggestion]
    /// A question can't be sent while a reply is still being written. The photo chip only
    /// attaches, so it stays available.
    var isAnswering: Bool = false
    var onSelect: (FollowUpSuggestion) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions) { suggestion in
                    chip(suggestion)
                }
            }
        }
    }

    private func chip(_ suggestion: FollowUpSuggestion) -> some View {
        let isDisabled: Bool
        if case .ask = suggestion.action {
            isDisabled = isAnswering
        } else {
            isDisabled = false
        }

        return Button {
            onSelect(suggestion)
        } label: {
            HStack(spacing: 8) {
                if let systemImage = suggestion.systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(LocalizedStringKey(suggestion.title))
            }
            .appFont(size: 17, weight: .medium, design: .rounded)
            .foregroundColor(Color(.label))
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            .overlay(Capsule().strokeBorder(ChatPalette.outline, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}

#Preview {
    FollowUpChips(suggestions: [
        .init(title: "Chụp ảnh vết thương", systemImage: "camera.fill", action: .takePhoto),
        .init(title: "Đau tăng lên", action: .ask(prompt: "Tôi thấy đau tăng lên sau mổ. Tôi nên làm gì?")),
        .init(title: "Dịch tiết lạ", action: .ask(prompt: "Vết mổ của tôi có dịch tiết lạ. Tôi có nên lo không?")),
    ])
    .contentMargins(.horizontal, 16, for: .scrollContent)
}
