import AppKit

// Original artwork for the local preview. No upstream icon assets are used.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let board = NSRect(x: 90, y: 90, width: 844, height: 844)
NSColor(calibratedRed: 0.68, green: 0.49, blue: 0.31, alpha: 1).setFill()
NSBezierPath(roundedRect: board, xRadius: 172, yRadius: 172).fill()
let fabric = board.insetBy(dx: 23, dy: 23)
NSColor(calibratedRed: 0.80, green: 0.75, blue: 0.66, alpha: 1).setFill()
let fabricPath = NSBezierPath(roundedRect: fabric, xRadius: 151, yRadius: 151)
fabricPath.fill()
NSGraphicsContext.saveGraphicsState()
fabricPath.addClip()
for i in stride(from: 90, through: 935, by: 5) {
    let position = CGFloat(i)
    NSColor(calibratedWhite: 1, alpha: i % 3 == 0 ? 0.16 : 0.08).setStroke()
    let vertical = NSBezierPath()
    vertical.move(to: NSPoint(x: position, y: 90))
    vertical.line(to: NSPoint(x: position, y: 935))
    vertical.lineWidth = 1.2
    vertical.stroke()
    NSColor(calibratedRed: 0.40, green: 0.34, blue: 0.25, alpha: 0.10).setStroke()
    let horizontal = NSBezierPath()
    horizontal.move(to: NSPoint(x: 90, y: position))
    horizontal.line(to: NSPoint(x: 935, y: position))
    horizontal.lineWidth = 1.4
    horizontal.stroke()
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by: 520, yBy: 500)
transform.rotate(byDegrees: -7)
transform.concat()
let paper = NSBezierPath(roundedRect: NSRect(x: -225, y: -250, width: 450, height: 500), xRadius: 3, yRadius: 3)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.16, alpha: 0.30)
shadow.shadowBlurRadius = 23
shadow.shadowOffset = NSSize(width: 15, height: -19)
shadow.set()
NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.94, alpha: 1).setFill()
paper.fill()
NSShadow().set()
let printArea = NSRect(x: -194, y: -130, width: 388, height: 343)
NSGradient(starting: NSColor(calibratedRed: 0.58, green: 0.65, blue: 0.54, alpha: 1),
           ending: NSColor(calibratedRed: 0.83, green: 0.83, blue: 0.70, alpha: 1))!.draw(in: printArea, angle: 90)
NSColor(calibratedRed: 0.89, green: 0.81, blue: 0.60, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 62, y: 78, width: 74, height: 74)).fill()
NSGraphicsContext.restoreGraphicsState()

let pinRect = NSRect(x: 495, y: 721, width: 86, height: 80)
let pinShadow = NSShadow()
pinShadow.shadowColor = NSColor(calibratedRed: 0.26, green: 0.17, blue: 0.08, alpha: 0.42)
pinShadow.shadowBlurRadius = 9
pinShadow.shadowOffset = NSSize(width: 9, height: -13)
pinShadow.set()
NSGradient(starting: NSColor(calibratedRed: 0.91, green: 0.78, blue: 0.55, alpha: 1),
           ending: NSColor(calibratedRed: 0.66, green: 0.45, blue: 0.25, alpha: 1))!
    .draw(in: NSBezierPath(ovalIn: pinRect), angle: -65)
NSShadow().set()
NSColor(calibratedRed: 0.96, green: 0.85, blue: 0.64, alpha: 0.65).setStroke()
let pinRing = NSBezierPath(ovalIn: pinRect.insetBy(dx: 10, dy: 10))
pinRing.lineWidth = 2
pinRing.stroke()
image.unlockFocus()

guard CommandLine.arguments.count == 2,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Expected an output PNG path")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
