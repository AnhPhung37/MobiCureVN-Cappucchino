import Foundation

/// The two kinds of text a chat turn can put on screen.
///
/// The medical pipeline cannot stream its real answer token-by-token: the output guardrail
/// (hallucination detection, unsafe-dosage detection, citation enforcement) inspects the
/// COMPLETE response and may rewrite or replace it outright, so text it has not seen can never
/// be treated as the answer. That is why generation is buffered — but buffering left the bubble
/// empty for the whole decode, which on a 3B on-device model is most of the wait.
///
/// So both kinds of text travel on one stream, clearly labelled:
///
/// - `.preview` — the decoder's raw output so far. It exists only so the user can watch the
///   answer being written instead of staring at a spinner. It has passed no guardrail, may stop
///   mid-word, and is never persisted or replayed to the model.
/// - `.final` — the answer, after the output guardrail and the language-drift check. Delivered
///   exactly once per turn, replaces whatever preview is on screen, and is what gets stored.
///
/// Consumers must treat `.preview` as display-only and `.final` as authoritative.
enum ChatStreamEvent: Sendable, Equatable {
    /// Draft text so far. A cumulative snapshot rather than a delta, so a consumer can simply
    /// assign it — dropping intermediate snapshots (or arriving late) costs nothing.
    case preview(String)

    /// The complete, validated response for this turn.
    case final(String)
}
