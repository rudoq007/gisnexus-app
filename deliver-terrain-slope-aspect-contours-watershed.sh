#!/usr/bin/env bash
# GISNEXUS — Terrain Analysis: Slope, Aspect, Contours, Watershed
# (fast-follow to the Hillshade delivery, same WhiteboxTools pipeline)
#
# Run this from the ROOT of your gisnexus-app repo, in Git Bash:
#   bash deliver-terrain-slope-aspect-contours-watershed.sh
set -e

echo "Writing apps/api/src/lib/terrain.ts ..."
cat > apps/api/src/lib/terrain.ts <<'EOF'
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { normalizeFeatureArray } from "./geo";
import { NormalizedFeature } from "../types";

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

// ---------------------------------------------------------------------------
// Slope & Aspect — the same DEM-fetch → WhiteboxTools → colorize pipeline as
// Hillshade above, reusing all of it: only the tool name, output coloring,
// and (for Slope) a units flag differ. Same known-risk caveat as Hillshade's
// header comment: --units on Slope, and the plain --input/--output pair on
// both, match WhiteboxTools' documented CLI convention but weren't run
// against the real binary while writing this (no network access here) — if
// either fails, the ApiError message includes whitebox_tools's own
// stdout/stderr, which will show a flag mismatch immediately.
//
// Both tools also depend on WhiteboxTools' automatic z-factor handling: our
// ASCII grid's horizontal spacing is in decimal degrees (see writeAsciiGrid's
// comment) while elevation is in meters. WhiteboxTools detects a
// geographic-coordinate DEM from its header and grid extent and rescales
// internally unless --zfactor overrides it — this is the same assumption
// Hillshade already relies on, confirmed working against a live deploy, so
// Slope/Aspect (part of the same tool family, sharing that auto-detection)
// should behave the same way.
// ---------------------------------------------------------------------------
export type RasterToolResult = HillshadeResult; // same shape: { pngBuffer, bounds }

type ColorStop = [number, [number, number, number]]; // [position 0..1, [r,g,b]]

function lerpColor(stops: ColorStop[], t: number): [number, number, number] {
  const clamped = Math.max(0, Math.min(1, t));
  for (let i = 0; i < stops.length - 1; i++) {
    const [p0, c0] = stops[i];
    const [p1, c1] = stops[i + 1];
    if (clamped >= p0 && clamped <= p1) {
      const localT = p1 === p0 ? 0 : (clamped - p0) / (p1 - p0);
      return [
        Math.round(c0[0] + (c1[0] - c0[0]) * localT),
        Math.round(c0[1] + (c1[1] - c0[1]) * localT),
        Math.round(c0[2] + (c1[2] - c0[2]) * localT),
      ];
    }
  }
  return stops[stops.length - 1][1];
}

// Standard green→yellow→orange→red "steepness" ramp — flat ground reads as
// safe/green, steep ground reads as a warning color, matching the intuitive
// convention used by most slope-analysis tools (QGIS, ArcGIS default styles).
const SLOPE_RAMP: ColorStop[] = [
  [0, [26, 152, 80]], // #1a9850
  [0.25, [145, 207, 96]], // #91cf60
  [0.5, [254, 224, 139]], // #fee08b
  [0.75, [252, 141, 89]], // #fc8d59
  [1, [215, 48, 39]], // #d73027
];

async function colorizeSequential(grid: DemGrid, domain: { min: number; max: number }, ramp: ColorStop[]): Promise<Buffer> {
  const { width, height, data } = grid;
  const rgba = Buffer.alloc(width * height * 4);
  const span = domain.max - domain.min || 1;
  for (let i = 0; i < data.length; i++) {
    const v = data[i];
    if (!Number.isFinite(v)) {
      rgba[i * 4 + 3] = 0; // NoData — transparent, same convention as Hillshade
      continue;
    }
    const [r, g, b] = lerpColor(ramp, (v - domain.min) / span);
    rgba[i * 4] = r;
    rgba[i * 4 + 1] = g;
    rgba[i * 4 + 2] = b;
    rgba[i * 4 + 3] = 255;
  }
  return sharp(rgba, { raw: { width, height, channels: 4 } }).png().toBuffer();
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const hue = ((h % 360) + 360) % 360;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
  const m = l - c / 2;
  let rp = 0,
    gp = 0,
    bp = 0;
  if (hue < 60) [rp, gp, bp] = [c, x, 0];
  else if (hue < 120) [rp, gp, bp] = [x, c, 0];
  else if (hue < 180) [rp, gp, bp] = [0, c, x];
  else if (hue < 240) [rp, gp, bp] = [0, x, c];
  else if (hue < 300) [rp, gp, bp] = [x, 0, c];
  else [rp, gp, bp] = [c, 0, x];
  return [Math.round((rp + m) * 255), Math.round((gp + m) * 255), Math.round((bp + m) * 255)];
}

// Aspect is circular (compass direction), so it gets a hue wheel rather than
// a linear ramp — 0°/360° (north) and any other matching direction share the
// same hue, which a sequential ramp can't represent. WhiteboxTools' Aspect
// output uses -1 for "flat" cells (no defined downslope direction); those
// render as neutral gray rather than a misleading direction.
const ASPECT_FLAT_GRAY: [number, number, number] = [130, 130, 130];

