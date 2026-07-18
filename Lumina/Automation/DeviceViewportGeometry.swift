import CoreGraphics

nonisolated enum DeviceViewportGeometry {
    static func centerCropRect(source: CGSize, device: DeviceScreenInfo.Size) -> CGRect {
        guard source.width > 0,
              source.height > 0,
              device.width > 0,
              device.height > 0 else { return .zero }

        let sourceAspect = source.width / source.height
        let deviceAspect = CGFloat(device.width / device.height)
        if sourceAspect > deviceAspect {
            let width = source.height * deviceAspect
            return CGRect(
                x: (source.width - width) / 2,
                y: 0,
                width: width,
                height: source.height
            )
        }

        let height = source.width / deviceAspect
        return CGRect(
            x: 0,
            y: (source.height - height) / 2,
            width: source.width,
            height: height
        )
    }

    static func fittedDisplaySize(
        device: DeviceScreenInfo.Size,
        available: CGSize
    ) -> CGSize {
        guard device.width > 0,
              device.height > 0,
              available.width > 0,
              available.height > 0 else { return .zero }

        let scale = min(
            1,
            available.width / CGFloat(device.width),
            available.height / CGFloat(device.height)
        )
        return CGSize(
            width: floor(CGFloat(device.width) * scale),
            height: floor(CGFloat(device.height) * scale)
        )
    }

    static func map(
        _ point: CGPoint,
        from display: CGSize,
        to device: DeviceScreenInfo.Size
    ) -> AutomationPoint? {
        guard display.width > 0,
              display.height > 0,
              device.width > 0,
              device.height > 0 else { return nil }

        let u = min(max(Double(point.x / display.width), 0), 1)
        let v = min(max(Double(point.y / display.height), 0), 1)
        return AutomationPoint(
            x: min(u * device.width, device.width.nextDown),
            y: min(v * device.height, device.height.nextDown)
        )
    }
}
