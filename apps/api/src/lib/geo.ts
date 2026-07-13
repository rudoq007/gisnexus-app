import { GeomType, NormalizedFeature, ServiceConfig } from "../types";

// ---------------------------------------------------------------------------
// CSV parsing (no external dependency — handles quoted fields & commas)
// ---------------------------------------------------------------------------
function splitCSVLine(line: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQuotes) {
      if (c === '"') {
        if (line[i + 1] === '"') {
          cur += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cur += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      out.push(cur);
      cur = "";
    } else {
      cur += c;
    }
  }
  out.push(cur);
  return out;
}

export function parseCSV(text: string): { headers: string[]; rows: Record<string, string>[] } {
  const lines = text.split(/\r\n|\n/).filter((l) => l.trim().length);
  if (!lines.length) return { headers: [], rows: [] };
  const headers = splitCSVLine(lines[0]).map((h) => h.trim());
  const rows = lines.slice(1).map((line) => {
    const vals = splitCSVLine(line);
    const obj: Record<string, string> = {};
    headers.forEach((h, i) => (obj[h] = (vals[i] ?? "").trim()));
    return obj;
  });
  return { headers, rows };
}

const LAT_NAMES = ["lat", "latitude", "y"];
const LON_NAMES = ["lon", "lng", "long", "longitude", "x"];

function isNumericStr(v: string): boolean {
  return v !== "" && v !== null && v !== undefined && !isNaN(Number(v));
}

export function csvToFeatures(text: string): { geomType: GeomType; features: NormalizedFeature[]; skipped: number } {
  const { headers, rows } = parseCSV(text);
  if (!headers.length) throw new Error("Empty or unparseable CSV.");
  const latKey = headers.find((h) => LAT_NAMES.includes(h.toLowerCase()));
  const lonKey = headers.find((h) => LON_NAMES.includes(h.toLowerCase()));
  if (!latKey || !lonKey) {
    throw new Error("CSV needs latitude/longitude columns (e.g. lat, lon).");
  }
  const features: NormalizedFeature[] = [];
  let skipped = 0;
  for (const row of rows) {
    const lat = parseFloat(row[latKey]);
    const lon = parseFloat(row[lonKey]);
    if (Number.isNaN(lat) || Number.isNaN(lon)) {
      skipped++;
      continue;
    }
    const properties: Record<string, unknown> = {};
    for (const h of headers) {
      if (h === latKey || h === lonKey) continue;
      const v = row[h];
      properties[h] = isNumericStr(v) ? Number(v) : v;
    }
    features.push({ geometry: { type: "Point", coordinates: [lon, lat] }, properties });
  }
  if (!features.length) throw new Error("No valid coordinate rows found in that CSV.");
  return { geomType: "Point", features, skipped };
}

// ---------------------------------------------------------------------------
// GeoJSON normalization — flattens Multi* geometries into individual
// Point/LineString/Polygon features so every row in `features` maps to one
// simple geometry (keeps styling & rendering logic simple downstream).
// ---------------------------------------------------------------------------
interface GeoJSONGeometry {
  type: string;
  coordinates: unknown;
}
interface GeoJSONFeature {
  type: "Feature";
  geometry: GeoJSONGeometry | null;
  properties?: Record<string, unknown> | null;
}

/**
 * Shared by every format that ultimately produces a standard array of
 * {geometry, properties} features (GeoJSON, Shapefile-via-shpjs, KML/GPX-via-
 * togeojson). Flattens Multi* geometries into individual Point/LineString/
 * Polygon features and picks the dominant geometry type for the new layer.
 */