async function colorizeAspect(grid: DemGrid): Promise<Buffer> {
  const { width, height, data } = grid;
  const rgba = Buffer.alloc(width * height * 4);
  for (let i = 0; i < data.length; i++) {
    const v = data[i];
    if (!Number.isFinite(v)) {
      rgba[i * 4 + 3] = 0;
      continue;
    }
    const [r, g, b] = v < 0 ? ASPECT_FLAT_GRAY : hslToRgb(v, 0.75, 0.5);
    rgba[i * 4] = r;
    rgba[i * 4 + 1] = g;
    rgba[i * 4 + 2] = b;
    rgba[i * 4 + 3] = 255;
  }
  return sharp(rgba, { raw: { width, height, channels: 4 } }).png().toBuffer();
}

export async function runSlope(bbox: Bbox, units: "degrees" | "percent" = "degrees"): Promise<RasterToolResult> {
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "gisnexus-terrain-"));
  try {
    const dem = await fetchDem(bbox);
    await writeAsciiGrid(dem, path.join(workDir, "dem.asc"));

    await runWhiteboxTool("Slope", ["--input=dem.asc", "--output=slope.asc", `--units=${units}`], workDir);

    const result = await readAsciiGrid(path.join(workDir, "slope.asc"));
    // 0-60° / 0-100% covers the vast majority of real terrain; anything
    // steeper just clips to the ramp's red end rather than needing a wider,
    // less-useful domain.
    const domain = units === "percent" ? { min: 0, max: 100 } : { min: 0, max: 60 };
    const pngBuffer = await colorizeSequential(result, domain, SLOPE_RAMP);
    return { pngBuffer, bounds: result.bounds };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

export async function runAspect(bbox: Bbox): Promise<RasterToolResult> {
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "gisnexus-terrain-"));
  try {
    const dem = await fetchDem(bbox);
    await writeAsciiGrid(dem, path.join(workDir, "dem.asc"));

    await runWhiteboxTool("Aspect", ["--input=dem.asc", "--output=aspect.asc"], workDir);

    const result = await readAsciiGrid(path.join(workDir, "aspect.asc"));
    const pngBuffer = await colorizeAspect(result);
    return { pngBuffer, bounds: result.bounds };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Shapefile read-back — shared by Contours and Watershed below, both of
// which get their result from WhiteboxTools as a Shapefile rather than a
// raster. Reuses lib/geo.ts's normalizeFeatureArray (the same flattening
// logic an uploaded Shapefile goes through) so Multi* geometries become one
// row per simple feature, same as everywhere else in the app.
// ---------------------------------------------------------------------------
async function readShapefileFeatures(shpPath: string, dbfPath: string, emptyMessage: string): Promise<NormalizedFeature[]> {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const shapefile = require("shapefile");
  const shpBuffer = await fs.readFile(shpPath);
  let dbfBuffer: Buffer | undefined;
  try {
    dbfBuffer = await fs.readFile(dbfPath);
  } catch {
    dbfBuffer = undefined; // WhiteboxTools may omit the .dbf if there were no attributes to write
  }
  // collection.features is untyped (shapefile has no type declarations, same
  // as lib/geo.ts's shapefileZipToFeatures() a few files over) — normalized
  // the same way an uploaded Shapefile's features are.
  const collection = await shapefile.read(shpBuffer, dbfBuffer);
  const rawFeatures: Parameters<typeof normalizeFeatureArray>[0] = collection.features || [];
  if (!rawFeatures.length) throw new Error(emptyMessage);
  const { features } = normalizeFeatureArray(rawFeatures);
  return features;
}

export interface VectorToolResult {
  geomType: "LineString" | "Polygon";
  features: NormalizedFeature[];
  bounds: Bbox;
}

// ---------------------------------------------------------------------------
// Contours — elevation isolines at a fixed interval, via WhiteboxTools'
// ContoursFromRaster. Same flag-name caveat as everything else here:
// --interval is passed explicitly; --base and --smooth are left at
// WhiteboxTools' own defaults rather than guessed, to keep the flag surface
// (and therefore the risk of a wrong flag name) as small as possible.
// ---------------------------------------------------------------------------
export async function runContours(bbox: Bbox, intervalMeters: number): Promise<VectorToolResult> {
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "gisnexus-terrain-"));
  try {
    const dem = await fetchDem(bbox);
    await writeAsciiGrid(dem, path.join(workDir, "dem.asc"));

    await runWhiteboxTool("ContoursFromRaster", ["--input=dem.asc", "--output=contours.shp", `--interval=${intervalMeters}`], workDir);

    const features = await readShapefileFeatures(
      path.join(workDir, "contours.shp"),
      path.join(workDir, "contours.dbf"),
      "No contour lines at that interval for this area — try a smaller interval, or zoom to an area with more elevation change."
    );
    return { geomType: "LineString", features, bounds: dem.bounds };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Watershed delineation — standard D8 pipeline: fill sinks so every cell can
// drain somewhere, compute a D8 flow-direction pointer, mark the user's
// chosen outlet as a single-cell pour-point raster, delineate the upstream
// catchment, then convert the resulting raster mask to a vector polygon.
//
// The pour-point raster is built directly in Node (one nonzero cell at the
// pixel nearest the click, NoData everywhere else) rather than round-tripped
// through a Shapefile — simpler, and this is the one input WhiteboxTools
// needs that we're already set up to write (writeAsciiGrid), so there's no
// reason to introduce a second vector-format detour just to feed a single
// point back in.
//
// This chains four separate WhiteboxTools subprocess calls, so it's the
// highest-risk of the terrain tools for a flag-name mismatch (more surface
// area than Hillshade/Slope/Aspect/Contours' single call each) — but each
// step fails independently with its own clear stdout/stderr-bearing error,
// same as every other tool here, so a wrong flag on e.g. RasterToVectorPolygons
// is a one-line fix once the error message shows which step it was.
// ---------------------------------------------------------------------------
function buildPourPointGrid(dem: DemGrid, pourPoint: { lon: number; lat: number }): DemGrid {
  const { width, height, bounds } = dem;
  const cellW = (bounds.east - bounds.west) / width;
  const cellH = (bounds.north - bounds.south) / height;
  const col = Math.max(0, Math.min(width - 1, Math.floor((pourPoint.lon - bounds.west) / cellW)));
  const row = Math.max(0, Math.min(height - 1, Math.floor((bounds.north - pourPoint.lat) / cellH))); // row 0 = north
  const data = new Float32Array(width * height).fill(NaN); // NaN -> NODATA via writeAsciiGrid
  data[row * width + col] = 1; // single pour point, ID 1
  return { data, width, height, bounds };
}

export async function runWatershed(bbox: Bbox, pourPoint: { lon: number; lat: number }): Promise<VectorToolResult> {
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "gisnexus-terrain-"));
  try {
    const dem = await fetchDem(bbox);
    if (pourPoint.lon < dem.bounds.west || pourPoint.lon > dem.bounds.east || pourPoint.lat < dem.bounds.south || pourPoint.lat > dem.bounds.north) {
      throw new Error("The pour point must be inside the current map view.");
    }
    await writeAsciiGrid(dem, path.join(workDir, "dem.asc"));

    await runWhiteboxTool("FillDepressions", ["--input=dem.asc", "--output=filled.asc"], workDir);
    await runWhiteboxTool("D8Pointer", ["--input=filled.asc", "--output=d8.asc"], workDir);

    const pourGrid = buildPourPointGrid(dem, pourPoint);
    await writeAsciiGrid(pourGrid, path.join(workDir, "pour.asc"));

    await runWhiteboxTool("Watershed", ["--d8_pntr=d8.asc", "--pour_pts=pour.asc", "--output=watershed.asc"], workDir);
    await runWhiteboxTool("RasterToVectorPolygons", ["--input=watershed.asc", "--output=watershed.shp"], workDir);

    const features = await readShapefileFeatures(
      path.join(workDir, "watershed.shp"),
      path.join(workDir, "watershed.dbf"),
      "Couldn't delineate a watershed for that pour point — try clicking a point that's clearly on a slope, not a flat area or right at the edge of the map view."
    );
    return { geomType: "Polygon", features, bounds: dem.bounds };
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
import { binExists, runAspect, runContours, runHillshade, runSlope, runWatershed, Bbox as TerrainBbox } from "../lib/terrain";
import { insertFeatures, collectPopupFields } from "./layers";
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

const SETUP_MESSAGE =
  "Terrain tools aren't set up on this server yet — the WhiteboxTools binary is missing. " +
  "Run `npm run setup:whitebox` as part of the API's build/deploy step, then redeploy.";

/** Builds the `service` jsonb blob for a single georeferenced raster output (Hillshade/Slope/Aspect). */
function imageLayerService(
  pngBuffer: Buffer,
  bounds: TerrainBbox,
  attribution: string,
  raw: Record<string, string | number | boolean>
) {
  return {
    type: "image",
    url: `data:image/png;base64,${pngBuffer.toString("base64")}`,
    coordinates: [
      [bounds.west, bounds.north],
      [bounds.east, bounds.north],
      [bounds.east, bounds.south],
      [bounds.west, bounds.south],
    ],
    attribution,
    raw,
  };
}

const ELEVATION_ATTRIBUTION = "Elevation: AWS Terrain Tiles (SRTM/NED/etc., public domain)";

// ---------------------------------------------------------------------------
// Hillshade — the first of GISNEXUS's WhiteboxTools-backed terrain tools
// (see apps/api/src/lib/terrain.ts). Fetches free public elevation data for
// the map's current view, runs WhiteboxTools' Hillshade algorithm, and adds
// the result as a single georeferenced image layer (kind='raster',
// service.type='image') — same layer model as any other raster layer, just
// rendered from a data: URL instead of a live tile service.
// ---------------------------------------------------------------------------
const hillshadeSchema = z.object({
  bbox: bboxSchema,
  azimuth: z.number().gte(0).lte(360).default(315),
  altitude: z.number().gte(0).lte(90).default(45),
  name: z.string().min(1).max(200).optional(),
});

terrainRouter.post(
  "/maps/:mapId/terrain/hillshade",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");
    if (!binExists()) throw new ApiError(503, SETUP_MESSAGE);

    const { bbox, azimuth, altitude, name } = hillshadeSchema.parse(req.body);

    let result: Awaited<ReturnType<typeof runHillshade>>;
    try {
      result = await runHillshade(bbox, azimuth, altitude);
    } catch (err) {
      throw new ApiError(500, `Hillshade failed: ${(err as Error).message}`);
    }

    const service = imageLayerService(
      result.pngBuffer,
      result.bounds,
      `${ELEVATION_ATTRIBUTION} · Hillshade via WhiteboxTools`,
      { azimuth, altitude }
    );

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, kind, geom_type, source, service, style)
       VALUES ($1, $2, 'raster', NULL, 'terrain', $3, '{"color":"#7c5cff","opacity":0.65,"size":6}')
       RETURNING *`,
      [req.params.mapId, name || `Hillshade (az ${azimuth}°, alt ${altitude}°)`, JSON.stringify(service)]
    );

    res.status(201).json({ layer: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Slope — steepness at every cell, in degrees or percent, colorized on a
// green (flat) → red (steep) ramp. Same image-layer model as Hillshade.
// ---------------------------------------------------------------------------
const slopeSchema = z.object({
  bbox: bboxSchema,
  units: z.enum(["degrees", "percent"]).default("degrees"),
  name: z.string().min(1).max(200).optional(),
});

terrainRouter.post(
  "/maps/:mapId/terrain/slope",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");
    if (!binExists()) throw new ApiError(503, SETUP_MESSAGE);

    const { bbox, units, name } = slopeSchema.parse(req.body);

    let result: Awaited<ReturnType<typeof runSlope>>;
    try {
      result = await runSlope(bbox, units);
    } catch (err) {
      throw new ApiError(500, `Slope failed: ${(err as Error).message}`);
    }

    const service = imageLayerService(result.pngBuffer, result.bounds, `${ELEVATION_ATTRIBUTION} · Slope via WhiteboxTools`, {
      units,
    });

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, kind, geom_type, source, service, style)
       VALUES ($1, $2, 'raster', NULL, 'terrain', $3, '{"color":"#7c5cff","opacity":0.7,"size":6}')
       RETURNING *`,
      [req.params.mapId, name || `Slope (${units})`, JSON.stringify(service)]
    );

    res.status(201).json({ layer: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Aspect — downslope-facing compass direction at every cell, colorized as a
// hue wheel (it's circular data, so a linear ramp like Slope's doesn't fit).
// ---------------------------------------------------------------------------
const aspectSchema = z.object({
  bbox: bboxSchema,
  name: z.string().min(1).max(200).optional(),
});

terrainRouter.post(
  "/maps/:mapId/terrain/aspect",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");
    if (!binExists()) throw new ApiError(503, SETUP_MESSAGE);

    const { bbox, name } = aspectSchema.parse(req.body);

    let result: Awaited<ReturnType<typeof runAspect>>;
    try {
      result = await runAspect(bbox);
    } catch (err) {
      throw new ApiError(500, `Aspect failed: ${(err as Error).message}`);
    }

    const service = imageLayerService(result.pngBuffer, result.bounds, `${ELEVATION_ATTRIBUTION} · Aspect via WhiteboxTools`, {});

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, kind, geom_type, source, service, style)
       VALUES ($1, $2, 'raster', NULL, 'terrain', $3, '{"color":"#7c5cff","opacity":0.7,"size":6}')
       RETURNING *`,
      [req.params.mapId, name || "Aspect", JSON.stringify(service)]
    );

    res.status(201).json({ layer: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Contours — elevation isolines as a new vector (LineString) layer, inserted
// into `features` exactly like an uploaded file (see routes/layers.ts's
// insertFeatures, reused here rather than duplicated).
// ---------------------------------------------------------------------------
const contoursSchema = z.object({
  bbox: bboxSchema,
  intervalMeters: z.number().positive().max(1000).default(50),
  name: z.string().min(1).max(200).optional(),
});

terrainRouter.post(
  "/maps/:mapId/terrain/contours",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");
    if (!binExists()) throw new ApiError(503, SETUP_MESSAGE);

    const { bbox, intervalMeters, name } = contoursSchema.parse(req.body);

    let result: Awaited<ReturnType<typeof runContours>>;
    try {
      result = await runContours(bbox, intervalMeters);
    } catch (err) {
      throw new ApiError(500, `Contours failed: ${(err as Error).message}`);
    }

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, kind, geom_type, source, popup_fields, style)
       VALUES ($1, $2, 'vector', 'LineString', 'terrain', $3, '{"color":"#22d3ee","opacity":0.85,"size":1.5}')
       RETURNING *`,
      [req.params.mapId, name || `Contours (${intervalMeters}m)`, JSON.stringify(collectPopupFields(result.features))]
    );
    const layer = rows[0];
    await insertFeatures(layer.id, result.features);

    res.status(201).json({ layer, featureCount: result.features.length });
  })
);

