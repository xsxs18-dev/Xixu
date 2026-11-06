import UIKit

/// Drawn file and folder icons (Finder-style document with a type label),
/// Settings-style colored squircles, and app icons read from app bundles.
enum Icons {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()

    private static func mix(_ color: UIColor, _ target: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // MARK: - Files

    /// Icon for a list row. `dark` follows the current interface style.
    static func file(_ item: FileItem, size: CGFloat = 34, dark: Bool) -> UIImage {
        if Prefs.themeStyle == .ios {
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.74, weight: .regular)
            let color: UIColor = item.isDirectory ? Theme.accent : .secondaryLabel
            let symbol = item.isSymlink ? "arrow.turn.up.right" : item.kind.symbol
            if let image = UIImage(systemName: symbol, withConfiguration: config) {
                return image.withTintColor(color, renderingMode: .alwaysOriginal)
            }
        }
        let link = item.isSymlink
        if item.isDirectory {
            let color: UIColor = item.kind == .package ? .systemGray : Theme.accent
            return folder(color: color, size: size, link: link)
        }
        let (label, color) = badge(for: item, dark: dark)
        return document(label: label, color: color, size: size, dark: dark, link: link)
    }

    static func folder(color: UIColor, size: CGFloat = 34, link: Bool = false) -> UIImage {
        let key = "folder|\(color.description)|\(size)|\(link)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let back = mix(resolved, .black, 0.16)
        let front = mix(resolved, .white, 0.16)
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let k = size / 34
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
            }
            back.setFill()
            UIBezierPath(roundedRect: rect(1, 4.5, 13, 4.5), cornerRadius: 2 * k).fill()
            UIBezierPath(roundedRect: rect(1, 6.5, 32, 23.5), cornerRadius: 3.2 * k).fill()
            front.setFill()
            UIBezierPath(roundedRect: rect(1, 10, 32, 20), cornerRadius: 3.2 * k).fill()
            if link { drawLinkBadge(k: k) }
        }.withRenderingMode(.alwaysOriginal)
        cache.setObject(image, forKey: key)
        return image
    }

    static func document(label: String?, color: UIColor?, size: CGFloat = 34, dark: Bool, link: Bool = false) -> UIImage {
        let key = "doc|\(label ?? "")|\(color?.description ?? "")|\(size)|\(dark)|\(link)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let page = dark ? rgb(58, 58, 62) : .white
        let stroke = dark ? rgb(82, 82, 88) : rgb(205, 205, 212)
        let foldColor = dark ? rgb(86, 86, 92) : rgb(229, 229, 234)
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let k = size / 34
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let x0: CGFloat = 6, y0: CGFloat = 1.5, x1: CGFloat = 28, y1: CGFloat = 32.5, f: CGFloat = 7, r: CGFloat = 2.6

            let body = UIBezierPath()
            body.move(to: p(x0 + r, y0))
            body.addLine(to: p(x1 - f, y0))
            body.addLine(to: p(x1, y0 + f))
            body.addLine(to: p(x1, y1 - r))
            body.addQuadCurve(to: p(x1 - r, y1), controlPoint: p(x1, y1))
            body.addLine(to: p(x0 + r, y1))
            body.addQuadCurve(to: p(x0, y1 - r), controlPoint: p(x0, y1))
            body.addLine(to: p(x0, y0 + r))
            body.addQuadCurve(to: p(x0 + r, y0), controlPoint: p(x0, y0))
            body.close()
            page.setFill()
            body.fill()
            stroke.setStroke()
            body.lineWidth = 0.6 * k
            body.stroke()

            let fold = UIBezierPath()
            fold.move(to: p(x1 - f, y0))
            fold.addLine(to: p(x1 - f, y0 + f - 1.4))
            fold.addQuadCurve(to: p(x1 - f + 1.4, y0 + f), controlPoint: p(x1 - f, y0 + f))
            fold.addLine(to: p(x1, y0 + f))
            fold.close()
            foldColor.setFill()
            fold.fill()
            fold.lineWidth = 0.6 * k
            fold.stroke()

            if let label = label, let color = color, !label.isEmpty {
                let badge = CGRect(x: (x0 + 2.2) * k, y: 22 * k, width: (x1 - x0 - 4.4) * k, height: 7 * k)
                color.setFill()
                UIBezierPath(roundedRect: badge, cornerRadius: 1.6 * k).fill()
                let fontSize = (label.count <= 4 ? 5.2 : 4.3) * k
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                    .foregroundColor: UIColor.white,
                    .kern: 0.15 * k,
                ]
                let text = label as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2), withAttributes: attributes)
            }
            if link { drawLinkBadge(k: k) }
        }.withRenderingMode(.alwaysOriginal)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Small alias arrow in the lower left corner, like Finder.
    private static func drawLinkBadge(k: CGFloat) {
        let circle = CGRect(x: 0.5 * k, y: 21.5 * k, width: 12 * k, height: 12 * k)
        UIColor.white.setFill()
        let path = UIBezierPath(ovalIn: circle)
        path.fill()
        UIColor(white: 0, alpha: 0.18).setStroke()
        path.lineWidth = 0.6 * k
        path.stroke()
        let config = UIImage.SymbolConfiguration(pointSize: 6.5 * k, weight: .bold)
        if let arrow = UIImage(systemName: "arrow.turn.up.right", withConfiguration: config)?
            .withTintColor(.black, renderingMode: .alwaysOriginal) {
            arrow.draw(at: CGPoint(x: circle.midX - arrow.size.width / 2, y: circle.midY - arrow.size.height / 2))
        }
    }

    private static func badge(for item: FileItem, dark: Bool) -> (String?, UIColor?) {
        let ext = Paths.split(item.name).ext.uppercased()
        let shortExt = ext.count <= 5 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : ""
        switch item.kind {
        case .plist: return (ext == "STRINGS" ? "STR" : "PLIST", rgb(94, 107, 125))
        case .deb: return ("DEB", rgb(242, 113, 33))
        case .ipa: return ("IPA", rgb(10, 132, 255))
        case .archive:
            if ext == "XIXUBACKUP" { return ("BAK", rgb(255, 149, 0)) }
            return (shortExt.isEmpty ? "ZIP" : String(shortExt.prefix(4)), rgb(176, 124, 58))
        case .dylib: return ("DYLIB", rgb(140, 82, 224))
        case .sqlite: return ("DB", rgb(16, 163, 160))
        case .text: return (shortExt.isEmpty ? nil : shortExt, rgb(120, 120, 128))
        case .code: return (shortExt.isEmpty ? "CODE" : shortExt, rgb(88, 86, 214))
        case .image: return (shortExt, rgb(52, 170, 90))
        case .video: return (shortExt, rgb(175, 82, 222))
        case .audio: return (shortExt, rgb(232, 62, 140))
        case .pdf: return ("PDF", rgb(229, 72, 77))
        case .document: return (shortExt, rgb(0, 122, 255))
        case .font: return (shortExt, rgb(99, 99, 102))
        case .binary: return ("EXEC", dark ? rgb(99, 99, 102) : rgb(44, 44, 46))
        case .special: return ("SYS", rgb(142, 142, 147))
        case .other: return (shortExt.isEmpty || shortExt.count > 4 ? nil : shortExt, rgb(142, 142, 147))
        case .folder, .app, .package: return (nil, nil)
        }
    }

    // MARK: - Squircles

    /// White glyph on a colored rounded square, like the rows in iOS Settings.
    static func squircle(_ symbol: String, _ color: UIColor, size: CGFloat = 29) -> UIImage {
        let key = "sq|\(symbol)|\(color.description)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerRadius: size * 0.225).fill()
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let scale = min(1, (size * 0.66) / max(glyph.size.width, glyph.size.height))
                let w = glyph.size.width * scale, h = glyph.size.height * scale
                glyph.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
            }
        }.withRenderingMode(.alwaysOriginal)
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - App icons

    private static var missing = Set<String>()

    /// Reads the icon straight from an app bundle (public API only) and rounds it.
    static func app(bundlePath: String, size: CGFloat = 60) -> UIImage? {
        let key = "app|\(bundlePath)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if missing.contains(bundlePath) { return nil }
        guard let source = loadAppIcon(bundlePath) else {
            missing.insert(bundlePath)
            return nil
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.225).addClip()
            source.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func loadAppIcon(_ bundlePath: String) -> UIImage? {
        guard let bundle = Bundle(path: bundlePath), let info = bundle.infoDictionary else { return nil }
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            if let files = primary["CFBundleIconFiles"] as? [String] { names += files.reversed() }
            if let name = primary["CFBundleIconName"] as? String { names.append(name) }
        }
        if let files = info["CFBundleIconFiles"] as? [String] { names += files.reversed() }
        if let file = info["CFBundleIconFile"] as? String { names.append(file) }
        names += ["AppIcon60x60", "AppIcon", "Icon-60", "Icon@2x", "Icon"]
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil), image.size.width >= 20 {
                return image
            }
        }
        return nil
    }
}
