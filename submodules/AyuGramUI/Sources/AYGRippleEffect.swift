import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit

// AYG: the wave AyuGram for Android plays when Local Telegram Premium is switched on
// (`LaunchActivity.makeRipple(x, y, 0.9f)` from `toggleLocalPremium`).
//
// Android's version is a circular *reveal*: it snapshots the screen and grows a hole
// through which the already-updated UI shows. That only reads because enabling premium
// visibly changes things. Here the setting is not wired to anything, so a reveal would
// expose identical pixels and be invisible — this draws the expanding ring itself.
public func aygPlayRipple(in view: UIView, at point: CGPoint, color: UIColor) {
    let farthestCorner = [
        CGPoint(x: view.bounds.minX, y: view.bounds.minY),
        CGPoint(x: view.bounds.maxX, y: view.bounds.minY),
        CGPoint(x: view.bounds.minX, y: view.bounds.maxY),
        CGPoint(x: view.bounds.maxX, y: view.bounds.maxY)
    ].map { corner -> CGFloat in
        let dx = corner.x - point.x
        let dy = corner.y - point.y
        return sqrt(dx * dx + dy * dy)
    }.max() ?? view.bounds.width

    let rippleLayer = CAShapeLayer()
    rippleLayer.fillColor = color.withAlphaComponent(0.16).cgColor
    rippleLayer.frame = view.bounds
    rippleLayer.path = UIBezierPath(arcCenter: point, radius: 0.01, startAngle: 0.0, endAngle: CGFloat.pi * 2.0, clockwise: true).cgPath
    rippleLayer.isOpaque = false
    view.layer.addSublayer(rippleLayer)

    let duration: Double = 0.55

    let grow = CABasicAnimation(keyPath: "path")
    grow.fromValue = rippleLayer.path
    grow.toValue = UIBezierPath(arcCenter: point, radius: farthestCorner, startAngle: 0.0, endAngle: CGFloat.pi * 2.0, clockwise: true).cgPath
    grow.duration = duration
    grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
    grow.fillMode = .forwards
    grow.isRemovedOnCompletion = false

    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1.0 as NSNumber
    fade.toValue = 0.0 as NSNumber
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    fade.fillMode = .forwards
    fade.isRemovedOnCompletion = false

    rippleLayer.add(grow, forKey: "aygRippleGrow")
    rippleLayer.add(fade, forKey: "aygRippleFade")

    Queue.mainQueue().after(duration) { [weak rippleLayer] in
        rippleLayer?.removeFromSuperlayer()
    }
}