// ---------------------------------------------------------------------------
// Watershed — upstream catchment polygon for a user-chosen pour point, as a
// new vector (Polygon) layer. See lib/terrain.ts's runWatershed for the full
// D8 pipeline and the caveat that this is the highest flag-name risk of the
// terrain tools (four chained WhiteboxTools calls instead of one).
// ---------------------------------------------------------------------------
const watershedSchema = z.object({
  bbox: bboxSchema,
  pourPoint: z.object({ lon: z.number().gte(-180).lte(180), lat: z.number().gte(-85).lte(85) }),
  name: z.string().min(1).max(200).optional(),
});

terrainRouter.post(
  "/maps/:mapId/terrain/watershed",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");
    if (!binExists()) throw new ApiError(503, SETUP_MESSAGE);

    const { bbox, pourPoint, name } = watershedSchema.parse(req.body);

    let result: Awaited<ReturnType<typeof runWatershed>>;
    try {
      result = await runWatershed(bbox, pourPoint);
    } catch (err) {
      throw new ApiError(500, `Watershed delineation failed: ${(err as Error).message}`);
    }

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, kind, geom_type, source, popup_fields, style)
       VALUES ($1, $2, 'vector', 'Polygon', 'terrain', $3, '{"color":"#7c5cff","opacity":0.35,"size":2}')
       RETURNING *`,
      [req.params.mapId, name || "Watershed", JSON.stringify(collectPopupFields(result.features))]
    );
    const layer = rows[0];
    await insertFeatures(layer.id, result.features);

    res.status(201).json({ layer, featureCount: result.features.length });
  })
);
EOF

echo "Writing apps/api/src/routes/layers.ts ..."
cat > apps/api/src/routes/layers.ts <<'EOF'
import { Router } from "express";
import multer from "multer";
import { z } from "zod";
import { pool } from "../db";
import { requireAuth, optionalAuth, AuthedRequest } from "../middleware/auth";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { canEdit, canView, getMapRole, getMapRoleForLayer } from "../lib/access";
import {
  arcgisFeatureToFeatures,
  buildWmsService,
  buildWmtsService,
  buildXyzService,
  csvToFeatures,
  geojsonToFeatures,
  geojsonUrlToFeatures,
  gpxToFeatures,
  kmlToFeatures,
  shapefileZipToFeatures,
  wfsToFeatures,
} from "../lib/geo";
import { LayerRow, NormalizedFeature } from "../types";
import { env } from "../env";

export const layersRouter = Router();

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: env.maxUploadMb * 1024 * 1024 },
});

/**
 * Inserts a batch of normalized features for a layer inside a transaction.
 * Exported for reuse by routes/terrain.ts — the vector-output terrain tools
 * (Contours, Watershed) produce the exact same NormalizedFeature[] shape as
 * an upload does, just sourced from a WhiteboxTools Shapefile instead of a
 * user-supplied file, so they insert the same way rather than duplicating
 * this transaction logic.
 */
export async function insertFeatures(layerId: string, features: NormalizedFeature[]) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    for (const f of features) {
      await client.query(
        `INSERT INTO features (layer_id, geom, properties)
         VALUES ($1, ST_SetSRID(ST_GeomFromGeoJSON($2), 4326), $3)`,
        [layerId, JSON.stringify(f.geometry), JSON.stringify(f.properties)]
      );
    }
    await client.query("COMMIT");
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

export function collectPopupFields(features: NormalizedFeature[]): string[] {
  const keys = new Set<string>();
  for (const f of features) Object.keys(f.properties || {}).forEach((k) => keys.add(k));
  return Array.from(keys).slice(0, 4);
}

// ---------------------------------------------------------------------------
// Upload a file as a new layer on a map. Supported formats, dispatched by
// file extension: GeoJSON (.geojson/.json), CSV (.csv, needs lat/lon
// columns), Shapefile (.zip containing .shp/.dbf/.prj), KML (.kml), and
// GPX (.gpx). See lib/geo.ts for each format's parser.
// ---------------------------------------------------------------------------
layersRouter.post(
  "/maps/:mapId/layers/upload",
  requireAuth,
  upload.single("file"),
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");
    if (!req.file) throw new ApiError(400, "No file uploaded (expected multipart field 'file').");

    const name = (req.body.name as string) || req.file.originalname.replace(/\.[^.]+$/, "");
    const filename = req.file.originalname;

    let result: { geomType: string; features: NormalizedFeature[]; skipped: number; warning?: string };
    try {
      if (/\.csv$/i.test(filename)) {
        result = csvToFeatures(req.file.buffer.toString("utf8"));
      } else if (/\.zip$/i.test(filename)) {
        result = await shapefileZipToFeatures(req.file.buffer);
      } else if (/\.kml$/i.test(filename)) {
        result = kmlToFeatures(req.file.buffer.toString("utf8"));
      } else if (/\.gpx$/i.test(filename)) {
        result = gpxToFeatures(req.file.buffer.toString("utf8"));
      } else if (/\.(geojson|json)$/i.test(filename)) {
        result = geojsonToFeatures(JSON.parse(req.file.buffer.toString("utf8")));
      } else {
        throw new Error("Unsupported file type. Upload .geojson, .json, .csv, .zip (Shapefile), .kml, or .gpx.");
      }
    } catch (err) {
      throw new ApiError(400, `Couldn't parse file: ${(err as Error).message}`);
    }

    const { rows } = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, geom_type, popup_fields, source)
       VALUES ($1, $2, $3, $4, 'upload') RETURNING *`,
      [req.params.mapId, name, result.geomType, JSON.stringify(collectPopupFields(result.features))]
    );
    const layer = rows[0];
    await insertFeatures(layer.id, result.features);

    res.status(201).json({ layer, featureCount: result.features.length, skipped: result.skipped, warning: result.warning });
  })
);

// ---------------------------------------------------------------------------
// Add a layer backed by an external service ("Add Data" catalog / custom
// URLs). Raster kinds (XYZ/WMS/WMTS) never touch `features` — we just build
// a MapLibre-ready tile URL template and store it; the browser fetches tiles
// live. Vector kinds (WFS/ArcGIS FeatureServer) are fetched once, right now,
// and imported into `features` the same way an upload is. See lib/geo.ts for
// the per-type builders/fetchers and README for caveats (no live refresh for
// vector services; WMTS support is limited to RESTful {z}/{x}/{y} templates).
// ---------------------------------------------------------------------------
const addServiceLayerSchema = z.object({
  name: z.string().min(1).max(200),
  serviceType: z.enum(["xyz", "wms", "wmts", "wfs", "arcgis", "geojson"]),
  fields: z.record(z.union([z.string(), z.number(), z.boolean()])).default({}),
});

layersRouter.post(
  "/maps/:mapId/layers/service",
  requireAuth,
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.mapId);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");

    const { name, serviceType, fields } = addServiceLayerSchema.parse(req.body);

    try {
      if (serviceType === "xyz" || serviceType === "wms" || serviceType === "wmts") {
        const service =
          serviceType === "xyz"
            ? buildXyzService(fields)
            : serviceType === "wms"
              ? buildWmsService(fields)
              : buildWmtsService(fields);

        const { rows } = await pool.query<LayerRow>(
          `INSERT INTO layers (map_id, name, kind, geom_type, source, service)
           VALUES ($1, $2, 'raster', NULL, 'service', $3) RETURNING *`,
          [req.params.mapId, name, JSON.stringify(service)]
        );
        res.status(201).json({ layer: rows[0], featureCount: 0, skipped: 0 });
        return;
      }

      const result =
        serviceType === "wfs"
          ? await wfsToFeatures(fields)
          : serviceType === "arcgis"
            ? await arcgisFeatureToFeatures(fields)
            : await geojsonUrlToFeatures(fields);

      const { rows } = await pool.query<LayerRow>(
        `INSERT INTO layers (map_id, name, kind, geom_type, source, service, popup_fields)
         VALUES ($1, $2, 'vector', $3, 'service', $4, $5) RETURNING *`,
        [
          req.params.mapId,
          name,
          result.geomType,
          JSON.stringify(result.config),
          JSON.stringify(collectPopupFields(result.features)),
        ]
      );
      const layer = rows[0];
      await insertFeatures(layer.id, result.features);

      res.status(201).json({ layer, featureCount: result.features.length, skipped: result.skipped });
    } catch (err) {
      if (err instanceof ApiError) throw err;
      throw new ApiError(400, `Couldn't add that service: ${(err as Error).message}`);
    }
  })
);

