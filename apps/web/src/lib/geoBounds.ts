import { Bbox, GeoFeatureCollection } from "../api/client";

// Collects every coordinate out of a FeatureCollection's geometries — only
// Point/LineString/Polygon are handled, matching MapCanvas's own initial
// "fit bounds once" effect: Multi* geometries never reach the client since
// normalizeFeatureArray (server-side, see lib/geo.ts) flattens them into
// individual simple features before storage.
function collectCoords(geom: { type: string; coordinates: unknown }, out: [number, number][]) {
  if (geom.type === "Point") out.push(geom.coordinates as [number, number]);
  else if (geom.type === "LineString") out.push(...(geom.coordinates as [number, number][]));
  else if (geom.type === "Polygon") (geom.coordinates as [number, number][][]).forEach((ring) => out.push(...ring));
}

// Used by the layer list's "zoom to layer" button (see LayerList.tsx /
// MapEditorPage.tsx) to compute where to fly the map for a given vector
// layer's features. Returns null for an empty layer — nothing to zoom to.
export function boundsFromFeatureCollection(fc: GeoFeatureCollection): Bbox | null {
  const coords: [number, number][] = [];
  fc.features.forEach((f) => collectCoords(f.geometry, coords));
  if (!coords.length) return null;
  const lons = coords.map((c) => c[0]);
  const lats = coords.map((c) => c[1]);
  return { west: Math.min(...lons), south: Math.min(...lats), east: Math.max(...lons), north: Math.max(...lats) };
}
