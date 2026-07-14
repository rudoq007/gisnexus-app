// Minimal ambient shim for the `geotiff` npm package.
//
// This project only uses `geotiff` for one thing — encoding a georeferenced
// raster to a GeoTIFF entirely client-side, see lib/downloadLayer.ts. We
// couldn't confirm at write-time whether the installed version of `geotiff`
// ships its own TypeScript declarations, or whether `writeArrayBuffer`'s
// real signature matches this shim exactly (no network access to inspect
// the package). Declaring it here — loosely, with `unknown`/`any` — means
// the web build can't fail because of a type mismatch with the *real*
// package; if the shim is wrong, the failure shows up at runtime instead
// (caught by the try/catch around downloadRasterLayer's caller), not as a
// build break blocking every other feature in this delivery.
//
// If TypeScript reports "Duplicate identifier" or similar here once you
// build, it means `geotiff` DOES ship its own types and this file can just
// be deleted.
declare module "geotiff" {
  export function writeArrayBuffer(values: unknown, metadata: Record<string, unknown>): Promise<ArrayBuffer>;
}
