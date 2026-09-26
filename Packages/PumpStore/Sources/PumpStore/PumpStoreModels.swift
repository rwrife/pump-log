import Foundation

public enum PumpVolumeUnit: String, Codable, CaseIterable, Sendable {
    case usGallon = "us_gallon"
    case imperialGallon = "imperial_gallon"
    case litre = "litre"
}

public enum PumpClassification: String, Codable, CaseIterable, Sendable {
    case full
    case partial
    case topoff
    case unknown
}

public struct Vehicle: Equatable, Sendable {
    public var id: UUID
    public var nickname: String
    public var createdAt: Date
    public var retiredAt: Date?

    public init(id: UUID = UUID(), nickname: String, createdAt: Date, retiredAt: Date? = nil) {
        self.id = id
        self.nickname = nickname
        self.createdAt = createdAt
        self.retiredAt = retiredAt
    }
}

public struct FillEvent: Equatable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var occurredAt: Date
    public var odometerDecimal: Decimal?
    public var volumeDecimal: Decimal
    public var volumeUnit: PumpVolumeUnit
    public var costCents: Int
    public var pumpClassification: PumpClassification
    public var note: String?

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        occurredAt: Date,
        odometerDecimal: Decimal?,
        volumeDecimal: Decimal,
        volumeUnit: PumpVolumeUnit,
        costCents: Int,
        pumpClassification: PumpClassification,
        note: String? = nil
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.occurredAt = occurredAt
        self.odometerDecimal = odometerDecimal
        self.volumeDecimal = volumeDecimal
        self.volumeUnit = volumeUnit
        self.costCents = costCents
        self.pumpClassification = pumpClassification
        self.note = note
    }
}

public struct ServiceEvent: Equatable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var occurredAt: Date
    public var odometerDecimal: Decimal?
    public var category: String
    public var costCents: Int
    public var intervalMileageDecimal: Decimal?
    public var intervalDays: Int?
    public var intervalRuleText: String?
    public var note: String?

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        occurredAt: Date,
        odometerDecimal: Decimal?,
        category: String,
        costCents: Int,
        intervalMileageDecimal: Decimal?,
        intervalDays: Int?,
        intervalRuleText: String?,
        note: String? = nil
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.occurredAt = occurredAt
        self.odometerDecimal = odometerDecimal
        self.category = category
        self.costCents = costCents
        self.intervalMileageDecimal = intervalMileageDecimal
        self.intervalDays = intervalDays
        self.intervalRuleText = intervalRuleText
        self.note = note
    }
}

public enum CorrectionTargetKind: String, Codable, CaseIterable, Sendable {
    case fillEvent = "fill_event"
    case serviceEvent = "service_event"
}

public struct CorrectionRecord: Equatable, Sendable {
    public var id: UUID
    public var targetKind: CorrectionTargetKind
    public var fillEventID: UUID?
    public var serviceEventID: UUID?
    public var version: Int
    public var correctedPayloadJSON: String
    public var correctedAt: Date

    public init(
        id: UUID = UUID(),
        targetKind: CorrectionTargetKind,
        fillEventID: UUID?,
        serviceEventID: UUID?,
        version: Int,
        correctedPayloadJSON: String,
        correctedAt: Date
    ) {
        self.id = id
        self.targetKind = targetKind
        self.fillEventID = fillEventID
        self.serviceEventID = serviceEventID
        self.version = version
        self.correctedPayloadJSON = correctedPayloadJSON
        self.correctedAt = correctedAt
    }
}

public enum PumpStoreError: Error, Equatable, Sendable {
    case parentNotFound(table: String, id: UUID)
    case eventNotFound(table: String, id: UUID)
    case invalidDecimal(field: String, value: String)
    case correctionPayloadCorrupt(table: String, id: UUID, underlying: String)
    case immutableIdentityMismatch(expectedID: UUID, observedID: UUID)
}

