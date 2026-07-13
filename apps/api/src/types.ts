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

/** The type of external service backing a source='service' layer. */
export type ServiceType = "xyz" | "wms" | "wmts" | "wfs" | "arcgis" | "geojson";

/**
 * Config for a source='service' layer. Raster kinds (xyz/wms/wmts) carry a
 * ready-to-use MapLibre tile URL template (`url`) built server-side at add
 * time — the frontend never has to know how to construct a WMS GetMap query.
 * Vector kinds (wfs/arcgis) are metadata-only: their features were fetched
 * once and imported into `features`, so `url` isn't used for rendering.
 */
export interface ServiceConfig {
  type: ServiceType;
  url?: string;
  tileSize?: number;
  attribution?: string;
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
  source: "upload" | "buffer" | "intersect" | "service";
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
