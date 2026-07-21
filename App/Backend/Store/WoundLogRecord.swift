import Foundation
import SwiftData

@Model
final class WoundLogRecord {
    @Attribute(.unique) var id: UUID
    var patientID: UUID
    var capturedAt: Date
    var imageReference: URL
    var stomaColor: String
    var stomaSizeChange: String
    var surroundingSkin: String
    var outputAppearance: String
    var bagSeal: String
    var swellingOrProtrusion: String
    var otherObservations: String
    var rawDescription: String
    var flaggedForReview: Bool
    var modelUsed: String

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
