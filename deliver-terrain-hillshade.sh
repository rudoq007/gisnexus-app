#!/usr/bin/env bash
# GISNEXUS — Terrain Analysis (Hillshade), v1
# Run this from the ROOT of your gisnexus-app repo, in Git Bash:
#   bash deliver-terrain-hillshade.sh
# It writes/overwrites every file this feature touches, then you review the
# diff, install deps, build, and push (instructions printed at the end).
set -e

echo "Writing apps/api/src/types.ts ..."
cat > apps/api/src/types.ts <<'EOF'
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
EOF

echo "Writing apps/api/src/lib/terrain.ts ..."
mkdir -p apps/api/src/lib
cat > apps/api/src/lib/terrain.ts <<'EOF'
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";

// ---------------------------------------------------------------------------
// Terrain analysis (GeoLibre-style "Processing" tools) — v1 ships Hillshade
// only. The pipeline below (DEM fetch → WhiteboxTools → colorize) is written
// so Slope/Aspect/Contours/Watershed are each just a new function that reuses
// fetchDem()/writeAsciiGrid()/runWhiteboxTool(), not a new subsystem.
//
// KNOWN RISK: the exact WhiteboxTools CLI flag names below (--input=,
// --output=, --azimuth=, --altitude=) match the tool's documented CLI
// convention as of this writing, but this file was written without the
// ability to run `whitebox_tools` and verify against it directly (no network
// access in the environment this was authored in). If a hillshade request
// fails, check the ApiError message (it includes whitebox_tools's own
// stderr/stdout) — a flag-name mismatch will show up there immediately.
// ---------------------------------------------------------------------------

const WHITEBOX_BIN = path.join(__dirname, "..", "..", "bin", "whitebox_tools");
const TERRARIUM_URL = (z: number, x: number, y: number) =>
  `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/${z}/${x}/${y}.png`;
const MAX_TILES_PER_SIDE = 6; // caps both fetch time and output image size
const NODATA = -32768;

export interface Bbox {
  west: number;
  south: number;
  east: number;
  north: number;
}

export interface DemGrid {
  data: Float32Array; // row-major, row 0 = north
  width: number;
  height: number;
  bounds: Bbox; // tile-aligned extent (may be slightly larger than requested)
}

export function binExists(): boolean {
  return fsSync.existsSync(WHITEBOX_BIN);
}