export function normalizeFeatureArray(
  rawFeatures: GeoJSONFeature[]
): { geomType: GeomType; features: NormalizedFeature[]; skipped: number } {
  const built: NormalizedFeature[] = [];
  const dominant: Record<string, number> = {};
  let skipped = 0;

  for (const f of rawFeatures) {
    const geom = f.geometry;
    const props = f.properties || {};
    if (!geom || !geom.type) {
      skipped++;
      continue;
    }
    switch (geom.type) {
      case "Point":
        built.push({ geometry: { type: "Point", coordinates: geom.coordinates }, properties: props });
        dominant.Point = (dominant.Point || 0) + 1;
        break;
      case "MultiPoint":
        (geom.coordinates as unknown[]).forEach((c) => {
          built.push({ geometry: { type: "Point", coordinates: c }, properties: props });
        });
        dominant.Point = (dominant.Point || 0) + 1;
        break;
      case "LineString":
        built.push({ geometry: { type: "LineString", coordinates: geom.coordinates }, properties: props });
        dominant.LineString = (dominant.LineString || 0) + 1;
        break;
      case "MultiLineString":
        (geom.coordinates as unknown[]).forEach((c) => {
          built.push({ geometry: { type: "LineString", coordinates: c }, properties: props });
        });
        dominant.LineString = (dominant.LineString || 0) + 1;
        break;
      case "Polygon":
        built.push({ geometry: { type: "Polygon", coordinates: geom.coordinates }, properties: props });
        dominant.Polygon = (dominant.Polygon || 0) + 1;
        break;
      case "MultiPolygon":
        (geom.coordinates as unknown[]).forEach((c) => {
          built.push({ geometry: { type: "Polygon", coordinates: c }, properties: props });
        });
        dominant.Polygon = (dominant.Polygon || 0) + 1;
        break;
      default:
        skipped++;
    }
  }

  if (!built.length) throw new Error("No supported geometries (Point/LineString/Polygon) found.");
  const geomType = Object.entries(dominant).sort((a, b) => b[1] - a[1])[0][0] as GeomType;
  return { geomType, features: built, skipped };
}

export function geojsonToFeatures(json: unknown): { geomType: GeomType; features: NormalizedFeature[]; skipped: number } {
  let rawFeatures: GeoJSONFeature[] = [];
  const j = json as { type?: string; features?: GeoJSONFeature[]; geometry?: GeoJSONGeometry; coordinates?: unknown };

  if (j?.type === "FeatureCollection" && Array.isArray(j.features)) {
    rawFeatures = j.features;
  } else if (j?.type === "Feature") {
    rawFeatures = [j as unknown as GeoJSONFeature];
  } else if (j?.type && j.coordinates) {
    rawFeatures = [{ type: "Feature", geometry: j as GeoJSONGeometry, properties: {} }];
  } else {
    throw new Error("Unrecognized GeoJSON: expected a Feature, FeatureCollection, or geometry object.");
  }

  return normalizeFeatureArray(rawFeatures);
}

// ---------------------------------------------------------------------------
// Shapefile (.zip containing .shp/.dbf/.prj) — parsed with the `shapefile`
// package. Attribute joining (.dbf) is handled by that package; we just
// locate the right members inside the zip and normalize the result.
//
// Known limitation: this does NOT reproject non-WGS84 shapefiles. If the
// .prj doesn't look like WGS84/EPSG:4326, we still parse it (coordinates
// are stored as-is) but flag it in the `warning` field so the caller can
// surface it — reprojecting arbitrary CRSes needs a full WKT->proj4 pipeline
// (see README "Known scaling limits" for the follow-up note).
// ---------------------------------------------------------------------------
export async function shapefileZipToFeatures(
  zipBuffer: Buffer
): Promise<{ geomType: GeomType; features: NormalizedFeature[]; skipped: number; warning?: string }> {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const JSZip = require("jszip");
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const shapefile = require("shapefile");

  const zip = await JSZip.loadAsync(zipBuffer);
  const entries = Object.keys(zip.files).filter((name) => !zip.files[name].dir);

  const shpName = entries.find((n) => /\.shp$/i.test(n));
  const dbfName = entries.find((n) => /\.dbf$/i.test(n));
  const prjName = entries.find((n) => /\.prj$/i.test(n));
  if (!shpName) throw new Error("No .shp file found inside the uploaded zip.");

  const shpBuffer = Buffer.from(await zip.files[shpName].async("nodebuffer"));
  const dbfBuffer = dbfName ? Buffer.from(await zip.files[dbfName].async("nodebuffer")) : undefined;

  let warning: string | undefined;
  if (prjName) {
    const prjText = await zip.files[prjName].async("string");
    const looksLikeWgs84 = /GCS_WGS_1984|WGS_1984|WGS84|4326/i.test(prjText);
    if (!looksLikeWgs84) {
      warning =
        "This shapefile's .prj doesn't look like WGS84 (EPSG:4326). Coordinates were loaded as-is without " +
        "reprojection, so the layer may appear in the wrong place on the map. Reproject to WGS84 before " +
        "uploading for accurate results.";
    }
  } else {
    warning = "No .prj file found — assuming coordinates are already WGS84 (EPSG:4326).";
  }

  const collection = await shapefile.read(shpBuffer, dbfBuffer);
  const result = normalizeFeatureArray(collection.features as GeoJSONFeature[]);
  return { ...result, warning };
}