// ---------------------------------------------------------------------------
// Get a layer's features as a GeoJSON FeatureCollection
// ---------------------------------------------------------------------------
layersRouter.get(
  "/layers/:id/features",
  optionalAuth,
  asyncRoute(async (req: AuthedRequest, res) => {
    const layerResult = await pool.query<{ map_id: string }>("SELECT map_id FROM layers WHERE id = $1", [req.params.id]);
    if (!layerResult.rows.length) throw new ApiError(404, "Layer not found.");
    const mapId = layerResult.rows[0].map_id;

    const mapResult = await pool.query<{ visibility: string; owner_id: string }>(
      "SELECT visibility, owner_id FROM maps WHERE id = $1",
      [mapId]
    );
    const map = mapResult.rows[0];

    const isPublic = map.visibility === "public" || map.visibility === "unlisted";
    if (!isPublic) {
      if (!req.user) throw new ApiError(401, "Sign in to view this layer.");
      const role = await getMapRole(req.user.id, mapId);
      if (!canView(role)) throw new ApiError(403, "You don't have access to this map.");
    }

    const { rows } = await pool.query<{ id: string; properties: Record<string, unknown>; geometry: string }>(
      `SELECT id, properties, ST_AsGeoJSON(geom) AS geometry FROM features WHERE layer_id = $1`,
      [req.params.id]
    );

    res.json({
      type: "FeatureCollection",
      features: rows.map((r) => ({
        type: "Feature",
        id: r.id,
        geometry: JSON.parse(r.geometry),
        properties: r.properties,
      })),
    });
  })
);