// ---------------------------------------------------------------------------
// Slippy-map tile math (standard Web Mercator XYZ scheme, used by every free
// raster tile service including the Terrarium elevation tiles below).
// ---------------------------------------------------------------------------
function lonToTileX(lon: number, z: number): number {
  return Math.floor(((lon + 180) / 360) * 2 ** z);
}
function latToTileY(lat: number, z: number): number {
  const rad = (lat * Math.PI) / 180;
  return Math.floor(((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * 2 ** z);
}
function tileXToLon(x: number, z: number): number {
  return (x / 2 ** z) * 360 - 180;
}
function tileYToLat(y: number, z: number): number {
  const n = Math.PI - (2 * Math.PI * y) / 2 ** z;
  return (180 / Math.PI) * Math.atan(Math.sinh(n));
}

/** Picks the highest zoom (most detail) whose tile coverage of `bbox` fits within MAX_TILES_PER_SIDE per axis. */
function pickZoom(bbox: Bbox): number {
  for (let z = 14; z >= 0; z--) {
    const xMin = lonToTileX(bbox.west, z);
    const xMax = lonToTileX(bbox.east, z);
    const yMin = latToTileY(bbox.north, z);
    const yMax = latToTileY(bbox.south, z);
    if (xMax - xMin + 1 <= MAX_TILES_PER_SIDE && yMax - yMin + 1 <= MAX_TILES_PER_SIDE) return z;
  }
  return 0;
}

/**
 * Fetches free, keyless AWS "Terrarium" elevation tiles covering `bbox`,
 * decodes each tile's RGB-encoded elevation (elevation = R*256 + G + B/256 -
 * 32768, per the Terrarium spec), and mosaics them into one elevation grid.
 *
 * Known simplification: the assembled grid is treated as an evenly-spaced
 * lat/lon (geographic) grid for the ASCII-grid handoff to WhiteboxTools, but
 * the source tiles are evenly spaced in Web Mercator Y, not latitude. This
 * under-states north-south cell height slightly (more so at high latitudes)
 * — negligible for a shaded-relief visualization at city/regional scale, but
 * not survey-grade. A future pass could resample to a true geographic grid.
 */
export async function fetchDem(bbox: Bbox): Promise<DemGrid> {
  const z = pickZoom(bbox);
  const xMin = lonToTileX(bbox.west, z);
  const xMax = lonToTileX(bbox.east, z);
  const yMin = latToTileY(bbox.north, z);
  const yMax = latToTileY(bbox.south, z);

  const tilesX = xMax - xMin + 1;
  const tilesY = yMax - yMin + 1;
  const width = tilesX * 256;
  const height = tilesY * 256;
  const data = new Float32Array(width * height);

  const fetches: Promise<void>[] = [];
  for (let ty = yMin; ty <= yMax; ty++) {
    for (let tx = xMin; tx <= xMax; tx++) {
      fetches.push(
        (async () => {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 15000);
          let res: Response;
          try {
            res = await fetch(TERRARIUM_URL(z, tx, ty), { signal: controller.signal });
          } catch (err) {
            throw new Error(`Couldn't fetch elevation tile ${z}/${tx}/${ty}: ${(err as Error).message}`);
          } finally {
            clearTimeout(timer);
          }
          if (!res.ok) throw new Error(`Elevation data isn't available for this area (tile ${z}/${tx}/${ty} → HTTP ${res.status}).`);
          const buf = Buffer.from(await res.arrayBuffer());
          const { data: pixels, info } = await sharp(buf).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
          if (info.width !== 256 || info.height !== 256) {
            throw new Error(`Unexpected elevation tile size ${info.width}x${info.height} for ${z}/${tx}/${ty}.`);
          }
          const offsetX = (tx - xMin) * 256;
          const offsetY = (ty - yMin) * 256;
          for (let py = 0; py < 256; py++) {
            for (let px = 0; px < 256; px++) {
              const i = (py * 256 + px) * 4;
              const r = pixels[i];
              const g = pixels[i + 1];
              const b = pixels[i + 2];
              const elevation = r * 256 + g + b / 256 - 32768;
              data[(offsetY + py) * width + (offsetX + px)] = elevation;
            }
          }
        })()
      );
    }
  }
  await Promise.all(fetches);

  return {
    data,
    width,
    height,
    bounds: {
      west: tileXToLon(xMin, z),
      east: tileXToLon(xMax + 1, z),
      north: tileYToLat(yMin, z),
      south: tileYToLat(yMax + 1, z),
    },
  };
}

// ---------------------------------------------------------------------------
// ESRI ASCII Grid (.asc) read/write — a plain-text raster format both GDAL
// and WhiteboxTools read/write natively. Chosen over GeoTIFF or WhiteboxTools'
// own binary .dep/.tas format specifically because it's simple enough to
// hand-write correctly without a binary-format dependency: a short text
// header followed by whitespace-separated numbers, one row per line.
// ---------------------------------------------------------------------------
export async function writeAsciiGrid(grid: DemGrid, filePath: string): Promise<void> {
  const { width, height, bounds, data } = grid;
  // ESRI ASCII Grid only supports one `cellsize` for both axes (square
  // cells). We derive it from the east-west span, which is exact (tile
  // longitude spacing is uniform); reusing it for the north-south axis is
  // the other half of the "treated as a geographic grid" approximation
  // noted on fetchDem() above — the resulting north bound (south +
  // height*cellsize, see readAsciiGrid) drifts from the tiles' true
  // Mercator-derived north edge by the local Mercator scale factor. Over a
  // single small map-view bbox this is a few percent at most; fine for a
  // shaded-relief visual, not for survey-grade output.
  const cellsize = (bounds.east - bounds.west) / width;
  const lines: string[] = [
    `ncols ${width}`,
    `nrows ${height}`,
    `xllcorner ${bounds.west}`,
    `yllcorner ${bounds.south}`,
    `cellsize ${cellsize}`,
    `NODATA_value ${NODATA}`,
  ];
  for (let row = 0; row < height; row++) {
    const rowVals = new Array(width);
    for (let col = 0; col < width; col++) {
      const v = data[row * width + col];
      rowVals[col] = Number.isFinite(v) ? v.toFixed(2) : String(NODATA);
    }
    lines.push(rowVals.join(" "));
  }
  await fs.writeFile(filePath, lines.join("\n") + "\n", "utf8");
}

// The 6 standard ESRI ASCII Grid header keys (plus the xllcenter/yllcenter
// variant some writers use instead of the corner convention). Matching
// against this known set — rather than "does this line look like `word
// number`" — matters: every *data* row is also whitespace-separated numbers,
// and a naive "\w+\s+number" pattern matches a data row just as happily as a
// header line (a plain digit like "0" satisfies \w+ too), which would walk
// the header parser straight through the entire grid. Only a line whose
// first token is a real header keyword can be a header line.
const ASCII_GRID_HEADER_KEYS = new Set([
  "ncols",
  "nrows",
  "xllcorner",
  "yllcorner",
  "xllcenter",
  "yllcenter",
  "cellsize",
  "nodata_value",
]);

export async function readAsciiGrid(filePath: string): Promise<DemGrid> {
  const text = await fs.readFile(filePath, "utf8");
  const lines = text.split(/\r?\n/);
  const header: Record<string, number> = {};
  let dataStartLine = 0;
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (!trimmed) continue;
    const parts = trimmed.split(/\s+/);
    const key = parts[0].toLowerCase();
    if (ASCII_GRID_HEADER_KEYS.has(key) && parts.length >= 2 && Number.isFinite(parseFloat(parts[1]))) {
      header[key] = parseFloat(parts[1]);
      dataStartLine = i + 1;
    } else {
      dataStartLine = i;
      break;
    }
  }
  const width = header["ncols"];
  const height = header["nrows"];
  // Accept either corner or center convention for the lower-left reference
  // point; we only ever *write* "corner" ourselves, but WhiteboxTools may
  // echo back whichever convention it was given.
  const cellsize = header["cellsize"];
  const west = header["xllcorner"] ?? (Number.isFinite(header["xllcenter"]) ? header["xllcenter"] - cellsize / 2 : NaN);
  const south = header["yllcorner"] ?? (Number.isFinite(header["yllcenter"]) ? header["yllcenter"] - cellsize / 2 : NaN);
  const nodata = header["nodata_value"] ?? NODATA;
  if (!width || !height || !Number.isFinite(west) || !Number.isFinite(south) || !cellsize) {
    throw new Error("Couldn't parse WhiteboxTools output (unexpected ASCII grid header).");
  }

  const data = new Float32Array(width * height);
  let idx = 0;
  for (let i = dataStartLine; i < lines.length && idx < data.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    for (const tok of line.split(/\s+/)) {
      const v = parseFloat(tok);
      data[idx++] = v === nodata ? NaN : v;
    }
  }

  return {
    data,
    width,
    height,
    bounds: { west, south, east: west + cellsize * width, north: south + cellsize * height },
  };
}