// ---------------------------------------------------------------------------
// KML / GPX — both are XML formats converted to GeoJSON via @tmcw/togeojson,
// which needs a DOM Document (Node has no built-in DOMParser, so we use the
// lightweight @xmldom/xmldom package).
// ---------------------------------------------------------------------------
function parseXml(text: string) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { DOMParser } = require("@xmldom/xmldom");
  return new DOMParser().parseFromString(text, "text/xml");
}

export function kmlToFeatures(text: string): { geomType: GeomType; features: NormalizedFeature[]; skipped: number } {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const togeojson = require("@tmcw/togeojson");
  const dom = parseXml(text);
  const collection = togeojson.kml(dom);
  if (!collection?.features?.length) throw new Error("No features found in this KML file.");
  return normalizeFeatureArray(collection.features as GeoJSONFeature[]);
}

export function gpxToFeatures(text: string): { geomType: GeomType; features: NormalizedFeature[]; skipped: number } {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const togeojson = require("@tmcw/togeojson");
  const dom = parseXml(text);
  const collection = togeojson.gpx(dom);
  if (!collection?.features?.length) throw new Error("No features found in this GPX file.");
  return normalizeFeatureArray(collection.features as GeoJSONFeature[]);
}

// ---------------------------------------------------------------------------
// Buffer analysis — approximate circular buffer around a point, in meters.
// Good enough for coverage/proximity visualization without a full geodesic
// buffering library.
// ---------------------------------------------------------------------------
export function bufferRing(lon: number, lat: number, radiusMeters: number, steps = 32): [number, number][] {
  const R = 6371000;
  const dLat = (radiusMeters / R) * (180 / Math.PI);
  const dLon = (radiusMeters / (R * Math.cos((lat * Math.PI) / 180))) * (180 / Math.PI);
  const ring: [number, number][] = [];
  for (let i = 0; i < steps; i++) {
    const a = (i / steps) * 2 * Math.PI;
    ring.push([lon + dLon * Math.cos(a), lat + dLat * Math.sin(a)]);
  }
  ring.push(ring[0]);
  return ring;
}

// ---------------------------------------------------------------------------
// Dashboard aggregation — mirrors the client-side prototype's bucketing so
// behavior is consistent whether computed on a small sample or the full set.
// ---------------------------------------------------------------------------
export interface AggregateBar {
  label: string;
  value: number;
}

function fmtNum(n: number): string {
  return Math.abs(n) >= 1000 ? Math.round(n).toLocaleString() : (Math.round(n * 100) / 100).toString();
}

export function aggregateField(values: (string | number | null | undefined)[]): AggregateBar[] {
  const nonEmpty = values.filter((v) => v !== null && v !== undefined && v !== "");
  const numeric = nonEmpty.every((v) => typeof v === "number" || isNumericStr(String(v)));

  if (numeric) {
    const nums = nonEmpty.map(Number);
    if (!nums.length) return [];
    const min = Math.min(...nums);
    const max = Math.max(...nums);
    const buckets = 5;
    const span = max - min || 1;
    const counts = new Array(buckets).fill(0);
    nums.forEach((n) => {
      let idx = Math.floor(((n - min) / span) * buckets);
      if (idx >= buckets) idx = buckets - 1;
      if (idx < 0) idx = 0;
      counts[idx]++;
    });
    return counts.map((c, i) => ({
      label: `${fmtNum(min + (span * i) / buckets)}–${fmtNum(min + (span * (i + 1)) / buckets)}`,
      value: c,
    }));
  }

  const counts = new Map<string, number>();
  values.forEach((v) => {
    const k = v === null || v === undefined || v === "" ? "(empty)" : String(v);
    counts.set(k, (counts.get(k) || 0) + 1);
  });
  const entries = Array.from(counts.entries()).sort((a, b) => b[1] - a[1]);
  const top = entries.slice(0, 8);
  const rest = entries.slice(8).reduce((s, e) => s + e[1], 0);
  const bars: AggregateBar[] = top.map(([label, value]) => ({ label, value }));
  if (rest > 0) bars.push({ label: "Other", value: rest });
  return bars;
}

