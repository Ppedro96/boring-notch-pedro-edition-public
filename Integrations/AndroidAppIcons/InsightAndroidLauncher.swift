import AppKit

if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "icon" {
    let output = CommandLine.arguments[2], label = CommandLine.arguments[3]
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.lockFocus()
    NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 488, height: 488), xRadius: 110, yRadius: 110).fill()
    NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.95, alpha: 1).setStroke()
    let tablet = label.localizedCaseInsensitiveContains("tab")
    let fold = label.localizedCaseInsensitiveContains("fold")
    let body = NSBezierPath(roundedRect: NSRect(x: tablet ? 76 : fold ? 111 : 151, y: 124, width: tablet ? 360 : fold ? 290 : 210, height: 304), xRadius: label.contains("23") ? 12 : 28, yRadius: label.contains("23") ? 12 : 28)
    body.lineWidth = 13; body.stroke()
    if fold { let hinge = NSBezierPath(); hinge.move(to:NSPoint(x:256,y:128)); hinge.line(to:NSPoint(x:256,y:424)); hinge.lineWidth=5; hinge.stroke() }
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 246, y: 400, width: 20, height: 20)).fill()
    let text = label as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 51, weight: .bold), .foregroundColor: NSColor.white]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (512-size.width)/2, y: 42), withAttributes: attributes)
    image.unlockFocus()
    if let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) {
        try png.write(to:URL(fileURLWithPath:output)); exit(0)
    }
    exit(1)
}
// A pinned/recent app can be reopened through the same authorized device broker.
let info = Bundle.main.infoDictionary ?? [:]
guard let device=info["InsightDeviceID"] as? String,
      let helper=info["InsightBrokerPath"] as? String else { exit(1) }
let package=info["InsightAndroidPackage"] as? String
let child=Process(); child.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
child.arguments=[helper, package == nil ? "open" : "app", device] + (package.map { [$0] } ?? [])
child.standardInput=FileHandle.nullDevice
child.standardOutput=FileHandle.nullDevice
child.standardError=FileHandle.nullDevice
do { try child.run(); exit(0) } catch { exit(1) }