// ---------------------------------------------------------------------------
// WhiteboxTools subprocess runner
// ---------------------------------------------------------------------------
export async function runWhiteboxTool(toolName: string, args: string[], workDir: string): Promise<void> {
  if (!binExists()) {
    throw new Error(
      "The WhiteboxTools binary isn't installed on this server. Run `npm run setup:whitebox` (see apps/api/scripts/setup-whitebox.js) as part of your build/deploy."
    );
  }
  const fullArgs = [`--run=${toolName}`, `--wd=${workDir}`, ...args, "-v"];
  await new Promise<void>((resolve, reject) => {
    execFile(WHITEBOX_BIN, fullArgs, { timeout: 90000, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const detail = [stdout, stderr].filter(Boolean).join("\n").slice(-2000);
        reject(new Error(`WhiteboxTools ${toolName} failed: ${err.message}${detail ? `\n${detail}` : ""}`));
        return;
      }
      resolve();
    });
  });
}

// ---------------------------------------------------------------------------
// Hillshade — grayscale shaded-relief PNG, ready to drop straight onto the
// map as a MapLibre ImageSource (see routes/terrain.ts).
// ---------------------------------------------------------------------------
export interface HillshadeResult {
  pngBuffer: Buffer;
  bounds: Bbox;
}

export async function runHillshade(bbox: Bbox, azimuth: number, altitude: number): Promise<HillshadeResult> {
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "gisnexus-terrain-"));
  try {
    const dem = await fetchDem(bbox);
    await writeAsciiGrid(dem, path.join(workDir, "dem.asc"));

    await runWhiteboxTool("Hillshade", [
      "--input=dem.asc",
      "--output=hillshade.asc",
      `--azimuth=${azimuth}`,
      `--altitude=${altitude}`,
    ], workDir);

    const result = await readAsciiGrid(path.join(workDir, "hillshade.asc"));

    // Hillshade output values are already a 0-255 grayscale intensity;
    // NoData cells (NaN, e.g. tile edges) render fully transparent so gaps
    // don't show up as black.
    const rgba = Buffer.alloc(result.width * result.height * 4);
    for (let i = 0; i < result.data.length; i++) {
      const v = result.data[i];
      const gray = Number.isFinite(v) ? Math.max(0, Math.min(255, Math.round(v))) : 0;
      rgba[i * 4] = gray;
      rgba[i * 4 + 1] = gray;
      rgba[i * 4 + 2] = gray;
      rgba[i * 4 + 3] = Number.isFinite(v) ? 255 : 0;
    }
    const pngBuffer = await sharp(rgba, { raw: { width: result.width, height: result.height, channels: 4 } })
      .png()
      .toBuffer();

    return { pngBuffer, bounds: result.bounds };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}
EOF

echo "Writing apps/api/src/routes/terrain.ts ..."
cat > apps/api/src/routes/terrain.ts <<'EOF'
import { Router } from "express";
import { z } from "zod";
import { pool } from "../db";
import { requireAuth, AuthedRequest } from "../middleware/auth";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { canEdit, getMapRole } from "../lib/access";
import { binExists, runHillshade } from "../lib/terrain";
import { LayerRow } from "../types";

export const terrainRouter = Router();
terrainRouter.use(requireAuth);

// Bounds the area (and therefore the DEM tile-fetch cost + output image
// size) any single terrain request can cover. fetchDem() enforces its own
// MAX_TILES_PER_SIDE cap as a second line of defense, but rejecting an
// obviously-too-large request up front gives a clearer error message.
const MAX_SPAN_DEGREES = 2;

const bboxSchema = z
  .object({
    west: z.number().gte(-180).lte(180),
    south: z.number().gte(-85).lte(85),
    east: z.number().gte(-180).lte(180),
    north: z.number().gte(-85).lte(85),
  })
  .refine((b) => b.east > b.west && b.north > b.south, { message: "Invalid bounding box." })
  .refine((b) => b.east - b.west <= MAX_SPAN_DEGREES && b.north - b.south <= MAX_SPAN_DEGREES, {
    message: `Zoom in further — terrain analysis only works on an area up to about ${MAX_SPAN_DEGREES}° across.`,
  });

const hillshadeSchema = z.object({
  bbox: bboxSchema,
  azimuth: z.number().gte(0).lte(360).default(315),
  altitude: z.number().gte(0).lte(90).default(45),
  name: z.string().min(1).max(200).optional(),
});