// ---------------------------------------------------------------------------
// External service layers ("Add Data" catalog + custom URLs). Two flavors:
//
//   - Raster (xyz/wms/wmts): we build a MapLibre-ready tile URL template
//     server-side and store it in the layer's `service` column. Nothing is
//     fetched here — the browser requests tiles directly from the remote
//     service as the user pans/zooms.
//   - Vector (wfs/arcgis): fetched once, right now, and normalized into the
//     same NormalizedFeature[] shape an upload produces, then inserted into
//     `features` exactly like routes/layers.ts's upload handler does. This is
//     a one-time snapshot import, not a live connection — re-adding the same
//     service later won't pick up upstream changes (see README).
// ---------------------------------------------------------------------------
export type ServiceFields = Record<string, string | number | boolean>;

function fieldStr(fields: ServiceFields, key: string, fallback = ""): string {
  const v = fields[key];
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return fallback;
}
function fieldBool(fields: ServiceFields, key: string, fallback = false): boolean {
  const v = fields[key];
  return typeof v === "boolean" ? v : fallback;
}
function fieldNum(fields: ServiceFields, key: string, fallback: number): number {
  const v = fields[key];
  const n = typeof v === "number" ? v : parseFloat(String(v));
  return Number.isFinite(n) ? n : fallback;
}

export function buildXyzService(fields: ServiceFields): ServiceConfig {
  const url = fieldStr(fields, "url").trim();
  if (!url) throw new Error("A tile URL is required.");
  if (!/\{z\}/.test(url) || !/\{x\}/.test(url) || !/\{y\}/.test(url)) {
    throw new Error("The tile URL must contain {z}, {x}, and {y} placeholders.");
  }
  return {
    type: "xyz",
    url,
    tileSize: fieldNum(fields, "tileSize", 256),
    attribution: fieldStr(fields, "attribution") || undefined,
    raw: fields,
  };
}

export function buildWmsService(fields: ServiceFields): ServiceConfig {
  const endpoint = fieldStr(fields, "endpoint").trim();
  const layers = fieldStr(fields, "layers").trim();
  if (!endpoint || !layers) throw new Error("A WMS endpoint and layer name are required.");
  const version = fieldStr(fields, "version", "1.3.0");
  const tileSize = fieldNum(fields, "tileSize", 256);
  const params = new URLSearchParams({
    SERVICE: "WMS",
    VERSION: version,
    REQUEST: "GetMap",
    LAYERS: layers,
    STYLES: fieldStr(fields, "styles"),
    FORMAT: fieldStr(fields, "format", "image/png"),
    TRANSPARENT: String(fieldBool(fields, "transparent", true)),
    WIDTH: String(tileSize),
    HEIGHT: String(tileSize),
  });
  // WMS 1.3.0 renamed the CRS parameter (and, for geographic CRSes, flipped
  // axis order — irrelevant here since we always request Web Mercator).
  params.set(version === "1.3.0" ? "CRS" : "SRS", "EPSG:3857");
  // Time-enabled services (e.g. NASA GIBS daily satellite composites) need a
  // TIME dimension on every request; "default" asks for the most recent
  // available date so the layer never goes stale.
  const time = fieldStr(fields, "time");
  if (time) params.set("TIME", time);
  const separator = endpoint.includes("?") ? "&" : "?";
  // MapLibre substitutes {bbox-epsg-3857} with each tile's bounds at request time.
  const url = `${endpoint}${separator}${params.toString()}&BBOX={bbox-epsg-3857}`;
  return {
    type: "wms",
    url,
    tileSize,
    attribution: fieldStr(fields, "attribution") || undefined,
    raw: fields,
  };
}

export function buildWmtsService(fields: ServiceFields): ServiceConfig {
  const url = fieldStr(fields, "url").trim();
  if (!url) throw new Error("A WMTS tile URL template is required.");
  if (!/\{z\}/.test(url) || !/\{x\}/.test(url) || !/\{y\}/.test(url)) {
    throw new Error(
      "This MVP only supports RESTful WMTS templates with {z}, {x}, and {y} placeholders (like an XYZ URL) — " +
        "paste the tile URL template, not a GetCapabilities document."
    );
  }
  return {
    type: "wmts",
    url,
    tileSize: fieldNum(fields, "tileSize", 256),
    attribution: fieldStr(fields, "attribution") || undefined,
    raw: fields,
  };
}

const SERVICE_FETCH_TIMEOUT_MS = 15000;
const MAX_SERVICE_RESPONSE_BYTES = 25 * 1024 * 1024; // 25MB guard against runaway remote responses

