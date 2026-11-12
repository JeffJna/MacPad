// Draws the MacPad application icon and writes it as a 1024x1024 PNG.
// Usage: swift tools/make-icon.swift <output.png> [--ios]   (see tools/make-icon.sh)
// --ios draws a full-bleed square: iOS rounds the corners itself.
// This file is part of MacPad (GPL v3 or later).
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let fullBleed = CommandLine.arguments.contains("--ios")

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
	NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
	        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// Background: the standard macOS icon shape (824 pt rounded square on a 1024 pt canvas).
let plate = fullBleed ? NSRect(x: 0, y: 0, width: size, height: size) : NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = fullBleed ? NSBezierPath(rect: plate) : NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)
if !fullBleed {
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: colour(0x000000, 0.35).cgColor)
	colour(0x1B1F2A).setFill()
	platePath.fill()
	context.restoreGState()
}
NSGradient(colors: [colour(0x3B4252), colour(0x1A1D26)])!.draw(in: platePath, angle: -90)

// On iOS the sheet fills more of the icon, which has no margin of its own.
if fullBleed {
	let scale: CGFloat = 1.2
	context.translateBy(x: size / 2, y: size / 2)
	context.scaleBy(x: scale, y: scale)
	context.translateBy(x: -size / 2, y: -size / 2)
}

// Sheet of paper with a folded corner.
let sheet = NSRect(x: 272, y: 196, width: 480, height: 632)
let fold: CGFloat = 120
let radius: CGFloat = 40
let sheetPath = NSBezierPath()
sheetPath.move(to: NSPoint(x: sheet.minX + radius, y: sheet.minY))
sheetPath.line(to: NSPoint(x: sheet.maxX - radius, y: sheet.minY))
sheetPath.appendArc(withCenter: NSPoint(x: sheet.maxX - radius, y: sheet.minY + radius), radius: radius, startAngle: 270, endAngle: 0)
sheetPath.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
sheetPath.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
sheetPath.line(to: NSPoint(x: sheet.minX + radius, y: sheet.maxY))
sheetPath.appendArc(withCenter: NSPoint(x: sheet.minX + radius, y: sheet.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
sheetPath.line(to: NSPoint(x: sheet.minX, y: sheet.minY + radius))
sheetPath.appendArc(withCenter: NSPoint(x: sheet.minX + radius, y: sheet.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
sheetPath.close()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: colour(0x000000, 0.45).cgColor)
colour(0xFFFFFF).setFill()
sheetPath.fill()
context.restoreGState()
NSGradient(colors: [colour(0xFFFFFF), colour(0xE9EDF5)])!.draw(in: sheetPath, angle: -90)

let corner = NSBezierPath()
corner.move(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
corner.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 26))
corner.appendArc(withCenter: NSPoint(x: sheet.maxX - fold + 26, y: sheet.maxY - fold + 26), radius: 26, startAngle: 180, endAngle: 270)
corner.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
corner.close()
NSGradient(colors: [colour(0xC9D1E0), colour(0xAEB8CC)])!.draw(in: corner, angle: -45)

// Lines of "code": coloured bars indented like a small function.
struct Bar { let indent: CGFloat; let width: CGFloat; let colour: UInt32 }
let rows: [[Bar]] = [
	[Bar(indent: 0, width: 110, colour: 0x3D7BF7), Bar(indent: 130, width: 150, colour: 0x2B303B)],
	[Bar(indent: 48, width: 90, colour: 0xC678DD), Bar(indent: 158, width: 170, colour: 0x2FA84F)],
	[Bar(indent: 48, width: 200, colour: 0x8E96A8)],
	[Bar(indent: 96, width: 80, colour: 0x3D7BF7), Bar(indent: 196, width: 120, colour: 0xE8833A)],
	[Bar(indent: 48, width: 130, colour: 0x2B303B), Bar(indent: 198, width: 70, colour: 0xE8833A)],
	[Bar(indent: 0, width: 60, colour: 0x2B303B)],
]
let barHeight: CGFloat = 36
let rowGap: CGFloat = 72
var y = sheet.maxY - 196
for row in rows {
	for bar in row {
		let rect = NSRect(x: sheet.minX + 64 + bar.indent, y: y, width: bar.width, height: barHeight)
		colour(bar.colour).setFill()
		NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
	}
	y -= rowGap
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
