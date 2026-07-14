export interface User {
  id: string;
  email: string;
  name: string | null;
  password_hash: string;
  created_at: string;
}

export type MapVisibility = "private" | "unlisted" | "public";

export interface MapRow {
  id: string;
  owner_id: string;
  name: string;
  description: string | null;
  visibility: MapVisibility;
  share_token: string | null;
  view_state: { center: [number, number]; zoom: number };
  components: unknown[];
  created_at: string;
  updated_at: string;
}

export type GeomType = "Point" | "LineString" | "Polygon";

export type LayerKind = "vector" | "raster";

/**
 * The type of external service backing a source='service' layer, plus
 * 'image' — a single georeferenced raster produced server-side (terrain
 * analysis output: hillshade, slope, aspect, ...) rather than fetched from a
 * third party. It reuses the same 'raster' layer kind and `service` column
 * as xyz/wms/wmts; the frontend renders it with a MapLibre ImageSource
 * (bounded, single image) instead of a tiled RasterSource.
 */
export type ServiceType = "xyz" | "wms" | "wmts" | "wfs" | "arcgis" | "geojson" | "image";

/**
 * Config for a source='service' or source='terrain' layer. Tiled raster
 * kinds (xyz/wms/wmts) carry a ready-to-use MapLibre tile URL template
 * (`url`) built server-side at add time. The 'image' kind (terrain analysis
 * output) carries a single image `url` (currently a data: URL — see
 * lib/terrain.ts) plus `coordinates`, its four corners in MapLibre
 * ImageSource order: [[west,north],[east,north],[east,south],[west,south]].
 * Vector kinds (wfs/arcgis) are metadata-only: their features were fetched
 * once and imported into `features`, so `url` isn't used for rendering.
 */
export interface ServiceConfig {
  type: ServiceType;
  url?: string;
  tileSize?: number;
  attribution?: string;
  coordinates?: [number, number][];
  raw: Record<string, string | number | boolean>;
}

export interface LayerRow {
  id: string;
  map_id: string;
  name: string;
  kind: LayerKind;
  geom_type: GeomType | null;
  style: { color: string; opacity: number; size: number };
  popup_fields: string[];
  source: "upload" | "buffer" | "intersect" | "service" | "terrain";
  service: ServiceConfig | null;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export type MapRole = "owner" | "editor" | "viewer" | null;

// Minimal shape we normalize any uploaded geometry into before insert.
export interface NormalizedFeature {
  geometry: { type: GeomType; coordinates: unknown };
  properties: Record<string, unknown>;
}
