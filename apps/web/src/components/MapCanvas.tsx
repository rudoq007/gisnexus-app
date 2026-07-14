import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";
import maplibregl, { LngLatBoundsLike, Map as MapLibreMap, MapLayerMouseEvent, MapMouseEvent } from "maplibre-gl";
import { Bbox, GeoFeature, GeoFeatureCollection, LayerDto } from "../api/client";

// A free, no-API-key raster basemap. Swap for a vector style + MapTiler/Stadia
// key in production for sharper rendering — see README "Basemap tiles".
const BASEMAP_STYLE: maplibregl.StyleSpecification = {
  version: 8,
  sources: {
    osm: {
      type: "raster",
      tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      tileSize: 256,
      attribution: "&copy; OpenStreetMap contributors",
    },
  },
  layers: [{ id: "osm", type: "raster", source: "osm" }],
};

interface Props {
  layers: LayerDto[];
  featuresByLayer: Record<string, GeoFeatureCollection>;
  viewState: { center: [number, number]; zoom: number };
  onViewStateChange: (v: { center: [number, number]; zoom: number }) => void;
  onFeatureClick: (layer: LayerDto, feature: GeoFeature, lngLat: [number, number]) => void;
  // Current viewport bounds, reported on every move — the terrain tools
  // (Hillshade, ...) run against "whatever's on screen right now" rather
  // than a layer, so they need this and there's nowhere else to get it.
  onBoundsChange?: (bounds: { west: number; south: number; east: number; north: number }) => void;
  // Fires on every map click, regardless of whether it landed on a feature —
  // used by the Watershed tool's "pick a pour point" flow (see
  // TerrainPanel.tsx / MapEditorPage.tsx). Most of the time this is a no-op
  // in the parent; only meaningful while pour-point picking is active.
  onMapClick?: (lngLat: [number, number]) => void;
  // When set, shows a marker at this position — currently just the chosen
  // watershed pour point, so the user can see where they clicked.
  pickMarker?: [number, number] | null;
}

// Imperative actions the parent (MapEditorPage) can trigger directly, for
// things that are one-off commands rather than state the map should keep
// reacting to — e.g. "zoom to this specific layer's extent" doesn't fit the
// usual prop-driven-by-state pattern (the same bounds could be requested
// twice in a row, which wouldn't re-trigger a useEffect keyed on that prop).
export interface MapCanvasHandle {
  fitToBounds: (bbox: Bbox) => void;
}

function sourceIdFor(layerId: string) {
  return `src-${layerId}`;
}
function fillLayerIdFor(layerId: string) {
  return `lyr-${layerId}-fill`;
}
function lineLayerIdFor(layerId: string) {
  return `lyr-${layerId}-line`;
}
function rasterLayerIdFor(layerId: string) {
  return `lyr-${layerId}-raster`;
}