struct FillEventPayload: Codable, Equatable {
    var id: UUID
    var vehicleID: UUID
    var occurredAt: Date
    var odometerDecimal: String?
    var volumeDecimal: String
    var volumeUnit: PumpVolumeUnit
    var costCents: Int
    var pumpClassification: PumpClassification
    var note: String?

    init(event: FillEvent) {
        id = event.id
        vehicleID = event.vehicleID
        occurredAt = event.occurredAt
        odometerDecimal = event.odometerDecimal.map(PumpStoreDecimalCodec.encode)
        volumeDecimal = PumpStoreDecimalCodec.encode(event.volumeDecimal)
        volumeUnit = event.volumeUnit
        costCents = event.costCents
        pumpClassification = event.pumpClassification
        note = event.note
    }

    func toFillEvent() throws -> FillEvent {
        FillEvent(
            id: id,
            vehicleID: vehicleID,
            occurredAt: occurredAt,
            odometerDecimal: try odometerDecimal.map { try PumpStoreDecimalCodec.decode($0, field: "odometer_decimal") },
            volumeDecimal: try PumpStoreDecimalCodec.decode(volumeDecimal, field: "volume_decimal"),
            volumeUnit: volumeUnit,
            costCents: costCents,
            pumpClassification: pumpClassification,
            note: note
        )
    }
}

struct ServiceEventPayload: Codable, Equatable {
    var id: UUID
    var vehicleID: UUID
    var occurredAt: Date
    var odometerDecimal: String?
    var category: String
    var costCents: Int
    var intervalMileageDecimal: String?
    var intervalDays: Int?
    var intervalRuleText: String?
    var note: String?

    init(event: ServiceEvent) {
        id = event.id
        vehicleID = event.vehicleID
        occurredAt = event.occurredAt
        odometerDecimal = event.odometerDecimal.map(PumpStoreDecimalCodec.encode)
        category = event.category
        costCents = event.costCents
        intervalMileageDecimal = event.intervalMileageDecimal.map(PumpStoreDecimalCodec.encode)
        intervalDays = event.intervalDays
        intervalRuleText = event.intervalRuleText
        note = event.note
    }

    func toServiceEvent() throws -> ServiceEvent {
        ServiceEvent(
            id: id,
            vehicleID: vehicleID,
            occurredAt: occurredAt,
            odometerDecimal: try odometerDecimal.map { try PumpStoreDecimalCodec.decode($0, field: "odometer_decimal") },
            category: category,
            costCents: costCents,
            intervalMileageDecimal: try intervalMileageDecimal.map { try PumpStoreDecimalCodec.decode($0, field: "interval_mileage_decimal") },
            intervalDays: intervalDays,
            intervalRuleText: intervalRuleText,
            note: note
        )
    }
}

public enum PumpStoreCorrectionCodec {
    public static func encode(_ event: FillEvent) throws -> String {
        String(decoding: try PumpStoreJSON.encoder().encode(FillEventPayload(event: event)), as: UTF8.self)
    }

    public static func encode(_ event: ServiceEvent) throws -> String {
        String(decoding: try PumpStoreJSON.encoder().encode(ServiceEventPayload(event: event)), as: UTF8.self)
    }

    public static func decodeFillEvent(_ payload: String) throws -> FillEvent {
        try PumpStoreJSON.decoder()
            .decode(FillEventPayload.self, from: Data(payload.utf8))
            .toFillEvent()
    }

    public static func decodeServiceEvent(_ payload: String) throws -> ServiceEvent {
        try PumpStoreJSON.decoder()
            .decode(ServiceEventPayload.self, from: Data(payload.utf8))
            .toServiceEvent()
    }
}

enum PumpStoreJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum PumpStoreDecimalCodec {
    static func encode(_ decimal: Decimal) -> String {
        NSDecimalNumber(decimal: decimal).stringValue
    }

    static func decode(_ string: String, field: String) throws -> Decimal {
        guard let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
            throw PumpStoreError.invalidDecimal(field: field, value: string)
        }
        return value
    }
}