// ---------------------------------------------------------------------------
// Hillshade — the first of GISNEXUS's WhiteboxTools-backed terrain tools
// (see apps/api/src/lib/terrain.ts). Fetches free public elevation data for
// the map's current view, runs WhiteboxTools' Hillshade algorithm, and adds
// the result as a single georeferenced image layer (kind='raster',
// service.type='image') — same layer model as any other raster layer, just
// rendered from a data: URL instead of a live tile service.
// ---------------------------------------------------------------------------
terrainRouter.post(
  "/maps/:mapId/terrain/hillshade",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");

    if (!binExists()) {
      throw new ApiError(
        503,
        "Terrain tools aren't set up on this server yet — the WhiteboxTools binary is missing. " +
          "Run `npm run setup:whitebox` as part of the API's build/deploy step, then redeploy."
      );
    }

    const { bbox, azimuth, altitude, name } = hillshadeSchema.parse(req.body);

    let result: Awaited<ReturnType<typeof runHillshade>>;
    try {
      result = await runHillshade(bbox, azimuth, altitude);
    } catch (err) {
      throw new ApiError(500, `Hillshade failed: ${(err as Error).message}`);
    }

    const service = {
      type: "image",
      url: `data:image/png;base64,${result.pngBuffer.toString("base64")}`,
      coordinates: [
        [result.bounds.west, result.bounds.north],
        [result.bounds.east, result.bounds.north],
        [result.bounds.east, result.bounds.south],
        [result.bounds.west, result.bounds.south],
      ],
      attribution: "Elevation: AWS Terrain Tiles (SRTM/NED/etc., public domain) · Hillshade via WhiteboxTools",
      raw: { azimuth, altitude },
    };

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, kind, geom_type, source, service, style)
       VALUES ($1, $2, 'raster', NULL, 'terrain', $3, '{"color":"#7c5cff","opacity":0.65,"size":6}')
       RETURNING *`,
      [req.params.mapId, name || `Hillshade (az ${azimuth}°, alt ${altitude}°)`, JSON.stringify(service)]
    );

    res.status(201).json({ layer: rows[0] });
  })
);
EOF

echo "Writing apps/api/src/index.ts ..."
cat > apps/api/src/index.ts <<'EOF'
import express from "express";
import cors from "cors";
import { env } from "./env";
import { authRouter } from "./routes/auth";
import { mapsRouter } from "./routes/maps";
import { layersRouter } from "./routes/layers";
import { analysisRouter } from "./routes/analysis";
import { terrainRouter } from "./routes/terrain";
import { dashboardRouter } from "./routes/dashboard";
import { publicRouter } from "./routes/public";
import { errorHandler, notFoundHandler } from "./middleware/errorHandler";

const app = express();

app.use(cors({ origin: env.corsOrigin }));
app.use(express.json({ limit: "2mb" }));

app.get("/health", (_req, res) => res.json({ ok: true }));

app.use("/api/auth", authRouter);
app.use("/api/maps", mapsRouter);
app.use("/api", layersRouter); // mounts /api/maps/:mapId/layers/upload and /api/layers/:id/*
app.use("/api", analysisRouter); // mounts /api/layers/:id/buffer and /intersects
app.use("/api", terrainRouter); // mounts /api/maps/:mapId/terrain/hillshade
app.use("/api", dashboardRouter); // mounts /api/layers/:id/aggregate
app.use("/api/public", publicRouter);

app.use(notFoundHandler);
app.use(errorHandler);

app.listen(env.port, () => {
  // eslint-disable-next-line no-console
  console.log(`GISNEXUS API listening on http://localhost:${env.port}`);
});
EOF

echo "Writing apps/api/scripts/setup-whitebox.js ..."
mkdir -p apps/api/scripts
cat > apps/api/scripts/setup-whitebox.js <<'EOF'
/**
 * Downloads the open-source WhiteboxTools binary (MIT licensed,
 * github.com/jblindsay/whitebox-tools) into apps/api/bin/whitebox_tools, for
 * the terrain-analysis endpoints in src/routes/terrain.ts to shell out to.
 *
 * Not wired up as an npm "postinstall" hook on purpose: in the Docker build
 * (see ../Dockerfile), `npm install` runs before the rest of the source tree
 * (including this scripts/ folder) is copied in, so a postinstall hook would
 * fire before this file even exists. Instead this is an explicit build step
 * — call it after your source is present and before `npm run build`:
 *
 *   npm run setup:whitebox
 *
 * Deliberately non-fatal: if the download fails for any reason (network,
 * GitHub API rate limit, no matching release asset), this logs a warning and
 * exits 0 rather than failing the whole deploy. Terrain endpoints check
 * binExists() themselves and return a clear 503 if it's missing, so the rest
 * of the app (which doesn't depend on this) still ships fine either way.
 *
 * Usage: node scripts/setup-whitebox.js   (from apps/api)
 */
const fs = require("node:fs");
const path = require("node:path");
const https = require("node:https");

const BIN_DIR = path.join(__dirname, "..", "bin");
const BIN_PATH = path.join(BIN_DIR, "whitebox_tools");
const RELEASES_API = "https://api.github.com/repos/jblindsay/whitebox-tools/releases/latest";
const USER_AGENT = "gisnexus-setup-whitebox";

function httpGetBuffer(url, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/octet-stream, application/json" } }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirectsLeft > 0) {
          res.resume();
          httpGetBuffer(res.headers.location, redirectsLeft - 1).then(resolve, reject);
          return;
        }
        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`HTTP ${res.statusCode} fetching ${url}`));
          return;
        }
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(Buffer.concat(chunks)));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

