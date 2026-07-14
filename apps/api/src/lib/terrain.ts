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
