import Nbmap
import NbmapCoreNavigation
import UIKit

@available(iOS 13.0, *)
@MainActor
/// Renders the precise GeoJSON boundaries of installed offline regions on an SDK map.
///
/// Runtime style layers disappear whenever the map style reloads. The owning controller
/// must therefore call `refresh()` from `mapView(_:didFinishLoading:)` as well as when the
/// installed-region set changes.
final class DownloadedRegionMapOverlay {
    private weak var mapView: NGLMapView?
    private let sourceIdentifier: String
    private let fillLayerIdentifier: String
    private let lineLayerIdentifier: String
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()

    init(mapView: NGLMapView, identifierPrefix: String) {
        self.mapView = mapView
        sourceIdentifier = "\(identifierPrefix)-source"
        fillLayerIdentifier = "\(identifierPrefix)-fill"
        lineLayerIdentifier = "\(identifierPrefix)-line"
    }

    deinit {
        refreshTask?.cancel()
    }

    func refresh() {
        refreshTask?.cancel()
        let requestID = UUID()
        refreshID = requestID
        refreshTask = Task { [weak self] in
            do {
                // initializeOffline is idempotent and also retries a previous failed start.
                // waitUntilOfflineInitialized alone would not start an uninitialized engine.
                try await NBNavigation.initializeOffline()
                try Task.checkCancellation()
                // `true` may retrieve missing boundary detail. The returned polygon is more
                // accurate than boundaryBbox, which is suitable only for coarse camera focus.
                let boundaries = try await NBNavigation.getOfflineRegionBoundary(
                    fetchDetailIfMissing: true
                )
                try Task.checkCancellation()
                let geoJSON = Self.makeFeatureCollection(boundaries: boundaries)
                guard let self, self.refreshID == requestID else { return }
                self.refreshTask = nil
                self.apply(geoJSON: geoJSON)
            } catch is CancellationError {
                return
            } catch {
                // Ignore a stale completion from a refresh that has already been replaced.
                guard let self, self.refreshID == requestID else { return }
                self.refreshTask = nil
                // Keep map rendering usable when boundary metadata is temporarily unavailable.
                NSLog("Downloaded region overlay refresh failed: %@", error.localizedDescription)
            }
        }
    }

    func cancelRefresh() {
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func remove() {
        cancelRefresh()
        guard let style = mapView?.style else { return }
        removeLayers(from: style)
    }

    private func apply(geoJSON: String?) {
        guard let style = mapView?.style else { return }
        // Remove in reverse dependency order: layers reference the source and must be
        // detached before the source can safely be removed or replaced.
        removeLayers(from: style)
        guard let geoJSON,
              let data = geoJSON.data(using: .utf8),
              let shape = try? NGLShape(data: data, encoding: String.Encoding.utf8.rawValue)
        else { return }

        let source = NGLShapeSource(identifier: sourceIdentifier, shape: shape, options: nil)
        style.addSource(source)

        let overlayColor = UIColor.systemBlue
        let fillLayer = NGLFillStyleLayer(identifier: fillLayerIdentifier, source: source)
        fillLayer.fillColor = NSExpression(forConstantValue: overlayColor)
        fillLayer.fillOpacity = NSExpression(forConstantValue: 0.25)
        style.addLayer(fillLayer)

        let lineLayer = NGLLineStyleLayer(identifier: lineLayerIdentifier, source: source)
        lineLayer.lineColor = NSExpression(forConstantValue: overlayColor)
        lineLayer.lineWidth = NSExpression(forConstantValue: 2.0)
        style.addLayer(lineLayer)
    }

    private func removeLayers(from style: NGLStyle) {
        if let lineLayer = style.layer(withIdentifier: lineLayerIdentifier) {
            style.removeLayer(lineLayer)
        }
        if let fillLayer = style.layer(withIdentifier: fillLayerIdentifier) {
            style.removeLayer(fillLayer)
        }
        if let source = style.source(withIdentifier: sourceIdentifier) {
            style.removeSource(source)
        }
    }

    nonisolated private static func makeFeatureCollection(
        boundaries: [OfflineRegionBoundary]
    ) -> String? {
        // The SDK may return a FeatureCollection, a single Feature, or a bare geometry.
        // Normalize every supported representation into one source so the map needs only
        // one fill layer and one line layer regardless of installed-region count.
        var mergedFeatures: [[String: Any]] = []
        for boundary in boundaries where !boundary.geoJson.isEmpty {
            guard let data = boundary.geoJson.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data),
                  let object = root as? [String: Any],
                  let type = (object["type"] as? String)?.lowercased()
            else { continue }

            switch type {
            case "featurecollection":
                let features = object["features"] as? [[String: Any]] ?? []
                mergedFeatures.append(contentsOf: features.map {
                    featureWithRegionID($0, regionID: boundary.regionId)
                })
            case "feature":
                mergedFeatures.append(featureWithRegionID(object, regionID: boundary.regionId))
            default:
                mergedFeatures.append([
                    "type": "Feature",
                    "properties": ["region_id": boundary.regionId],
                    "geometry": object
                ])
            }
        }

        guard !mergedFeatures.isEmpty else { return nil }
        let featureCollection: [String: Any] = [
            "type": "FeatureCollection",
            "features": mergedFeatures
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: featureCollection) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func featureWithRegionID(
        _ feature: [String: Any],
        regionID: Int64
    ) -> [String: Any] {
        var result = feature
        var properties = result["properties"] as? [String: Any] ?? [:]
        properties["region_id"] = regionID
        result["properties"] = properties
        return result
    }
}