async function main() {
  if (fs.existsSync(BIN_PATH)) {
    console.log(`setup-whitebox: ${BIN_PATH} already present, skipping download.`);
    return;
  }

  console.log("setup-whitebox: looking up the latest WhiteboxTools release...");
  const releaseJson = JSON.parse((await httpGetBuffer(RELEASES_API)).toString("utf8"));
  const assets = releaseJson.assets || [];
  const asset = assets.find((a) => {
    const n = a.name.toLowerCase();
    return n.endsWith(".zip") && n.includes("linux") && (n.includes("amd64") || n.includes("x86_64") || n.includes("x86-64"));
  });

  if (!asset) {
    console.warn(
      `setup-whitebox: WARNING — couldn't find a linux/amd64 .zip asset in the latest release (${releaseJson.tag_name || "?"}). ` +
        `Available assets: ${assets.map((a) => a.name).join(", ") || "(none)"}. ` +
        "Terrain-analysis endpoints will return a clear error until this is resolved manually — everything else still works."
    );
    return;
  }

  console.log(`setup-whitebox: downloading ${asset.name} (${releaseJson.tag_name})...`);
  const zipBuffer = await httpGetBuffer(asset.browser_download_url);

  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const JSZip = require("jszip");
  const zip = await JSZip.loadAsync(zipBuffer);
  const entryName = Object.keys(zip.files).find((n) => !zip.files[n].dir && path.basename(n) === "whitebox_tools");
  if (!entryName) {
    console.warn(
      `setup-whitebox: WARNING — ${asset.name} didn't contain a "whitebox_tools" executable at any path. ` +
        `Zip contents: ${Object.keys(zip.files).slice(0, 20).join(", ")}${Object.keys(zip.files).length > 20 ? ", ..." : ""}. ` +
        "Terrain-analysis endpoints will return a clear error until this is resolved manually — everything else still works."
    );
    return;
  }

  const binBuffer = await zip.files[entryName].async("nodebuffer");
  fs.mkdirSync(BIN_DIR, { recursive: true });
  fs.writeFileSync(BIN_PATH, binBuffer);
  fs.chmodSync(BIN_PATH, 0o755);
  console.log(`setup-whitebox: installed ${BIN_PATH} (${(binBuffer.length / 1024 / 1024).toFixed(1)} MB).`);
}

main().catch((err) => {
  console.warn(`setup-whitebox: WARNING — setup failed, terrain-analysis endpoints won't work until this is resolved: ${err.message}`);
  // Non-fatal — exit 0 so this never breaks the rest of the build/deploy.
  process.exit(0);
});
EOF

echo "Writing apps/api/package.json ..."
cat > apps/api/package.json <<'EOF'
{
  "name": "@gisnexus/api",
  "version": "0.1.0",
  "private": true,
  "description": "GISNEXUS backend API — auth, maps, layers, sharing, spatial analysis, dashboards",
  "main": "dist/index.js",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc -p tsconfig.json",
    "start": "node dist/index.js",
    "migrate": "node scripts/migrate.js",
    "setup:whitebox": "node scripts/setup-whitebox.js",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@tmcw/togeojson": "^5.8.1",
    "@xmldom/xmldom": "^0.8.10",
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "jsonwebtoken": "^9.0.2",
    "jszip": "^3.10.1",
    "multer": "^1.4.5-lts.1",
    "pg": "^8.12.0",
    "shapefile": "^0.6.6",
    "sharp": "^0.33.5",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/bcryptjs": "^2.4.6",
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/jsonwebtoken": "^9.0.6",
    "@types/multer": "^1.4.11",
    "@types/node": "^20.14.9",
    "@types/pg": "^8.11.6",
    "tsx": "^4.16.2",
    "typescript": "^5.5.3"
  }
}
EOF

echo "Writing apps/api/Dockerfile ..."
cat > apps/api/Dockerfile <<'EOF'
FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
# Fetches the WhiteboxTools binary into ./bin — must run after `COPY . .`
# (needs scripts/setup-whitebox.js and jszip from node_modules), not as an
# npm postinstall hook (which would fire during the `npm install` above,
# before the source tree exists). setup:whitebox is deliberately non-fatal
# (see the script's own comments) — `mkdir -p bin` first guarantees the
# directory exists either way, so the later `COPY --from=build /app/bin`
# below never fails even if the download itself didn't succeed.
RUN mkdir -p bin && npm run setup:whitebox
RUN npm run build

FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
COPY --from=build /app/bin ./bin
COPY migrations ./migrations
COPY scripts ./scripts
EXPOSE 4000
# Run pending migrations (idempotent — tracked in the _migrations table, so
# already-applied ones are skipped) before starting the server, so schema
# changes land automatically on every deploy without a separate manual step.
CMD ["sh", "-c", "node scripts/migrate.js && node dist/index.js"]
EOF

echo "Writing .gitignore ..."
cat > .gitignore <<'EOF'
node_modules/
dist/
build/
.env
.env.local
*.log
.DS_Store
apps/api/bin/
EOF

echo "Writing apps/web/src/api/client.ts ..."
cat > apps/web/src/api/client.ts <<'EOF'
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
// 'image' = a single georeferenced raster produced server-side by a terrain
// tool (hillshade, ...), rendered as a MapLibre ImageSource rather than a
// tiled RasterSource — see MapCanvas.tsx.
export type ServiceType = "xyz" | "wms" | "wmts" | "wfs" | "arcgis" | "geojson" | "image";
export interface ServiceConfig {
  type: ServiceType;
  url?: string;
  tileSize?: number;
  attribution?: string;
  coordinates?: [number, number][];
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
  source: "upload" | "buffer" | "intersect" | "service" | "terrain";
  service: ServiceConfig | null;
  sort_order: number;
}
export interface Bbox {
  west: number;
  south: number;
  east: number;
  north: number;
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

