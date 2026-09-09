import Foundation

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date
    var modifiedAt: Date
    var isSlot: Bool
    var slotIndex: Int

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(), isSlot: Bool = false, slotIndex: Int = -1) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isSlot = isSlot
        self.slotIndex = slotIndex
    }

    var title: String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled" : String(firstLine.prefix(50))
    }
}