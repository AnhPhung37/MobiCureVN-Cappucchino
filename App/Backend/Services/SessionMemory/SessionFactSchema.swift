//
//  SessionFactSchema.swift
//  MobiCureVN
//

import Foundation
import FoundationModels

/// Schema for the guided-generation path of `SessionFactExtractor`.
///
/// The categories here must stay in step with `SessionFactExtractor.factKeys`, which is what the
/// free-text fallback path accepts and what `SessionFactSchemaTests` asserts against. `.anyOf`
/// makes the constraint structural rather than advisory: the decoder cannot emit a category
/// outside the list, so the "unrecognized key" branch the text parser needs simply has no
/// equivalent failure here.
@available(iOS 26.0, *)
@Generable
struct ExtractedSessionFacts {
    @Guide(
        description: """
        Every durable fact the user stated about themselves in the message. \
        Empty when the message states none.
        """,
        .maximumCount(8)
    )
    var facts: [ExtractedSessionFact]
}

@available(iOS 26.0, *)
@Generable
struct ExtractedSessionFact {
    @Guide(
        description: "Which category of fact this is.",
        .anyOf(["name", "age", "sex", "allergy", "wound_location", "medication", "condition"])
    )
    var key: String

    @Guide(description: "The fact itself, in as few words as possible. English.")
    var value: String
}
