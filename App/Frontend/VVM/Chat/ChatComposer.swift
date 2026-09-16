import SwiftUI

/// The message box: attach a photo, type or dictate, send.
///
/// Every control is a 48pt square and the text is 18pt, and all four sit inside one outlined
/// field so the composer reads as a single place to write — the previous layout was 38pt
/// circles either side of a grey pill.
struct ChatComposer: View {
    @Binding var text: String
    var isListening: Bool = false
    /// A reply is being written: send becomes stop, and the mic is unavailable.
    var isAnswering: Bool = false
    var canSend: Bool = false
    /// False once the per-message photo limit is reached. The button stays tappable so the
    /// caller can explain the limit instead of silently doing nothing.
    var canAttach: Bool = true
    var onAttach: () -> Void = {}
    var onToggleVoice: () -> Void = {}
    var onSend: () -> Void = {}

    @FocusState private var isFocused: Bool

    private let controlSize: CGFloat = 48
    private let fieldShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private let controlShape = RoundedRectangle(cornerRadius: 15, style: .continuous)

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton

            TextField(
                isListening ? LocalizedStringKey("Đang nghe...") : LocalizedStringKey("Kể về triệu chứng của bạn..."),
                text: $text,
                axis: .vertical
            )
            .appFont(size: 18, design: .rounded)
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
            .frame(minHeight: controlSize)
            .onSubmit(onSend)

            voiceButton
            sendButton
        }
        .padding(6)
        .background(fieldShape.fill(Color(.secondarySystemGroupedBackground)))
        .overlay(
            fieldShape.strokeBorder(
                isFocused ? ChatPalette.accent : ChatPalette.outline,
                lineWidth: isFocused ? 2 : 1
            )
        )
    }

    private var attachButton: some View {
        Button(action: onAttach) {
            Image(systemName: "camera.fill")
                .appFont(size: 18, weight: .semibold)
                .foregroundColor(canAttach ? Color(.label) : Color(.tertiaryLabel))
                .frame(width: controlSize, height: controlSize)
                .background(controlShape.fill(Color(.tertiarySystemFill)))
                .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Đính kèm ảnh")
    }

    private var voiceButton: some View {
        Button(action: onToggleVoice) {
            Image(systemName: isListening ? "waveform" : "mic.fill")
                .appFont(size: 18, weight: .semibold)
                .foregroundColor(isListening ? .white : Color(.label))
                .symbolEffect(.variableColor.iterative, isActive: isListening)
                .frame(width: controlSize, height: controlSize)
                .background(controlShape.fill(isListening ? Color.red : Color(.tertiarySystemFill)))
                .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        // Recording while the model is mid-answer would fight the same audio session for no
        // benefit, so the mic is only available when the composer is otherwise usable.
        .disabled(isAnswering)
        .opacity(isAnswering ? 0.4 : 1)
        .accessibilityLabel(isListening ? LocalizedStringKey("Dừng nhập giọng nói") : LocalizedStringKey("Nhập bằng giọng nói"))
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: isAnswering ? "stop.fill" : "paperplane.fill")
                .appFont(size: 18, weight: .semibold)
                .foregroundColor(.white)
                .frame(width: controlSize, height: controlSize)
                .background(controlShape.fill(canSend ? ChatPalette.accent : Color(.tertiaryLabel)))
                .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(isAnswering ? LocalizedStringKey("Dừng trả lời") : LocalizedStringKey("Gửi"))
    }
}

#Preview {
    @Previewable @State var text = ""
    VStack(spacing: 16) {
        ChatComposer(text: $text, canSend: false)
        ChatComposer(text: .constant("Vết mổ hơi đỏ"), canSend: true)
        ChatComposer(text: .constant(""), isListening: true, canSend: false)
        ChatComposer(text: .constant(""), isAnswering: true, canSend: true)
    }
    .padding(16)
}
