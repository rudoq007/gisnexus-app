import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { api, GeoFeature, GeoFeatureCollection, LayerDto, MapDto } from "../api/client";
import MapCanvas from "../components/MapCanvas";
import PrintMapModal from "../components/PrintMapModal";

export default function SharedMapPage() {
  const { token } = useParams<{ token: string }>();
  const [map, setMap] = useState<MapDto | null>(null);
  const [layers, setLayers] = useState<LayerDto[]>([]);
  const [featuresByLayer, setFeaturesByLayer] = useState<Record<string, GeoFeatureCollection>>({});
  const [popup, setPopup] = useState<{ layer: LayerDto; feature: GeoFeature } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [printOpen, setPrintOpen] = useState(false);

  useEffect(() => {
    if (!token) return;
    api
      .getSharedMap(token)
      .then(async ({ map, layers }) => {
        setMap(map);
        setLayers(layers);
        // Raster (service) layers render straight from their tile URL — no
        // features to fetch for them (see MapEditorPage for the same filter).
        const entries = await Promise.all(
          layers.filter((l) => l.kind !== "raster").map(async (l) => [l.id, await api.getLayerFeatures(l.id)] as const)
        );
        setFeaturesByLayer(Object.fromEntries(entries));
      })
      .catch((err) => setError(err instanceof Error ? err.message : "This map isn't available."));
  }, [token]);

  if (error) return <div className="page-loading">{error}</div>;
  if (!map) return <div className="page-loading">Loading map…</div>;

  return (
    <div className="shared-page">
      <header className="app-header">
        <div className="logo">GISNEXUS</div>
        <div className="map-title">{map.name}</div>
        <div className="header-actions">
          <button className="btn" onClick={() => setPrintOpen(true)}>
            🖨️ Print as PDF
          </button>
          <span className="badge">Read-only</span>
        </div>
      </header>
      <div className="map-wrap shared-map-wrap">
        <MapCanvas
          layers={layers}
          featuresByLayer={featuresByLayer}
          viewState={map.view_state}
          onViewStateChange={() => {}}
          onFeatureClick={(layer, feature) => setPopup({ layer, feature })}
        />
        {popup && (
          <div className="map-popup" onClick={() => setPopup(null)}>
            <div className="popup-card-inline" onClick={(e) => e.stopPropagation()}>
              <div className="pt">
                <span>{popup.layer.name}</span>
                <button onClick={() => setPopup(null)}>✕</button>
              </div>
              {(popup.layer.popup_fields.length ? popup.layer.popup_fields : Object.keys(popup.feature.properties).slice(0, 4)).map(
                (k) => (
                  <div className="prow" key={k}>
                    <span>{k}</span>
                    <b>{String(popup.feature.properties[k] ?? "—")}</b>
                  </div>
                )
              )}
            </div>
          </div>
        )}
      </div>

      {printOpen && (
        <PrintMapModal
          map={map}
          layers={layers}
          featuresByLayer={featuresByLayer}
          shareUrl={window.location.href}
          onClose={() => setPrintOpen(false)}
        />
      )}
    </div>
  );
}
