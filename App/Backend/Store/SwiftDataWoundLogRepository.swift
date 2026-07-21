import Foundation
import SwiftData

@MainActor
final class SwiftDataWoundLogRepository: WoundLogRepository {

    private let container: ModelContainer

    init(container: ModelContainer? = nil) throws {
        if let container {
            self.container = container
        } else {
            self.container = try ModelContainer(for: WoundLogRecord.self)
        }
    }

    func loadEntries(patientID: UUID) async throws -> [WoundLogEntry] {
        let predicate = #Predicate<WoundLogRecord> { record in
            record.patientID == patientID
        }
        let descriptor = FetchDescriptor<WoundLogRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        let records = try container.mainContext.fetch(descriptor)
        return records.map { record in
            WoundLogEntry(
                id: record.id,
                patientID: record.patientID,
                capturedAt: record.capturedAt,
                imageReference: record.imageReference,
                stomaColor: record.stomaColor,
                stomaSizeChange: record.stomaSizeChange,
                surroundingSkin: record.surroundingSkin,
                outputAppearance: record.outputAppearance,
                bagSeal: record.bagSeal,
                swellingOrProtrusion: record.swellingOrProtrusion,
                otherObservations: record.otherObservations,
                rawDescription: record.rawDescription,
                flaggedForReview: record.flaggedForReview,
                modelUsed: record.modelUsed
            )
        }
    }

    func append(_ entry: WoundLogEntry) async throws {
        let record = WoundLogRecord(
            id: entry.id,
            patientID: entry.patientID,
            capturedAt: entry.capturedAt,
            imageReference: entry.imageReference,
            stomaColor: entry.stomaColor,
            stomaSizeChange: entry.stomaSizeChange,
            surroundingSkin: entry.surroundingSkin,
            outputAppearance: entry.outputAppearance,
            bagSeal: entry.bagSeal,
            swellingOrProtrusion: entry.swellingOrProtrusion,
            otherObservations: entry.otherObservations,
            rawDescription: entry.rawDescription,
            flaggedForReview: entry.flaggedForReview,
            modelUsed: entry.modelUsed
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    func delete(id: UUID) async throws {
        let predicate = #Predicate<WoundLogRecord> { record in
            record.id == id
        }
        let descriptor = FetchDescriptor<WoundLogRecord>(predicate: predicate)
        let records = try container.mainContext.fetch(descriptor)
        for record in records {
            container.mainContext.delete(record)
        }
        try container.mainContext.save()
    }
}
