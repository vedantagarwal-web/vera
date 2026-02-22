import Foundation

struct Config {
    // Change this to the IP of the machine running the Vera bridge server
    static let bridgeIP = "10.1.10.116"
    static let bridgeWS = "ws://\(bridgeIP):3001/ws"
    static let bridgeHTTP = "http://\(bridgeIP):3001"

    // Demo contacts — replace phone numbers with real ones for the demo
    struct DemoContacts {
        static let jake = Contact(id: "1", name: "Jake", phone: "+1YOUR_NUMBER", relationship: "friend")
        static let mom = Contact(id: "2", name: "Mom", phone: "+1YOUR_NUMBER", relationship: "family")
        static let all = [jake, mom]
    }
}