const MapCanvas = forwardRef<MapCanvasHandle, Props>(function MapCanvas(
  { layers, featuresByLayer, viewState, onViewStateChange, onFeatureClick, onBoundsChange, onMapClick, pickMarker },
  ref
) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const loadedRef = useRef(false);
  const markerRef = useRef<maplibregl.Marker | null>(null);

  useImperativeHandle(ref, () => ({
    fitToBounds(bbox: Bbox) {
      const map = mapRef.current;
      if (!map) return;
      map.fitBounds(
        [
          [bbox.west, bbox.south],
          [bbox.east, bbox.north],
        ],
        { padding: 80, maxZoom: 18, duration: 600 }
      );
    },
  }));

  // The map-init effect below only runs once (empty deps), so it captures
  // whatever onMapClick was passed at mount time. Unlike onBoundsChange/
  // onFeatureClick (which just call stable setState functions), the pour-
  // point picker's onMapClick needs to see fresh "am I in picking mode right
  // now" state on every click — so it's read through a ref that's kept
  // current every render, rather than closed over directly.
  const onMapClickRef = useRef(onMapClick);
  onMapClickRef.current = onMapClick;

  function reportBounds(map: MapLibreMap) {
    if (!onBoundsChange) return;
    const b = map.getBounds();
    onBoundsChange({ west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth() });
  }

  // Initialize map once.
  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: BASEMAP_STYLE,
      center: viewState.center,
      zoom: viewState.zoom,
    });
    map.addControl(new maplibregl.NavigationControl(), "bottom-left");
    map.on("load", () => {
      loadedRef.current = true;
      syncLayers();
      reportBounds(map);
    });
    map.on("moveend", () => {
      const c = map.getCenter();
      onViewStateChange({ center: [c.lng, c.lat], zoom: map.getZoom() });
      reportBounds(map);
    });
    map.on("click", (e: MapMouseEvent) => {
      onMapClickRef.current?.([e.lngLat.lng, e.lngLat.lat]);
    });
    mapRef.current = map;
    return () => {
      map.remove();
      mapRef.current = null;
      loadedRef.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Show/move/hide the pour-point marker as it's picked, changed, or cleared.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (pickMarker) {
      if (!markerRef.current) {
        markerRef.current = new maplibregl.Marker({ color: "#22d3ee" }).setLngLat(pickMarker).addTo(map);
      } else {
        markerRef.current.setLngLat(pickMarker);
      }
    } else if (markerRef.current) {
      markerRef.current.remove();
      markerRef.current = null;
    }
  }, [pickMarker]);

  function syncLayers() {
    const map = mapRef.current;
    if (!map || !loadedRef.current) return;

    const currentLayerIds = new Set(layers.map((l) => l.id));

    // Remove map layers/sources for GISNEXUS layers that no longer exist
    // (deleted, or filtered out by a visibility toggle).
    const style = map.getStyle();
    for (const styleLayer of style.layers || []) {
      const match = /^lyr-(.+)-(fill|line|raster)$/.exec(styleLayer.id);
      if (match && !currentLayerIds.has(match[1])) {
        if (map.getLayer(styleLayer.id)) map.removeLayer(styleLayer.id);
      }
    }
    for (const srcId of Object.keys(style.sources || {})) {
      const match = /^src-(.+)$/.exec(srcId);
      if (match && !currentLayerIds.has(match[1]) && map.getSource(srcId)) {
        map.removeSource(srcId);
      }
    }

    for (const layer of layers) {
      const srcId = sourceIdFor(layer.id);

      // Raster layers come in two flavors:
      //  - service.type xyz/wms/wmts: live tiles from a tile URL template
      //    built server-side — no featuresByLayer entry, no click handler.
      //  - service.type 'image': a single georeferenced image produced
      //    server-side by a terrain tool (Hillshade, ...) — same idea, just
      //    a bounded ImageSource instead of a tiled RasterSource.
      if (layer.kind === "raster") {
        if (!layer.service?.url) continue;
        if (!map.getSource(srcId)) {
          if (layer.service.type === "image" && layer.service.coordinates) {
            map.addSource(srcId, {
              type: "image",
              url: layer.service.url,
              coordinates: layer.service.coordinates as [[number, number], [number, number], [number, number], [number, number]],
            });
          } else {
            map.addSource(srcId, {
              type: "raster",
              tiles: [layer.service.url],
              tileSize: layer.service.tileSize || 256,
              attribution: layer.service.attribution,
            });
          }
        }
        const rasterId = rasterLayerIdFor(layer.id);
        if (!map.getLayer(rasterId)) {
          // Newly-added basemap/imagery layers should sit below any existing
          // GISNEXUS layers (not on top, covering the data) — insert just
          // below the first custom layer currently in the style, if any.
          const firstCustomLayer = (map.getStyle().layers || []).find((l) => l.id.startsWith("lyr-"));
          map.addLayer(
            { id: rasterId, type: "raster", source: srcId, paint: { "raster-opacity": layer.style.opacity } },
            firstCustomLayer?.id
          );
        } else {
          map.setPaintProperty(rasterId, "raster-opacity", layer.style.opacity);
        }
        continue;
      }

      const fc = featuresByLayer[layer.id];
      if (!fc) continue;
      const existingSource = map.getSource(srcId) as maplibregl.GeoJSONSource | undefined;
      if (existingSource) {
        existingSource.setData(fc as unknown as any);
      } else {
        map.addSource(srcId, { type: "geojson", data: fc as unknown as any });
      }

      if (layer.geom_type === "Point") {
        const id = fillLayerIdFor(layer.id);
        if (!map.getLayer(id)) {
          map.addLayer({
            id,
            type: "circle",
            source: srcId,
            paint: {
              "circle-radius": layer.style.size,
              "circle-color": layer.style.color,
              "circle-opacity": layer.style.opacity,
              "circle-stroke-color": "#ffffff",
              "circle-stroke-width": 1.4,
            },
          });
          attachClickHandler(id, layer);
        } else {
          map.setPaintProperty(id, "circle-radius", layer.style.size);
          map.setPaintProperty(id, "circle-color", layer.style.color);
          map.setPaintProperty(id, "circle-opacity", layer.style.opacity);
        }
      } else if (layer.geom_type === "LineString") {
        const id = lineLayerIdFor(layer.id);
        if (!map.getLayer(id)) {
          map.addLayer({
            id,
            type: "line",
            source: srcId,
            layout: { "line-cap": "round", "line-join": "round" },
            paint: { "line-color": layer.style.color, "line-width": layer.style.size, "line-opacity": layer.style.opacity },
          });
          attachClickHandler(id, layer);
        } else {
          map.setPaintProperty(id, "line-color", layer.style.color);
          map.setPaintProperty(id, "line-width", layer.style.size);
          map.setPaintProperty(id, "line-opacity", layer.style.opacity);
        }
      } else if (layer.geom_type === "Polygon") {
        const fillId = fillLayerIdFor(layer.id);
        const lineId = lineLayerIdFor(layer.id);
        if (!map.getLayer(fillId)) {
          map.addLayer({
            id: fillId,
            type: "fill",
            source: srcId,
            paint: { "fill-color": layer.style.color, "fill-opacity": layer.style.opacity },
          });
          map.addLayer({
            id: lineId,
            type: "line",
            source: srcId,
            paint: { "line-color": layer.style.color, "line-width": Math.max(layer.style.size, 1) },
          });
          attachClickHandler(fillId, layer);
        } else {
          map.setPaintProperty(fillId, "fill-color", layer.style.color);
          map.setPaintProperty(fillId, "fill-opacity", layer.style.opacity);
          map.setPaintProperty(lineId, "line-color", layer.style.color);
        }
      }
    }
  }

  function attachClickHandler(mapLayerId: string, layer: LayerDto) {
    const map = mapRef.current;
    if (!map) return;
    map.on("click", mapLayerId, (e: MapLayerMouseEvent) => {
      const feature = e.features?.[0];
      if (!feature) return;
      onFeatureClick(layer, feature as unknown as GeoFeature, [e.lngLat.lng, e.lngLat.lat]);
    });
    map.on("mouseenter", mapLayerId, () => (map.getCanvas().style.cursor = "pointer"));
    map.on("mouseleave", mapLayerId, () => (map.getCanvas().style.cursor = ""));
  }

  // Re-sync whenever layers/features change.
  useEffect(() => {
    syncLayers();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [layers, featuresByLayer]);

  // Fit bounds once, the first time we have any features.
  const fitDoneRef = useRef(false);
  useEffect(() => {
    const map = mapRef.current;
    if (!map || fitDoneRef.current) return;
    const allCoords: [number, number][] = [];
    const collectCoords = (geom: { type: string; coordinates: unknown }) => {
      if (geom.type === "Point") allCoords.push(geom.coordinates as [number, number]);
      else if (geom.type === "LineString") allCoords.push(...(geom.coordinates as [number, number][]));
      else if (geom.type === "Polygon") (geom.coordinates as [number, number][][]).forEach((r) => allCoords.push(...r));
    };
    Object.values(featuresByLayer).forEach((fc) => fc.features.forEach((f) => collectCoords(f.geometry)));
    if (!allCoords.length) return;

    const lons = allCoords.map((c) => c[0]);
    const lats = allCoords.map((c) => c[1]);
    const bounds: LngLatBoundsLike = [
      [Math.min(...lons), Math.min(...lats)],
      [Math.max(...lons), Math.max(...lats)],
    ];
    map.fitBounds(bounds, { padding: 60, maxZoom: 15, duration: 400 });
    fitDoneRef.current = true;
  }, [featuresByLayer]);

  return <div ref={containerRef} className="map-canvas-el" />;
});

export default MapCanvas;