async function fetchServiceJson(url: string): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SERVICE_FETCH_TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetch(url, { signal: controller.signal, headers: { Accept: "application/json" } });
  } catch (err) {
    if ((err as Error).name === "AbortError") {
      throw new Error(`The remote service took too long to respond (${SERVICE_FETCH_TIMEOUT_MS / 1000}s timeout).`);
    }
    throw new Error(`Couldn't reach the remote service: ${(err as Error).message}`);
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) throw new Error(`The remote service returned an error (HTTP ${res.status}).`);

  const lengthHeader = res.headers.get("content-length");
  if (lengthHeader && Number(lengthHeader) > MAX_SERVICE_RESPONSE_BYTES) {
    throw new Error("The remote service's response was too large to import (over 25MB).");
  }
  const text = await res.text();
  if (text.length > MAX_SERVICE_RESPONSE_BYTES) {
    throw new Error("The remote service's response was too large to import (over 25MB).");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error("The remote service didn't return valid JSON/GeoJSON — check the URL and parameters.");
  }
}

export interface ServiceVectorResult {
  geomType: GeomType;
  features: NormalizedFeature[];
  skipped: number;
  config: ServiceConfig;
}

export async function wfsToFeatures(fields: ServiceFields): Promise<ServiceVectorResult> {
  const endpoint = fieldStr(fields, "endpoint").trim();
  const typeName = fieldStr(fields, "typeName").trim();
  if (!endpoint || !typeName) throw new Error("A WFS endpoint and type name are required.");
  const version = fieldStr(fields, "version", "2.0.0");
  const maxFeatures = fieldNum(fields, "maxFeatures", 1000);

  const params = new URLSearchParams({
    SERVICE: "WFS",
    VERSION: version,
    REQUEST: "GetFeature",
    OUTPUTFORMAT: fieldStr(fields, "outputFormat", "application/json"),
    SRSNAME: fieldStr(fields, "srsName", "EPSG:4326"),
  });
  // 2.x uses TYPENAMES/COUNT; 1.0.0/1.1.0 use TYPENAME/MAXFEATURES.
  if (version.startsWith("2.")) {
    params.set("TYPENAMES", typeName);
    params.set("COUNT", String(maxFeatures));
  } else {
    params.set("TYPENAME", typeName);
    params.set("MAXFEATURES", String(maxFeatures));
  }
  const separator = endpoint.includes("?") ? "&" : "?";
  const json = await fetchServiceJson(`${endpoint}${separator}${params.toString()}`);

  let result: { geomType: GeomType; features: NormalizedFeature[]; skipped: number };
  try {
    result = geojsonToFeatures(json);
  } catch (err) {
    throw new Error(`WFS response wasn't usable GeoJSON: ${(err as Error).message}`);
  }
  return { ...result, config: { type: "wfs", raw: fields } };
}

export async function arcgisFeatureToFeatures(fields: ServiceFields): Promise<ServiceVectorResult> {
  const base = fieldStr(fields, "url").trim().replace(/\/+$/, "");
  if (!base) throw new Error("An ArcGIS FeatureServer/MapServer layer URL is required.");
  const params = new URLSearchParams({ where: "1=1", outFields: "*", f: "geojson", outSR: "4326" });
  const json = await fetchServiceJson(`${base}/query?${params.toString()}`);

  const errPayload = json as { error?: { message?: string; details?: string[] } };
  if (errPayload && typeof errPayload === "object" && errPayload.error) {
    throw new Error(errPayload.error.message || "The ArcGIS service returned an error.");
  }
  let result: { geomType: GeomType; features: NormalizedFeature[]; skipped: number };
  try {
    result = geojsonToFeatures(json);
  } catch (err) {
    throw new Error(`ArcGIS response wasn't usable GeoJSON: ${(err as Error).message}`);
  }
  return { ...result, config: { type: "arcgis", raw: fields } };
}

/**
 * Plain hosted GeoJSON file (not a WFS/ArcGIS query — just a static .geojson
 * URL, e.g. a dataset published on GitHub or a data CDN). Simpler and more
 * reliable than a live OGC service since there's no server-side query to
 * fail: fetched once and imported exactly like an upload.
 */
export async function geojsonUrlToFeatures(fields: ServiceFields): Promise<ServiceVectorResult> {
  const url = fieldStr(fields, "url").trim();
  if (!url) throw new Error("A GeoJSON URL is required.");
  const json = await fetchServiceJson(url);
  let result: { geomType: GeomType; features: NormalizedFeature[]; skipped: number };
  try {
    result = geojsonToFeatures(json);
  } catch (err) {
    throw new Error(`That URL wasn't usable GeoJSON: ${(err as Error).message}`);
  }
  return { ...result, config: { type: "geojson", raw: fields } };
}
