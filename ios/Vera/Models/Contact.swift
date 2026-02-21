import Foundation

struct Contact: Identifiable, Codable {
    let id: String
    let name: String
    let phone: String
    let relationship: String
}
