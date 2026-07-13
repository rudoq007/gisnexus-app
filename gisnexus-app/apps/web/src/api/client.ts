const API_URL = import.meta.env.VITE_API_URL || "http://localhost:4000";
const TOKEN_KEY = "gisnexus_token";

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}
export function setToken(token: string | null) {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

export class ApiClientError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = { ...(options.headers as Record<string, string>) };
  if (!(options.body instanceof FormData)) headers["Content-Type"] = "application/json";
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`${API_URL}${path}`, { ...options, headers });
  if (res.status === 204) return undefined as T;

  const isJson = res.headers.get("content-type")?.includes("application/json");
  const body = isJson ? await res.json() : await res.text();

  if (!res.ok) {
    const message = isJson && body?.error ? body.error : `Request failed (${res.status})`;
    throw new ApiClientError(res.status, message);
  }
  return body as T;
}

// ---------------------------------------------------------------------------
// Types (mirrors apps/api/src/types.ts)
// ---------------------------------------------------------------------------
export interface User {
  id: string;
  email: string;
  name: string | null;
}
export type MapVisibility = "private" | "unlisted" | "public";
export interface MapDto {
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
  role?: string;
}
export type GeomType = "Point" | "LineString" | "Polygon";
export type LayerKind = "vector" | "raster";
export type ServiceType = "xyz" | "wms" | "wmts" | "wfs" | "arcgis" | "geojson";
export interface ServiceConfig {
  type: ServiceType;
  url?: string;
  tileSize?: number;
  attribution?: string;
  raw: Record<string, string | number | boolean>;
}
export interface LayerDto {
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
}
export interface AggregateBar {
  label: string;
  value: number;
}

// Minimal GeoJSON typing so we don't need an extra @types/geojson dependency.
export interface GeoFeature {
  type: "Feature";
  id?: string;
  geometry: { type: string; coordinates: unknown };
  properties: Record<string, unknown>;
}
export interface GeoFeatureCollection {
  type: "FeatureCollection";
  features: GeoFeature[];
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------
export const api = {
  register: (email: string, password: string, name?: string) =>
    request<{ token: string; user: User }>("/api/auth/register", { method: "POST", body: JSON.stringify({ email, password, name }) }),
  login: (email: string, password: string) =>
    request<{ token: string; user: User }>("/api/auth/login", { method: "POST", body: JSON.stringify({ email, password }) }),
  me: () => request<{ user: User }>("/api/auth/me"),

  // Maps
  listMaps: () => request<{ maps: MapDto[] }>("/api/maps"),
  createMap: (name: string, description?: string) =>
    request<{ map: MapDto }>("/api/maps", { method: "POST", body: JSON.stringify({ name, description }) }),
  getMap: (id: string) => request<{ map: MapDto; layers: LayerDto[]; role: string }>(`/api/maps/${id}`),
  updateMap: (id: string, patch: Partial<Pick<MapDto, "name" | "description" | "view_state" | "components">>) =>
    request<{ map: MapDto }>(`/api/maps/${id}`, { method: "PATCH", body: JSON.stringify(patch) }),
  deleteMap: (id: string) => request<void>(`/api/maps/${id}`, { method: "DELETE" }),
  shareMap: (id: string, visibility: MapVisibility, regenerateToken?: boolean) =>
    request<{ map: MapDto }>(`/api/maps/${id}/share`, { method: "POST", body: JSON.stringify({ visibility, regenerateToken }) }),
  addCollaborator: (id: string, email: string, role: "editor" | "viewer") =>
    request<{ ok: true }>(`/api/maps/${id}/collaborators`, { method: "POST", body: JSON.stringify({ email, role }) }),

  // Layers
  uploadLayer: (mapId: string, file: File, name?: string) => {
    const form = new FormData();
    form.append("file", file);
    if (name) form.append("name", name);
    return request<{ layer: LayerDto; featureCount: number; skipped: number; warning?: string }>(`/api/maps/${mapId}/layers/upload`, {
      method: "POST",
      body: form,
    });
  },
  getLayerFeatures: (id: string) => request<GeoFeatureCollection>(`/api/layers/${id}/features`),
  addServiceLayer: (mapId: string, payload: { name: string; serviceType: ServiceType; fields: Record<string, string | number | boolean> }) =>
    request<{ layer: LayerDto; featureCount: number; skipped: number }>(`/api/maps/${mapId}/layers/service`, {
      method: "POST",
      body: JSON.stringify(payload),
    }),
  updateLayer: (id: string, patch: Partial<Pick<LayerDto, "name" | "style" | "popup_fields" | "sort_order">>) =>
    request<{ layer: LayerDto }>(`/api/layers/${id}`, { method: "PATCH", body: JSON.stringify(patch) }),
  deleteLayer: (id: string) => request<void>(`/api/layers/${id}`, { method: "DELETE" }),

  // Analysis
  bufferLayer: (id: string, distanceMeters: number, name?: string) =>
    request<{ layer: LayerDto; featureCount: number }>(`/api/layers/${id}/buffer`, {
      method: "POST",
      body: JSON.stringify({ distanceMeters, name }),
    }),
  intersectLayers: (id: string, otherLayerId: string, name?: string) =>
    request<{ layer: LayerDto; featureCount: number }>(`/api/layers/${id}/intersects`, {
      method: "POST",
      body: JSON.stringify({ otherLayerId, name }),
    }),

  // Dashboard
  aggregateField: (layerId: string, field: string) =>
    request<{ field: string; bars: AggregateBar[] }>(`/api/layers/${layerId}/aggregate?field=${encodeURIComponent(field)}`),

  // Public
  getSharedMap: (token: string) => request<{ map: MapDto; layers: LayerDto[] }>(`/api/public/maps/${token}`),
};
