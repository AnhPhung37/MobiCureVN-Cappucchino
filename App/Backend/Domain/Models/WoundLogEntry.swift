import Foundation

struct WoundLogEntry: Identifiable, Sendable {
    let id: UUID
    let patientID: UUID
    let capturedAt: Date
    let imageReference: URL
    let stomaColor: String
    let stomaSizeChange: String
    let surroundingSkin: String
    let outputAppearance: String
    let bagSeal: String
    let swellingOrProtrusion: String
    let otherObservations: String
    let rawDescription: String
    let flaggedForReview: Bool
    let modelUsed: String

    init(
        id: UUID = UUID(),
        patientID: UUID,
        capturedAt: Date = Date(),
        imageReference: URL,
        stomaColor: String,
        stomaSizeChange: String,
        surroundingSkin: String,
        outputAppearance: String,
        bagSeal: String,
        swellingOrProtrusion: String,
        otherObservations: String,
        rawDescription: String,
        flaggedForReview: Bool = false,
        modelUsed: String
    ) {
        self.id = id
        self.patientID = patientID
        self.capturedAt = capturedAt
        self.imageReference = imageReference
        self.stomaColor = stomaColor
        self.stomaSizeChange = stomaSizeChange
        self.surroundingSkin = surroundingSkin
        self.outputAppearance = outputAppearance
        self.bagSeal = bagSeal
        self.swellingOrProtrusion = swellingOrProtrusion
        self.otherObservations = otherObservations
        self.rawDescription = rawDescription
        self.flaggedForReview = flaggedForReview
        self.modelUsed = modelUsed
    }
}
