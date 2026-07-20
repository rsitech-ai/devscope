import AppKit
import Foundation

let outputURL = URL(
  fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/AppIcon.iconset")
let fileManager = FileManager.default
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
  ("icon_16x16.png", 16, 1),
  ("icon_16x16@2x.png", 16, 2),
  ("icon_32x32.png", 32, 1),
  ("icon_32x32@2x.png", 32, 2),
  ("icon_128x128.png", 128, 1),
  ("icon_128x128@2x.png", 128, 2),
  ("icon_256x256.png", 256, 1),
  ("icon_256x256@2x.png", 256, 2),
  ("icon_512x512.png", 512, 1),
  ("icon_512x512@2x.png", 512, 2),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func scaled(_ value: CGFloat, _ pixelSize: CGFloat) -> CGFloat {
  value / 1024 * pixelSize
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ pixelSize: CGFloat)
  -> NSRect
{
  NSRect(
    x: scaled(x, pixelSize),
    y: scaled(y, pixelSize),
    width: scaled(width, pixelSize),
    height: scaled(height, pixelSize)
  )
}

func point(_ x: CGFloat, _ y: CGFloat, _ pixelSize: CGFloat) -> NSPoint {
  NSPoint(x: scaled(x, pixelSize), y: scaled(y, pixelSize))
}

func drawLine(
  _ path: NSBezierPath,
  from start: NSPoint,
  to end: NSPoint
) {
  path.move(to: start)
  path.line(to: end)
}

func drawIcon(pixelSize: CGFloat) throws -> NSBitmapImageRep {
  let pixels = Int(pixelSize)
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else {
    throw CocoaError(.fileWriteUnknown)
  }
  bitmap.size = NSSize(width: pixelSize, height: pixelSize)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  defer { NSGraphicsContext.restoreGraphicsState() }

  let bounds = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
  let background = NSBezierPath(
    roundedRect: bounds,
    xRadius: scaled(224, pixelSize),
    yRadius: scaled(224, pixelSize)
  )
  color(8, 10, 15).setFill()
  background.fill()

  NSGradient(colors: [
    color(36, 50, 71),
    color(18, 24, 33),
    color(8, 10, 15),
  ])?.draw(in: background, angle: -48)

  let topHighlight = NSBezierPath()
  topHighlight.move(to: point(120, 244, pixelSize))
  topHighlight.curve(
    to: point(904, 240, pixelSize),
    controlPoint1: point(186, 106, pixelSize),
    controlPoint2: point(778, 88, pixelSize)
  )
  topHighlight.line(to: point(904, 202, pixelSize))
  topHighlight.curve(
    to: point(120, 218, pixelSize),
    controlPoint1: point(768, 68, pixelSize),
    controlPoint2: point(246, 72, pixelSize)
  )
  topHighlight.close()
  color(255, 255, 255, 0.075).setFill()
  topHighlight.fill()

  let panel = NSBezierPath(
    roundedRect: rect(142, 158, 740, 708, pixelSize),
    xRadius: scaled(116, pixelSize),
    yRadius: scaled(116, pixelSize)
  )
  NSGraphicsContext.current?.saveGraphicsState()
  let panelShadow = NSShadow()
  panelShadow.shadowColor = color(0, 0, 0, 0.35)
  panelShadow.shadowBlurRadius = scaled(36, pixelSize)
  panelShadow.shadowOffset = NSSize(width: 0, height: -scaled(28, pixelSize))
  panelShadow.set()
  color(16, 21, 31, 0.96).setFill()
  panel.fill()
  NSGraphicsContext.current?.restoreGraphicsState()

  NSGradient(colors: [
    color(36, 48, 68, 0.96),
    color(16, 21, 31, 0.96),
  ])?.draw(in: panel, angle: -52)

  color(255, 255, 255, 0.12).setStroke()
  panel.lineWidth = max(1, scaled(4, pixelSize))
  panel.stroke()

  let titleRule = NSBezierPath(
    roundedRect: rect(205, 786, 614, 5, pixelSize), xRadius: scaled(2.5, pixelSize),
    yRadius: scaled(2.5, pixelSize))
  color(255, 255, 255, 0.16).setFill()
  titleRule.fill()

  for (x, dotColor) in [
    (251 as CGFloat, color(255, 69, 58)),
    (308 as CGFloat, color(255, 214, 10)),
    (365 as CGFloat, color(50, 215, 75)),
  ] {
    dotColor.setFill()
    NSBezierPath(ovalIn: rect(x - 19, 719, 38, 38, pixelSize)).fill()
  }

  let center = point(512, 510, pixelSize)
  let ringRadius = scaled(232, pixelSize)
  let ringWidth = max(1, scaled(58, pixelSize))
  let ringBase = NSBezierPath()
  ringBase.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
  ringBase.lineWidth = ringWidth
  color(20, 125, 255).setStroke()
  ringBase.stroke()

  let cyanArc = NSBezierPath()
  cyanArc.appendArc(withCenter: center, radius: ringRadius, startAngle: 105, endAngle: 214)
  cyanArc.lineCapStyle = .round
  cyanArc.lineWidth = ringWidth
  color(38, 217, 255).setStroke()
  cyanArc.stroke()

  let greenArc = NSBezierPath()
  greenArc.appendArc(withCenter: center, radius: ringRadius, startAngle: 294, endAngle: 24)
  greenArc.lineCapStyle = .round
  greenArc.lineWidth = ringWidth
  color(31, 227, 107).setStroke()
  greenArc.stroke()

  let tick = NSBezierPath()
  tick.lineCapStyle = .round
  tick.lineWidth = max(1, scaled(44, pixelSize))
  drawLine(tick, from: point(512, 748, pixelSize), to: point(512, 630, pixelSize))
  drawLine(tick, from: point(512, 390, pixelSize), to: point(512, 272, pixelSize))
  drawLine(tick, from: point(274, 510, pixelSize), to: point(392, 510, pixelSize))
  drawLine(tick, from: point(632, 510, pixelSize), to: point(750, 510, pixelSize))
  color(247, 251, 255, 0.9).setStroke()
  tick.stroke()

  let core = NSBezierPath(ovalIn: rect(394, 392, 236, 236, pixelSize))
  color(10, 17, 27).setFill()
  core.fill()
  color(255, 255, 255, 0.16).setStroke()
  core.lineWidth = max(1, scaled(6, pixelSize))
  core.stroke()

  let chevron = NSBezierPath()
  chevron.lineCapStyle = .round
  chevron.lineJoinStyle = .round
  chevron.lineWidth = max(2, scaled(42, pixelSize))
  chevron.move(to: point(440, 550, pixelSize))
  chevron.line(to: point(390, 510, pixelSize))
  chevron.line(to: point(440, 470, pixelSize))
  color(247, 251, 255).setStroke()
  chevron.stroke()

  let prompt = NSBezierPath()
  prompt.lineCapStyle = .round
  prompt.lineWidth = max(2, scaled(42, pixelSize))
  drawLine(prompt, from: point(535, 558, pixelSize), to: point(627, 558, pixelSize))
  color(38, 217, 255).setStroke()
  prompt.stroke()

  let cursor = NSBezierPath()
  cursor.lineCapStyle = .round
  cursor.lineWidth = max(2, scaled(42, pixelSize))
  drawLine(cursor, from: point(535, 462, pixelSize), to: point(661, 462, pixelSize))
  color(31, 227, 107).setStroke()
  cursor.stroke()

  let waveform = NSBezierPath()
  waveform.lineCapStyle = .round
  waveform.lineJoinStyle = .round
  waveform.lineWidth = max(2, scaled(28, pixelSize))
  waveform.move(to: point(284, 314, pixelSize))
  for (x, y) in [
    (338 as CGFloat, 348 as CGFloat),
    (386, 304),
    (432, 376),
    (484, 346),
    (540, 432),
    (592, 316),
    (640, 358),
    (690, 336),
    (740, 394),
  ] {
    waveform.line(to: point(x, y, pixelSize))
  }
  color(255, 176, 32).setStroke()
  waveform.stroke()

  let waveformAccent = NSBezierPath()
  waveformAccent.lineCapStyle = .round
  waveformAccent.lineJoinStyle = .round
  waveformAccent.lineWidth = max(2, scaled(16, pixelSize))
  waveformAccent.move(to: point(540, 432, pixelSize))
  waveformAccent.line(to: point(592, 316, pixelSize))
  waveformAccent.line(to: point(640, 358, pixelSize))
  waveformAccent.line(to: point(690, 336, pixelSize))
  waveformAccent.line(to: point(740, 394, pixelSize))
  color(31, 227, 107).setStroke()
  waveformAccent.stroke()

  let baseline = NSBezierPath()
  baseline.lineCapStyle = .round
  baseline.lineWidth = max(1, scaled(12, pixelSize))
  drawLine(baseline, from: point(284, 266, pixelSize), to: point(740, 266, pixelSize))
  color(255, 255, 255, 0.18).setStroke()
  baseline.stroke()

  return bitmap
}

for size in sizes {
  let pixels = size.points * size.scale
  let bitmap = try drawIcon(pixelSize: pixels)
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try png.write(to: outputURL.appendingPathComponent(size.name))
}
