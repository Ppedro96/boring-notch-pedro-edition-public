import Foundation
@main struct PedroBatteryWidgetTests { static func main() throws {
let phone = BatteryDevice(id: "s23", name: "S23 Ultra", kind: "s23", charge: 79, charging: false, connected: true, updatedAt: 1000)
assert(phone.fresh(at: Date(timeIntervalSince1970:1179)))
assert(!phone.fresh(at: Date(timeIntervalSince1970:1180)))
let mac = BatteryDevice(id: "mac", name: "MacBook Pro", kind: "mac", charge: 66, charging: false, connected: true, updatedAt:1000)
let snapshot=BatterySnapshot(updatedAt:1000,devices:[mac,phone])
let decoded=try JSONDecoder().decode(BatterySnapshot.self,from:JSONEncoder().encode(snapshot))
assert(decoded.phones.count == 1 && decoded.phones[0].kind == "s23")
print("Mac widget: decode, four-phone filter and stale boundary passed")

}}