  // Terrain (GeoLibre-style "Processing" tools, backed by WhiteboxTools — see
  // apps/api/src/lib/terrain.ts. Hillshade ships first; more (slope, aspect,
  // contours, watershed) follow the same pattern.)
  runHillshade: (mapId: string, params: { bbox: Bbox; azimuth?: number; altitude?: number; name?: string }) =>
    request<{ layer: LayerDto }>(`/api/maps/${mapId}/terrain/hillshade`, {
      method: "POST",
      body: JSON.stringify(params),
    }),

  // Dashboard
  aggregateField: (layerId: string, field: string) =>
    request<{ field: string; bars: AggregateBar[] }>(`/api/layers/${layerId}/aggregate?field=${encodeURIComponent(field)}`),

  // Public
  getSharedMap: (token: string) => request<{ map: MapDto; layers: LayerDto[] }>(`/api/public/maps/${token}`),
};
EOF

echo "Writing apps/web/src/components/MapCanvas.tsx ..."
cat > apps/web/src/components/MapCanvas.tsx <<'EOF'
import { useEffect, useRef } from "react";
import maplibregl, { LngLatBoundsLike, Map as MapLibreMap, MapLayerMouseEvent } from "maplibre-gl";
import { GeoFeature, GeoFeatureCollection, LayerDto } from "../api/client";

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

