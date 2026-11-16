import Foundation

/// Something the user reports that can explain a deviation. Also the vocabulary for feedback tags.
public struct ManualLog: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case alcohol, caffeine, illness, stress, hardTraining, travel

        public var id: Self { self }

        public var title: String {
            switch self {
            case .alcohol: "Alcohol"
            case .caffeine: "Caffeine"
            case .illness: "Feeling sick"
            case .stress: "Stressful event"
            case .hardTraining: "Hard training"
            case .travel: "Travel"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind

    public init(id: UUID = UUID(), date: Date, kind: Kind) {
        self.id = id
        self.date = date
        self.kind = kind
    }
}
