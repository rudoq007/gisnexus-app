#!/usr/bin/env bash
# GISNEXUS — Fix Watershed: switch the internal FillDepressions -> D8Pointer
# -> Watershed -> RasterToVectorPolygons chain from ESRI ASCII (.asc)
# intermediate files to GeoTIFF (.tif). Single-file change (apps/api/src/lib/terrain.ts).
#
# Root cause of the error you hit ("D8Pointer failed ... ParseFloatError {
# kind: Empty } ... arcascii_raster.rs:87"): FillDepressions' own ASCII grid
# writer produced a file that WhiteboxTools' own D8Pointer ASCII reader
# couldn't parse — an internal WhiteboxTools writer/reader mismatch, not a
# bug in our code (the DEM we write ourselves, dem.asc, was read back fine).
# filled.asc/d8.asc/watershed.asc are pure WhiteboxTools-to-WhiteboxTools
# handoffs that our own code never reads back, so they're free to use
# whatever format round-trips reliably — GeoTIFF is binary (no text-parsing
# edge cases) and WhiteboxTools' most commonly used raster format.
#
# Run this from the ROOT of your gisnexus-app repo, in Git Bash:
#   bash deliver-watershed-fix.sh
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

    // filled/d8/watershed are pure WhiteboxTools-to-WhiteboxTools handoffs —
    // our own code never reads them back (unlike dem.asc/pour.asc, which we
    // write, and the final result, which comes back as a Shapefile via
    // RasterToVectorPolygons) — so these three are free to use whatever
    // format WhiteboxTools round-trips most reliably. They were originally
    // ESRI ASCII (.asc) to match the rest of this file's convention, but
    // that tripped a WhiteboxTools bug: FillDepressions' own ASCII writer
    // produced a grid its own D8Pointer's ASCII reader couldn't parse
    // ("ParseFloatError { kind: Empty }" in arcascii_raster.rs — an internal
    // WhiteboxTools writer/reader mismatch, not something in our code, since
    // dem.asc — which WE write — was read back fine by FillDepressions).
    // GeoTIFF sidesteps this: it's a binary format with no text-parsing edge
    // cases, and it's WhiteboxTools' most commonly used raster format, so
    // its own tools chaining through it is the best-tested path.
    await runWhiteboxTool("FillDepressions", ["--input=dem.asc", "--output=filled.tif"], workDir);
    await runWhiteboxTool("D8Pointer", ["--input=filled.tif", "--output=d8.tif"], workDir);

    const pourGrid = buildPourPointGrid(dem, pourPoint);
    await writeAsciiGrid(pourGrid, path.join(workDir, "pour.asc"));

    await runWhiteboxTool("Watershed", ["--d8_pntr=d8.tif", "--pour_pts=pour.asc", "--output=watershed.tif"], workDir);
    await runWhiteboxTool("RasterToVectorPolygons", ["--input=watershed.tif", "--output=watershed.shp"], workDir);

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

echo ""
echo "Done writing files. Now review, build, and push:"
echo ""
echo "  git status"
echo "  git diff --stat"
echo "  npm run build --workspace=apps/api"
echo "  git add -A"
echo "  git commit -m \"Fix Watershed: use GeoTIFF for internal FillDepressions/D8Pointer/Watershed handoffs\""
echo "  git push"