export default function MapCanvas({ layers, featuresByLayer, viewState, onViewStateChange, onFeatureClick, onBoundsChange }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const loadedRef = useRef(false);

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
    mapRef.current = map;
    return () => {
      map.remove();
      mapRef.current = null;
      loadedRef.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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
}
EOF

echo "Writing apps/web/src/components/TerrainPanel.tsx ..."
cat > apps/web/src/components/TerrainPanel.tsx <<'EOF'
import { useState } from "react";
import { api, Bbox } from "../api/client";

interface Props {
  mapId: string;
  bounds: Bbox | null;
  onCreated: () => void;
}

// Terrain analysis (GeoLibre-style "Processing" tools), backed by
// WhiteboxTools server-side — see apps/api/src/lib/terrain.ts. Unlike
// AnalysisPanel (buffer/intersect, which run against a selected vector
// layer), these tools run against "whatever DEM covers the current map
// view" — there's no selected layer involved, so this panel takes the
// live viewport bounds reported by MapCanvas instead of a layer prop.
export default function TerrainPanel({ mapId, bounds, onCreated }: Props) {
  const [azimuth, setAzimuth] = useState(315);
  const [altitude, setAltitude] = useState(45);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function runHillshade() {
    if (!bounds) return;
    setBusy(true);
    setError(null);
    try {
      await api.runHillshade(mapId, { bbox: bounds, azimuth, altitude });
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Hillshade failed.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="analysis-box">
      <p>
        Run terrain analysis on <b>the current map view</b>. Elevation data is fetched automatically for whatever's
        visible on screen — pan/zoom the map to the area you want first, then run a tool below. Results are added as
        a new raster layer on this map.
      </p>

      <h4>Hillshade</h4>
      <p className="muted-sm">
        Generates a shaded-relief raster from elevation data, showing terrain as if lit from a given sun position.
      </p>
      <div className="analysis-row">
        <label style={{ minWidth: 70 }}>Azimuth</label>
        <input
          type="number"
          min={0}
          max={360}
          step={5}
          value={azimuth}
          onChange={(e) => setAzimuth(parseFloat(e.target.value) || 0)}
        />
        <span className="muted-sm">° (sun direction)</span>
      </div>
      <div className="analysis-row">
        <label style={{ minWidth: 70 }}>Altitude</label>
        <input
          type="number"
          min={0}
          max={90}
          step={5}
          value={altitude}
          onChange={(e) => setAltitude(parseFloat(e.target.value) || 0)}
        />
        <span className="muted-sm">° (sun elevation)</span>
      </div>

      {!bounds ? (
        <div className="empty-note">Waiting for the map to finish loading…</div>
      ) : (
        <button className="btn btn-primary" disabled={busy} onClick={runHillshade}>
          {busy ? "Generating hillshade…" : "Run hillshade"}
        </button>
      )}

      {error && (
        <div className="auth-error" style={{ marginTop: 12 }}>
          {error}
        </div>
      )}

      <p className="muted-sm" style={{ marginTop: 22 }}>
        More terrain tools (slope, aspect, contours, watershed delineation) are coming soon.
      </p>
    </div>
  );
}
EOF

echo "Writing apps/web/src/pages/MapEditorPage.tsx ..."
cat > apps/web/src/pages/MapEditorPage.tsx <<'EOF'
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { api, Bbox, GeoFeature, GeoFeatureCollection, LayerDto, MapDto, MapVisibility } from "../api/client";
import MapCanvas from "../components/MapCanvas";
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

type BottomTab = "table" | "dashboard" | "analysis" | "terrain";

export default function MapEditorPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [map, setMap] = useState<MapDto | null>(null);
  const [role, setRole] = useState<string>("viewer");
  const [layers, setLayers] = useState<LayerDto[]>([]);
  const [featuresByLayer, setFeaturesByLayer] = useState<Record<string, GeoFeatureCollection>>({});
  const [visibleIds, setVisibleIds] = useState<Set<string>>(new Set());
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [tab, setTab] = useState<BottomTab>("table");
  const [bounds, setBounds] = useState<Bbox | null>(null);
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

  async function handleShare(visibility: MapVisibility) {
    if (!id) return;
    const { map } = await api.shareMap(id, visibility);
    setMap(map);
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
            layers={visibleLayers}
            featuresByLayer={featuresByLayer}
            viewState={map.view_state}
            onViewStateChange={(v) => api.updateMap(map.id, { view_state: v }).catch(() => {})}
            onFeatureClick={(layer, feature, lngLat) => setPopup({ layer, feature, lngLat })}
            onBoundsChange={setBounds}
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
              <TerrainPanel mapId={id!} bounds={bounds} onCreated={loadMap} />
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
EOF

echo "Writing DEPLOYMENT.md ..."
cat > DEPLOYMENT.md <<'EOF'
# Deploying GISNEXUS affordably

Three things need to go somewhere: the **frontend** (static files), the
**backend API** (a long-running Node process), and the **database**
(Postgres + PostGIS). This doc lays out a recommended stack for each budget
stage, with current pricing and sources. Prices below were checked in July
2026 — always confirm on the provider's pricing page before committing, since
these change.

## Recommended stack

| Component | Recommendation | Why |
|---|---|---|
| Frontend | **Cloudflare Pages** | Free, unmetered bandwidth, no "non-commercial only" restriction. |
| Backend API | **Render** (or Railway) | Simple git-push deploys, predictable pricing, no cold-start surprises on the paid tier. |
| Database | **Supabase** (Postgres + PostGIS) | PostGIS is a supported first-party extension; generous free tier to start. |
| File uploads (optional, for large layers) | **Cloudflare R2** | No egress fees — matters once people are viewing maps a lot. |

### Why not Vercel for the frontend?

Vercel's Hobby (free) plan is explicitly restricted to **non-commercial,
personal use** — see the fair-use guidelines linked from
[vercel.com/docs/plans/hobby](https://vercel.com/docs/plans/hobby). If
GISNEXUS is ever going to have real users or make money, Vercel Hobby isn't
licensed for that; you'd need Pro at $20/user/month. Cloudflare Pages has no
such restriction on its free tier, so it's the safer default even though
Vercel's developer experience is excellent — feel free to use Vercel if you
upgrade to Pro or stay strictly personal/non-commercial.

### Why Supabase over Neon or plain RDS?

PostGIS needs to be an available Postgres extension. Supabase documents and
supports enabling `postgis` directly
([supabase.com/docs/guides/database/extensions/postgis](https://supabase.com/docs/guides/database/extensions/postgis)).
Neon's PostGIS support has historically been more limited. If you'd rather
self-manage, any Postgres 14+ with PostGIS works — Render and Railway also
offer managed Postgres, just without a guarantee that PostGIS is preloaded
(check before committing).

## Cost by stage

### Stage 1 — Demo / just you (target: $0/month)

- **Frontend:** Cloudflare Pages Free — 500 builds/month, unmetered bandwidth,
  up to 20,000 files per site.
  ([developers.cloudflare.com/pages/platform/limits](https://developers.cloudflare.com/pages/platform/limits/))
- **Backend:** Render's free Web Service tier — 512MB RAM / 0.1 CPU. It
  **spins down after inactivity** and cold-starts on the next request (a few
  seconds delay), which is fine for a demo, not for real users.
  ([render.com/pricing](https://render.com/pricing))
- **Database:** Supabase Free — 500MB database, 1GB file storage, 5GB egress,
  50,000 monthly active users cap. ([supabase.com/pricing](https://supabase.com/pricing))
- **File storage:** Cloudflare R2 Free — 10GB storage, 1M Class A ops/month,
  10M Class B ops/month, zero egress fees.
  ([developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/))

**Total: $0/month.** Good for showing people the product and personal use.
The tradeoff is the backend's cold start and the database's 500MB cap
(roughly a few hundred thousand small features, depending on geometry
complexity).

### Stage 2 — Small team / early real users (target: ~$12–19/month)

- **Frontend:** Cloudflare Pages Free — still free at this scale.
- **Backend:** Render Starter — **$7/month**, 512MB RAM / 0.5 CPU, always-on
  (no cold starts). ([render.com/pricing](https://render.com/pricing))
- **Database:** Supabase Free, or move to **Pro at $25/month** once you're
  past 500MB or need daily backups (Pro includes 8GB disk + $10/month of
  compute credit covering one "Micro" instance).
  ([supabase.com/pricing](https://supabase.com/pricing))
- **File storage:** Cloudflare R2 Free tier still likely covers this stage.

**Total: ~$7–32/month** depending on whether you've upgraded the database yet.

### Stage 3 — Growing usage (target: ~$45–80/month)

- **Frontend:** still free on Cloudflare Pages — frontend hosting rarely
  becomes the expensive part.
- **Backend:** Render Standard tier, or move to **Railway** if you want
  usage-based billing instead of fixed tiers — Railway's Hobby plan is
  **$5/month** including $5 of usage credit, billed beyond that at
  **$10/GB RAM/month, $20/vCPU/month, $0.05/GB egress, $0.15/GB storage/month**.
  ([docs.railway.com/pricing/plans](https://docs.railway.com/pricing/plans))
- **Database:** Supabase Pro ($25/month) is usually enough until you're at a
  genuinely large dataset (past 8GB, extra disk is $0.125/GB/month; past
  250GB egress, $0.09/GB).
- **File storage:** Cloudflare R2 usage-based beyond the free tier: **$0.015/GB-
  month storage**, **$4.50/million Class A requests** (writes/lists),
  **$0.36/million Class B requests** (reads), **still $0 egress**.
  ([developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/))

**Total: ~$45–80/month** — this is the range where you'd also start
considering Fly.io if you want the backend running physically close to your
users (Fly's shared-cpu-1x VMs run roughly **$1.94–10.70/month** depending on
RAM, but Fly no longer offers a real free tier for new accounts as of the
2024–2026 pricing changes — budget for it from day one if you go that route).
([fly.io/docs/about/pricing](https://fly.io/docs/about/pricing/))

## Step-by-step: Stage 1/2 deployment

### 1. Database — Supabase

1. Create a project at [supabase.com](https://supabase.com).
2. In the dashboard, go to **Database → Extensions**, search "postgis", and
   enable it.
3. Go to **Project Settings → Database → Connection string**, copy the URI
   (use "Session" mode pooling for a simple Node app).
4. Locally (or from a one-off Render/Railway shell), run the migration
   against that connection string:
   ```bash
   DATABASE_URL="<your supabase connection string>" npm run migrate --workspace=apps/api
   ```

### 2. Backend — Render

1. Push this repo to GitHub.
2. In Render, **New → Web Service**, connect the repo, set the root directory
   to `apps/api`.
3. Build command: `npm install && npm run setup:whitebox && npm run build`.
   Start command: `npm run migrate && npm start`. (`setup:whitebox` downloads
   the open-source WhiteboxTools binary the terrain-analysis endpoints shell
   out to — see `apps/api/scripts/setup-whitebox.js`. It's non-fatal if it
   fails, so leaving it out of the build command just means terrain
   endpoints return a clear 503 instead of working; everything else is
   unaffected. **If your service is actually deploying via
   `apps/api/Dockerfile`** instead of this native build command — Render
   auto-detects a Dockerfile if present — this step is already baked into
   the image and you don't need to touch the dashboard's Build command at
   all.)
4. Set environment variables: `DATABASE_URL` (from Supabase),
   `JWT_SECRET` (generate with `openssl rand -hex 32`), `CORS_ORIGIN` (your
   frontend's URL, added after step 3), `PORT=4000` (Render sets `PORT`
   automatically — you can omit this and let Render inject it, since the API
   reads `process.env.PORT`).
5. Deploy. Note the resulting `https://your-api.onrender.com` URL.

### 3. Frontend — Cloudflare Pages

1. In the Cloudflare dashboard, **Workers & Pages → Create → Pages → Connect
   to Git**, select this repo.
2. Build settings: root directory `apps/web`, build command `npm run build`,
   output directory `dist`.
3. Environment variable: `VITE_API_URL` = your Render API URL from step 2.
4. Deploy. Cloudflare gives you a `*.pages.dev` URL (custom domains are free
   to attach).
5. Go back to Render and set `CORS_ORIGIN` to this Cloudflare Pages URL, then
   redeploy the API so the browser is allowed to call it.

### Alternative: deploying the frontend from the CLI

If you'd rather push a build manually instead of connecting Git, run this
from `apps/web`:

```bash
npm run deploy   # = vite build, then: wrangler pages deploy dist --project-name=gisnexus-app
```

The first run will prompt you to log in (`wrangler login`) and to
confirm/create the `gisnexus-app` Pages project.

Use `wrangler pages deploy`, not the newer unified `wrangler deploy` —
`wrangler deploy` auto-detects any `vite.config.ts` in the directory and
routes through its Vite-plugin integration, which currently hard-requires
Vite 6+ regardless of whether a `wrangler.jsonc` is present. `wrangler pages
deploy` is the older, purpose-built Pages command: it just uploads the built
`dist/` folder and never touches that check, so it works fine on this
project's Vite 5 setup.

Client-side routing (react-router) is handled by `apps/web/public/_redirects`
(`/* /index.html 200`), which Vite copies into `dist/` on every build — this
is what makes a direct visit or refresh on a route like `/maps/:id` resolve
instead of 404ing, standing in for the `not_found_handling:
single-page-application` setting that only applies to the Workers-assets
deploy path.

### 4. Smoke test

Visit your Cloudflare Pages URL, register an account, create a map, and
upload a small GeoJSON or CSV file. If the map doesn't load features, check
the browser console for CORS errors first (almost always a `CORS_ORIGIN`
mismatch) and the Render logs second (almost always a `DATABASE_URL` or
missing-PostGIS-extension issue).

## A note on cost discipline

All of the providers above bill primarily on usage past a threshold, not
flat enterprise contracts — so the "Total" numbers here are ceilings you set
by your own plan choice, not surprise bills, with one exception: Supabase's
Pro tier egress and Cloudflare R2's Class A/B operations are genuinely
usage-based and could grow with traffic. Set up billing alerts on both from
day one.
EOF

echo ""
echo "Done writing files. Now review, install, build, and push:"
echo ""
echo "  git status"
echo "  git diff --stat"
echo "  npm install                                  # picks up sharp in apps/api"
echo "  npm run build --workspace=apps/api"
echo "  npm run build --workspace=apps/web"
echo "  npm run setup:whitebox --workspace=apps/api   # only needed for LOCAL testing;"
echo "                                                 # Render/Docker run this at deploy time"
echo "  git add -A"
echo '  git commit -m "Add terrain analysis (Hillshade via WhiteboxTools)"'
echo "  git push"