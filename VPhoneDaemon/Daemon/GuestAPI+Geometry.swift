import CoreFoundation
import Foundation
import IcliKit
import VphonedNative

extension GuestAPI {
    static func needsInterfaceGeometry(_ method: String, _ params: [String: Any]) -> Bool {
        switch method {
        case "input.tap", "input.double_tap", "input.long_press", "input.swipe", "input.drag",
             "ui.tree", "accessibility.tree", "ui.element_at", "ui.tap_element",
             "ui.wait", "ui.wait_gone":
            return true
        case "input.touch", "input.touch_sequence":
            return !(params["normalized"] as? Bool ?? true)
        default:
            return false
        }
    }

    /// Capture before taking the AX lock. The synchronous Icli scope stays on
    /// this RPC's thread and covers validation, AX clipping and HID conversion.
    /// Bundle checks do not establish an atomic scene or process epoch.
    static func activeInterfaceGeometry(for method: String) throws -> InterfaceGeometry {
        // Explicit points target the display, including Home and System UI.
        // AX-derived coordinates additionally need a verified app scene.
        let requireForeground = method.hasPrefix("ui.") || method == "accessibility.tree"
        return try interfaceGeometry(from: foregroundDisplayLayout(), requireForeground: requireForeground)
    }

    static func activeScreenInfo() throws -> [String: Any] {
        let geometry = try interfaceGeometry(from: foregroundDisplayLayout(), requireForeground: false)
        return withInterfaceGeometry(geometry) { screenInfo() }
    }

    static func activeScreenState() -> [String: Any] {
        do { return try activeScreenInfo() }
        catch {
            let failure = error as? IcliError
            return ["available": false, "error": [
                "code": failure?.code ?? "unavailable",
                "message": failure?.message ?? String(describing: error),
            ]]
        }
    }

    static func requireCaptureCoordinateCompatibility() throws {
        let active = try interfaceGeometry(from: foregroundDisplayLayout(), requireForeground: false)
        try requireCaptureCoordinateCompatibility(active: active, legacy: screenInfo())
    }

    /// OCR/describe publish point coordinates in the legacy capture transform.
    /// Equal metrics preserve that contract but do not prove display identity.
    /// Capture stays outside the override until its active raster is verified.
    static func requireCaptureCoordinateCompatibility(active: InterfaceGeometry, legacy: [String: Any]) throws {
        let expected = ["width": active.width, "height": active.height,
                        "scale": active.scale, "orientation": Double(active.orientation)]
        guard expected.allSatisfy({ key, expected in
            guard let value = legacy[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return false }
            return value.doubleValue == expected
        }) else {
            throw IcliError.unavailable("Capture coordinates differ from active interface")
        }
    }

    static func foregroundDisplayLayout() -> [String: Any] {
        let foreground = frontmostApp()
        let bundleID = foreground["verified"] as? Bool == true
            ? foreground["bundle_id"] as? String : nil
        var layout = vp_display_layout(bundleID)
        let after = frontmostApp()
        let stable = bundleID?.isEmpty == false
            && after["verified"] as? Bool == true
            && after["bundle_id"] as? String == bundleID
        layout["foreground_bundle_verified"] = stable
        layout["foreground_verification"] = stable
            ? "bundle_only_matched_before_and_after_non_atomic" : "bundle_unverified_or_changed"
        if !stable {
            layout["frontmost_bundle_id"] = NSNull()
            layout["monitors"] = (layout["monitors"] as? [[String: Any]] ?? []).map { monitor in
                var monitor = monitor
                monitor["foreground_scenes"] = [] as [Any]
                monitor["matched_scene_count"] = 0
                return monitor
            }
        }
        return layout
    }

    static func interfaceGeometry(from layout: [String: Any], requireForeground: Bool) throws -> InterfaceGeometry {
        func unavailable(_ reason: String) -> IcliError {
            .unavailable("Active interface geometry is unavailable: \(reason)")
        }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func rect(_ value: Any?) -> CGRect? {
            guard let value = value as? [String: Any], let x = number(value["x"]), let y = number(value["y"]),
                  let width = number(value["width"]), let height = number(value["height"]),
                  width > 0, height > 0, (x + width).isFinite, (y + height).isFinite else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard layout["available"] as? Bool == true,
              layout["geometry_available"] as? Bool == true,
              let monitors = layout["monitors"] as? [[String: Any]] else {
            let reason = layout["reason"] as? String ?? ""
            throw unavailable(reason.isEmpty ? "FrontBoard returned no usable layout" : reason)
        }
        let candidates = monitors.filter { $0["available"] as? Bool == true && $0["geometry_available"] as? Bool == true }
        guard candidates.count == 1, let monitor = candidates.first,
              monitor["monitor_source"] as? String == "default_main",
              let bounds = rect(monitor["bounds"]), let reference = rect(monitor["reference_bounds"]),
              bounds.origin == .zero, reference.origin == .zero,
              let scale = number(monitor["point_scale"]), scale > 0,
              let displayID = number(monitor["display_id"]), displayID > 0, Int(exactly: displayID) != nil,
              let rawOrientation = number(monitor["interface_orientation"]),
              let orientation = [1.0: 0, 2.0: 180, 3.0: 270, 4.0: 90][rawOrientation] else {
            throw unavailable("FrontBoard display identity, bounds, scale or orientation is invalid or ambiguous")
        }
        if requireForeground {
            guard layout["foreground_bundle_verified"] as? Bool == true,
                  let bundle = layout["frontmost_bundle_id"] as? String, !bundle.isEmpty,
                  monitor["elements_available"] as? Bool == true,
                  let scenes = monitor["foreground_scenes"] as? [[String: Any]], scenes.count == 1,
                  let scene = scenes.first, scene["bundle_id"] as? String == bundle,
                  let frame = rect(scene["frame"]), let referenceFrame = rect(scene["reference_frame"]),
                  bounds.contains(frame), reference.contains(referenceFrame) else {
                throw unavailable("Foreground bundle or its unique scene could not be verified within the display bounds")
            }
        }
        do {
            return try InterfaceGeometry(
                width: bounds.width, height: bounds.height,
                referenceWidth: reference.width, referenceHeight: reference.height,
                scale: scale, orientation: orientation,
            )
        } catch {
            throw unavailable("Upright and reference geometry do not match the interface orientation")
        }
    }
}