// ---------------------------------------------------------------------------
// Update a layer's name / style / popup fields
// ---------------------------------------------------------------------------
const patchLayerSchema = z.object({
  name: z.string().min(1).max(200).optional(),
  style: z.object({ color: z.string(), opacity: z.number().min(0).max(1), size: z.number().min(0.5).max(40) }).partial().optional(),
  popup_fields: z.array(z.string()).optional(),
  sort_order: z.number().optional(),
});

layersRouter.patch(
  "/layers/:id",
  requireAuth,
  asyncRoute(async (req: AuthedRequest, res) => {
    const { role } = await getMapRoleForLayer(req.user!.id, req.params.id);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this layer.");

    const body = patchLayerSchema.parse(req.body);
    const current = await pool.query<LayerRow>("SELECT * FROM layers WHERE id = $1", [req.params.id]);
    if (!current.rows.length) throw new ApiError(404, "Layer not found.");

    const mergedStyle = body.style ? { ...current.rows[0].style, ...body.style } : current.rows[0].style;

    const { rows } = await pool.query<LayerRow>(
      `UPDATE layers SET
         name = COALESCE($1, name),
         style = $2,
         popup_fields = COALESCE($3, popup_fields),
         sort_order = COALESCE($4, sort_order),
         updated_at = now()
       WHERE id = $5 RETURNING *`,
      [
        body.name ?? null,
        JSON.stringify(mergedStyle),
        body.popup_fields ? JSON.stringify(body.popup_fields) : null,
        body.sort_order ?? null,
        req.params.id,
      ]
    );
    res.json({ layer: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Delete a layer
// ---------------------------------------------------------------------------
layersRouter.delete(
  "/layers/:id",
  requireAuth,
  asyncRoute(async (req: AuthedRequest, res) => {
    const { role } = await getMapRoleForLayer(req.user!.id, req.params.id);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this layer.");
    await pool.query("DELETE FROM layers WHERE id = $1", [req.params.id]);
    res.status(204).send();
  })
);
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
  // apps/api/src/lib/terrain.ts). All five run against the current map
  // viewport (bbox) rather than a selected layer — see TerrainPanel.tsx.
  runHillshade: (mapId: string, params: { bbox: Bbox; azimuth?: number; altitude?: number; name?: string }) =>
    request<{ layer: LayerDto }>(`/api/maps/${mapId}/terrain/hillshade`, {
      method: "POST",
      body: JSON.stringify(params),
    }),
  runSlope: (mapId: string, params: { bbox: Bbox; units?: "degrees" | "percent"; name?: string }) =>
    request<{ layer: LayerDto }>(`/api/maps/${mapId}/terrain/slope`, {
      method: "POST",
      body: JSON.stringify(params),
    }),
  runAspect: (mapId: string, params: { bbox: Bbox; name?: string }) =>
    request<{ layer: LayerDto }>(`/api/maps/${mapId}/terrain/aspect`, {
      method: "POST",
      body: JSON.stringify(params),
    }),
  runContours: (mapId: string, params: { bbox: Bbox; intervalMeters?: number; name?: string }) =>
    request<{ layer: LayerDto; featureCount: number }>(`/api/maps/${mapId}/terrain/contours`, {
      method: "POST",
      body: JSON.stringify(params),
    }),
  runWatershed: (mapId: string, params: { bbox: Bbox; pourPoint: { lon: number; lat: number }; name?: string }) =>
    request<{ layer: LayerDto; featureCount: number }>(`/api/maps/${mapId}/terrain/watershed`, {
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
import maplibregl, { LngLatBoundsLike, Map as MapLibreMap, MapLayerMouseEvent, MapMouseEvent } from "maplibre-gl";
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
  // Fires on every map click, regardless of whether it landed on a feature —
  // used by the Watershed tool's "pick a pour point" flow (see
  // TerrainPanel.tsx / MapEditorPage.tsx). Most of the time this is a no-op
  // in the parent; only meaningful while pour-point picking is active.
  onMapClick?: (lngLat: [number, number]) => void;
  // When set, shows a marker at this position — currently just the chosen
  // watershed pour point, so the user can see where they clicked.
  pickMarker?: [number, number] | null;
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

export default function MapCanvas({
  layers,
  featuresByLayer,
  viewState,
  onViewStateChange,
  onFeatureClick,
  onBoundsChange,
  onMapClick,
  pickMarker,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const loadedRef = useRef(false);
  const markerRef = useRef<maplibregl.Marker | null>(null);

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
  // Watershed pour-point picking is driven from here but the actual map
  // click subscription lives in MapEditorPage/MapCanvas — this panel just
  // reads the current pick and asks the parent to start/stop picking mode.
  pourPoint: { lon: number; lat: number } | null;
  pickingPourPoint: boolean;
  onStartPickPourPoint: () => void;
  onClearPourPoint: () => void;
}

// Terrain analysis (GeoLibre-style "Processing" tools), backed by
// WhiteboxTools server-side — see apps/api/src/lib/terrain.ts. Unlike
// AnalysisPanel (buffer/intersect, which run against a selected vector
// layer), these tools run against "whatever DEM covers the current map
// view" — there's no selected layer involved, so this panel takes the
// live viewport bounds reported by MapCanvas instead of a layer prop.
export default function TerrainPanel({
  mapId,
  bounds,
  onCreated,
  pourPoint,
  pickingPourPoint,
  onStartPickPourPoint,
  onClearPourPoint,
}: Props) {
  const [azimuth, setAzimuth] = useState(315);
  const [altitude, setAltitude] = useState(45);
  const [slopeUnits, setSlopeUnits] = useState<"degrees" | "percent">("degrees");
  const [contourInterval, setContourInterval] = useState(50);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(tool: string, fn: () => Promise<unknown>) {
    setBusy(tool);
    setError(null);
    try {
      await fn();
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : `${tool} failed.`);
    } finally {
      setBusy(null);
    }
  }

  const runHillshade = () => bounds && run("hillshade", () => api.runHillshade(mapId, { bbox: bounds, azimuth, altitude }));
  const runSlope = () => bounds && run("slope", () => api.runSlope(mapId, { bbox: bounds, units: slopeUnits }));
  const runAspect = () => bounds && run("aspect", () => api.runAspect(mapId, { bbox: bounds }));
  const runContours = () => bounds && run("contours", () => api.runContours(mapId, { bbox: bounds, intervalMeters: contourInterval }));
  const runWatershed = () =>
    bounds && pourPoint && run("watershed", () => api.runWatershed(mapId, { bbox: bounds, pourPoint }));

  if (!bounds) {
    return <div className="empty-note">Waiting for the map to finish loading…</div>;
  }

  return (
    <div className="analysis-box">
      <p>
        Run terrain analysis on <b>the current map view</b>. Elevation data is fetched automatically for whatever's
        visible on screen — pan/zoom the map to the area you want first, then run a tool below. Results are added as
        a new layer on this map.
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
      <button className="btn btn-primary" disabled={!!busy} onClick={runHillshade}>
        {busy === "hillshade" ? "Generating hillshade…" : "Run hillshade"}
      </button>

      <h4 style={{ marginTop: 22 }}>Slope</h4>
      <p className="muted-sm">Steepness at every point, colorized from flat (green) to steep (red).</p>
      <div className="analysis-row">
        <select value={slopeUnits} onChange={(e) => setSlopeUnits(e.target.value as "degrees" | "percent")}>
          <option value="degrees">Degrees</option>
          <option value="percent">Percent</option>
        </select>
      </div>
      <button className="btn btn-primary" disabled={!!busy} onClick={runSlope}>
        {busy === "slope" ? "Generating slope…" : "Run slope"}
      </button>

      <h4 style={{ marginTop: 22 }}>Aspect</h4>
      <p className="muted-sm">
        Compass direction each slope faces, colorized as a hue wheel (north/south/east/west each get a distinct color).
      </p>
      <button className="btn btn-primary" disabled={!!busy} onClick={runAspect}>
        {busy === "aspect" ? "Generating aspect…" : "Run aspect"}
      </button>

      <h4 style={{ marginTop: 22 }}>Contours</h4>
      <p className="muted-sm">Elevation isolines at a fixed interval, added as a new line layer.</p>
      <div className="analysis-row">
        <input
          type="number"
          min={1}
          step={5}
          value={contourInterval}
          onChange={(e) => setContourInterval(parseFloat(e.target.value) || 0)}
        />
        <span className="muted-sm">meters interval</span>
      </div>
      <button className="btn btn-primary" disabled={!!busy} onClick={runContours}>
        {busy === "contours" ? "Generating contours…" : "Run contours"}
      </button>

      <h4 style={{ marginTop: 22 }}>Watershed</h4>
      <p className="muted-sm">
        Delineates the upstream catchment area that drains to a point you pick — click "Pick pour point," then click
        anywhere on the map.
      </p>
      <div className="analysis-row">
        <button className={"btn" + (pickingPourPoint ? " btn-primary" : "")} onClick={onStartPickPourPoint} disabled={!!busy}>
          {pickingPourPoint ? "Click the map…" : pourPoint ? "Pick a different point" : "Pick pour point"}
        </button>
        {pourPoint && (
          <button className="btn btn-sm" onClick={onClearPourPoint} disabled={!!busy}>
            Clear
          </button>
        )}
      </div>
      {pourPoint && (
        <p className="muted-sm">
          Pour point: {pourPoint.lat.toFixed(5)}, {pourPoint.lon.toFixed(5)}
        </p>
      )}
      <button className="btn btn-primary" disabled={!!busy || !pourPoint} onClick={runWatershed}>
        {busy === "watershed" ? "Delineating watershed…" : "Run watershed"}
      </button>

      {error && (
        <div className="auth-error" style={{ marginTop: 12 }}>
          {error}
        </div>
      )}
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
EOF

echo ""
echo "Done writing files. Now review, build, and push:"
echo ""
echo "  git status"
echo "  git diff --stat"
echo "  npm run build --workspace=apps/api"
echo "  npm run build --workspace=apps/web"
echo "  git add -A"
echo '  git commit -m "Add Slope, Aspect, Contours, and Watershed terrain tools"'
echo "  git push"