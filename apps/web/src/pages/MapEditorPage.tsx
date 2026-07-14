import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { api, Bbox, GeoFeature, GeoFeatureCollection, LayerDto, MapDto, MapVisibility } from "../api/client";
import MapCanvas, { MapCanvasHandle } from "../components/MapCanvas";
import LayerList from "../components/LayerList";
import StylePanel from "../components/StylePanel";
import PopupConfigPanel from "../components/PopupConfigPanel";
import UploadButton from "../components/UploadButton";
import DataTable from "../components/DataTable";
import DashboardChart from "../components/DashboardChart";
import AnalysisPanel from "../components/AnalysisPanel";
import TerrainPanel from "../components/TerrainPanel";
import AddDataPanel from "../components/AddDataPanel";
import PrintMapModal from "../components/PrintMapModal";
import { CatalogEntry } from "../lib/serviceCatalog";
import { downloadRasterLayer, downloadVectorLayer } from "../lib/downloadLayer";
import { boundsFromFeatureCollection } from "../lib/geoBounds";

type BottomTab = "table" | "dashboard" | "analysis" | "terrain";

export default function MapEditorPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const mapCanvasRef = useRef<MapCanvasHandle>(null);

  const [map, setMap] = useState<MapDto | null>(null);
  const [role, setRole] = useState<string>("viewer");
  const [layers, setLayers] = useState<LayerDto[]>([]);
  const [featuresByLayer, setFeaturesByLayer] = useState<Record<string, GeoFeatureCollection>>({});
  const [visibleIds, setVisibleIds] = useState<Set<string>>(new Set());
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [tab, setTab] = useState<BottomTab>("table");
  const [bounds, setBounds] = useState<Bbox | null>(null);
  const [pourPoint, setPourPoint] = useState<{ lon: number; lat: number } | null>(null);
  const [pickingPourPoint, setPickingPourPoint] = useState(false);
  const [popup, setPopup] = useState<{ layer: LayerDto; feature: GeoFeature; lngLat: [number, number] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [shareOpen, setShareOpen] = useState(false);
  const [printOpen, setPrintOpen] = useState(false);
  const [addDataOpen, setAddDataOpen] = useState(false);

  const canEdit = role === "owner" || role === "editor";

  const loadMap = useCallback(async () => {
    if (!id) return;
    try {
      const { map, layers, role } = await api.getMap(id);
      setMap(map);
      setLayers(layers);
      setRole(role);
      setVisibleIds(new Set(layers.map((l) => l.id)));
      if (!selectedId && layers.length) setSelectedId(layers[0].id);
      // Fetch features for every vector layer (fine for MVP-scale datasets).
      // Raster (service) layers render straight from their tile URL — they
      // have no rows in `features`, so there's nothing to fetch for them.
      const entries = await Promise.all(
        layers.filter((l) => l.kind !== "raster").map(async (l) => [l.id, await api.getLayerFeatures(l.id)] as const)
      );
      setFeaturesByLayer(Object.fromEntries(entries));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Couldn't load this map.");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  useEffect(() => {
    loadMap();
  }, [loadMap]);

  const selectedLayer = layers.find((l) => l.id === selectedId) || null;
  const visibleLayers = layers.filter((l) => visibleIds.has(l.id));

  async function handleUpload(file: File) {
    if (!id) return;
    setError(null);
    setNotice(null);
    try {
      const { featureCount, skipped, warning } = await api.uploadLayer(id, file);
      await loadMap();
      const notes: string[] = [`Loaded ${featureCount} feature${featureCount === 1 ? "" : "s"}.`];
      if (skipped) notes.push(`${skipped} row${skipped === 1 ? "" : "s"} skipped (unsupported or invalid geometry).`);
      if (warning) notes.push(warning);
      setNotice(notes.join(" "));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Upload failed.");
    }
  }

  // Called by AddDataPanel per-item; errors are intentionally left to
  // propagate so the panel can show them inline next to the item that failed
  // rather than as a page-level banner.
  async function handleAddService(entry: CatalogEntry) {
    if (!id) return;
    setError(null);
    const { featureCount, skipped } = await api.addServiceLayer(id, {
      name: entry.name,
      serviceType: entry.serviceType,
      fields: entry.fields,
    });
    await loadMap();
    if (entry.serviceType === "wfs" || entry.serviceType === "arcgis" || entry.serviceType === "geojson") {
      const notes = [`Added "${entry.name}" — imported ${featureCount} feature${featureCount === 1 ? "" : "s"}.`];
      if (skipped) notes.push(`${skipped} skipped (unsupported or invalid geometry).`);
      setNotice(notes.join(" "));
    } else {
      setNotice(`Added "${entry.name}" as a basemap layer.`);
    }
  }

  async function handleStyleChange(style: Partial<LayerDto["style"]>) {
    if (!selectedLayer) return;
    const mergedStyle = { ...selectedLayer.style, ...style };
    const updated = { ...selectedLayer, style: mergedStyle };
    setLayers((prev) => prev.map((l) => (l.id === updated.id ? updated : l)));
    await api.updateLayer(selectedLayer.id, { style: mergedStyle });
  }

  async function handlePopupFieldsChange(fields: string[]) {
    if (!selectedLayer) return;
    setLayers((prev) => prev.map((l) => (l.id === selectedLayer.id ? { ...l, popup_fields: fields } : l)));
    await api.updateLayer(selectedLayer.id, { popup_fields: fields });
  }

  async function handleDeleteLayer(layerId: string) {
    await api.deleteLayer(layerId);
    if (selectedId === layerId) setSelectedId(null);
    await loadMap();
  }

  // Vector layers already have their full feature set in featuresByLayer
  // (fetched up front by loadMap), so that path is synchronous and can't
  // fail beyond "not loaded yet". Raster (image) layers ship the PNG plus a
  // world file (see lib/downloadLayer.ts) — errors there (e.g. the image
  // failing to decode) are surfaced via the same error banner as everything
  // else rather than silently swallowed.
  function handleDownloadLayer(layerId: string) {
    const layer = layers.find((l) => l.id === layerId);
    if (!layer) return;
    setError(null);
    if (layer.kind === "raster") {
      downloadRasterLayer(layer).catch((err) =>
        setError(err instanceof Error ? err.message : "Couldn't download this layer.")
      );
    } else {
      const fc = featuresByLayer[layerId];
      if (!fc) {
        setError("This layer's features haven't finished loading yet — try again in a moment.");
        return;
      }
      downloadVectorLayer(layer, fc);
    }
  }

  // "Zoom to layer" — flies the map to a layer's extent so it's findable
  // without manual panning/zooming (this matters most for small results
  // like a Watershed polygon, which can be a tiny fraction of the current
  // view and easy to lose track of). Raster (image) layers already carry
  // their bounds in service.coordinates; vector layers' bounds are derived
  // from their already-loaded features. Uses MapCanvas's imperative handle
  // rather than a prop, since the same bounds might be requested twice in a
  // row (re-clicking the same layer), which wouldn't re-trigger a
  // useEffect keyed on a prop that hadn't changed.
  function handleZoomToLayer(layerId: string) {
    const layer = layers.find((l) => l.id === layerId);
    if (!layer) return;
    setError(null);
    if (layer.kind === "raster") {
      const coords = layer.service?.coordinates;
      if (!coords || coords.length < 4) {
        setError("This layer doesn't have a fixed extent to zoom to.");
        return;
      }
      const [west, north] = coords[0];
      const [east] = coords[1];
      const [, south] = coords[2];
      mapCanvasRef.current?.fitToBounds({ west, south, east, north });
    } else {
      const fc = featuresByLayer[layerId];
      const bounds = fc ? boundsFromFeatureCollection(fc) : null;
      if (!bounds) {
        setError("This layer has no features to zoom to yet.");
        return;
      }
      mapCanvasRef.current?.fitToBounds(bounds);
    }
  }

  async function handleShare(visibility: MapVisibility) {
    if (!id) return;
    const { map } = await api.shareMap(id, visibility);
    setMap(map);
  }

  function handleMapClick(lngLat: [number, number]) {
    if (!pickingPourPoint) return;
    setPourPoint({ lon: lngLat[0], lat: lngLat[1] });
    setPickingPourPoint(false);
  }

  const selectedFeatures = selectedLayer ? featuresByLayer[selectedLayer.id] || null : null;
  const allFields: string[] = Array.from(
    new Set((selectedFeatures?.features || []).flatMap((f) => Object.keys(f.properties || {})))
  );

  if (!map) {
    return <div className="page-loading">{error || "Loading map…"}</div>;
  }

  return (
    <div className="editor-page">
      <header className="app-header">
        <div className="logo" onClick={() => navigate("/maps")} style={{ cursor: "pointer" }}>
          GISNEXUS
        </div>
        <div className="map-title">{map.name}</div>
        <div className="header-actions">
          <UploadButton onUpload={handleUpload} />
          {canEdit && (
            <button className="btn" onClick={() => setAddDataOpen(true)}>
              🌐 Add data
            </button>
          )}
          {role === "owner" && (
            <button className="btn" onClick={() => setShareOpen(true)}>
              Share
            </button>
          )}
        </div>
      </header>

      {error && <div className="banner-error">{error}</div>}
      {notice && (
        <div className="banner-notice">
          {notice}
          <button onClick={() => setNotice(null)}>✕</button>
        </div>
      )}
      {pickingPourPoint && (
        <div className="banner-notice">
          Click anywhere on the map to set the watershed pour point.
          <button onClick={() => setPickingPourPoint(false)}>✕</button>
        </div>
      )}

      <div className="app">
        <aside className="sidebar">
          <div className="sidebar-section">
            <h4>Layers</h4>
            <LayerList
              layers={layers}
              visibleIds={visibleIds}
              selectedId={selectedId}
              canEdit={canEdit}
              onToggleVisible={(lid) =>
                setVisibleIds((prev) => {
                  const next = new Set(prev);
                  next.has(lid) ? next.delete(lid) : next.add(lid);
                  return next;
                })
              }
              onSelect={setSelectedId}
              onDelete={handleDeleteLayer}
              onDownload={handleDownloadLayer}
              onZoomToLayer={handleZoomToLayer}
            />
          </div>
          {selectedLayer && canEdit && selectedLayer.kind === "raster" ? (
            <div className="sidebar-section">
              <h4>Layer — {selectedLayer.name}</h4>
              <div className="field-row">
                <label>Opacity</label>
                <input
                  type="range"
                  min={0.1}
                  max={1}
                  step={0.05}
                  value={selectedLayer.style.opacity}
                  onChange={(e) => handleStyleChange({ opacity: parseFloat(e.target.value) })}
                />
                <span className="field-val">{Math.round(selectedLayer.style.opacity * 100)}%</span>
              </div>
              {selectedLayer.service?.attribution && <p className="muted-sm">{selectedLayer.service.attribution}</p>}
            </div>
          ) : (
            selectedLayer &&
            canEdit && (
              <>
                <StylePanel layer={selectedLayer} onChange={handleStyleChange} />
                <PopupConfigPanel allFields={allFields} selectedFields={selectedLayer.popup_fields} onChange={handlePopupFieldsChange} />
              </>
            )
          )}
        </aside>

        <div className="map-wrap">
          <MapCanvas
            ref={mapCanvasRef}
            layers={visibleLayers}
            featuresByLayer={featuresByLayer}
            viewState={map.view_state}
            onViewStateChange={(v) => api.updateMap(map.id, { view_state: v }).catch(() => {})}
            onFeatureClick={(layer, feature, lngLat) => setPopup({ layer, feature, lngLat })}
            onBoundsChange={setBounds}
            onMapClick={handleMapClick}
            pickMarker={pourPoint ? [pourPoint.lon, pourPoint.lat] : null}
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
      </div>

      <div className="bottom-panel">
        <div className="bottom-tabs">
          <button className={tab === "table" ? "active" : ""} onClick={() => setTab("table")}>
            Data table
          </button>
          <button className={tab === "dashboard" ? "active" : ""} onClick={() => setTab("dashboard")}>
            Dashboard
          </button>
          <button className={tab === "analysis" ? "active" : ""} onClick={() => setTab("analysis")}>
            Spatial analysis
          </button>
          <button className={tab === "terrain" ? "active" : ""} onClick={() => setTab("terrain")}>
            Terrain
          </button>
        </div>
        <div className="bottom-content">
          {tab === "terrain" ? (
            canEdit ? (
              <TerrainPanel
                mapId={id!}
                bounds={bounds}
                onCreated={loadMap}
                pourPoint={pourPoint}
                pickingPourPoint={pickingPourPoint}
                onStartPickPourPoint={() => setPickingPourPoint(true)}
                onClearPourPoint={() => {
                  setPourPoint(null);
                  setPickingPourPoint(false);
                }}
              />
            ) : (
              <div className="empty-note">You need edit access to run terrain analysis.</div>
            )
          ) : !selectedLayer ? (
            <div className="empty-note">Select a layer to get started.</div>
          ) : selectedLayer.kind === "raster" ? (
            <div className="empty-note">
              "{selectedLayer.name}" is a basemap/imagery layer — there's no feature data to show in the table,
              dashboard, or spatial analysis tools. Use the opacity slider in the sidebar to adjust it.
            </div>
          ) : tab === "table" ? (
            <DataTable data={selectedFeatures} />
          ) : tab === "dashboard" ? (
            <DashboardChart layer={selectedLayer} data={selectedFeatures} />
          ) : canEdit ? (
            <AnalysisPanel layer={selectedLayer} allLayers={layers.filter((l) => l.kind !== "raster")} onCreated={loadMap} />
          ) : (
            <div className="empty-note">You need edit access to run spatial analysis.</div>
          )}
        </div>
      </div>

      {shareOpen && (
        <div className="modal-backdrop" onClick={() => setShareOpen(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h3>Share "{map.name}"</h3>
            <p className="muted-sm">Anyone with the link can view this map if visibility is set to Unlisted or Public.</p>
            <div className="share-options">
              {(["private", "unlisted", "public"] as MapVisibility[]).map((v) => (
                <button key={v} className={"btn" + (map.visibility === v ? " btn-primary" : "")} onClick={() => handleShare(v)}>
                  {v}
                </button>
              ))}
            </div>
            {map.visibility !== "private" && map.share_token && (
              <div className="share-link">
                <code>{`${window.location.origin}/share/${map.share_token}`}</code>
                <button className="btn btn-sm" onClick={() => navigator.clipboard.writeText(`${window.location.origin}/share/${map.share_token}`)}>
                  Copy
                </button>
              </div>
            )}
            <button
              className="btn"
              style={{ marginTop: 16, width: "100%" }}
              onClick={() => {
                setShareOpen(false);
                setPrintOpen(true);
              }}
            >
              🖨️ Print map as PDF
            </button>
            <button className="btn" style={{ marginTop: 10 }} onClick={() => setShareOpen(false)}>
              Close
            </button>
          </div>
        </div>
      )}

      {printOpen && (
        <PrintMapModal
          map={map}
          layers={visibleLayers}
          featuresByLayer={featuresByLayer}
          shareUrl={map.visibility !== "private" && map.share_token ? `${window.location.origin}/share/${map.share_token}` : null}
          onClose={() => setPrintOpen(false)}
        />
      )}

      {addDataOpen && <AddDataPanel onAdd={handleAddService} onClose={() => setAddDataOpen(false)} />}
    </div>
  );
}
