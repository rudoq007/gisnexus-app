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
 * both mirrors down, no matching entry in the zip), this logs a warning and
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
const USER_AGENT = "gisnexus-setup-whitebox";

// Where to get the compiled Linux x86_64 whitebox_tools binary.
//
// This used to query the GitHub Releases API and grab the linux/amd64 .zip
// asset off the latest release — that broke, because as of the WhiteboxTools
// v2.4.0 release, binaries are no longer attached to GitHub Releases at all
// (the Releases API now returns an empty `assets` array for it; confirmed by
// hand against api.github.com/repos/jblindsay/whitebox-tools/releases/latest
// while fixing this). The release notes instead point people to
// whiteboxgeo.com/download-whiteboxtools/ — a marketing page gated behind a
// JavaScript redirect check, which a plain server-side script can't get past.
//
// So instead this goes straight to two known-good direct .zip URLs, in
// priority order:
//   1. A community-maintained mirror (giswqs/whitebox-bin) served from
//      GitHub's raw-content CDN — plain HTTPS, no bot/JS gate.
//   2. WhiteboxGeo's own direct download bucket, bypassing the gated HTML
//      page — the same URL WhiteboxTools' own official Python frontend
//      (github.com/opengeos/whitebox-python) downloads from.
// If a provider ever moves these again, this degrades to the same non-fatal
// "terrain endpoints return 503" behavior as always — nothing else in the
// build depends on this succeeding.
const DOWNLOAD_URLS = [
  "https://raw.githubusercontent.com/giswqs/whitebox-bin/master/WhiteboxTools_linux_amd64.zip",
  "https://www.whiteboxgeo.com/WBT_Linux/WhiteboxTools_linux_amd64.zip",
];

function httpGetBuffer(url, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/octet-stream, */*" } }, (res) => {
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

async function downloadZip() {
  const errors = [];
  for (const url of DOWNLOAD_URLS) {
    try {
      console.log(`setup-whitebox: trying ${url} ...`);
      const buf = await httpGetBuffer(url);
      console.log(`setup-whitebox: downloaded ${(buf.length / 1024 / 1024).toFixed(1)} MB from ${url}.`);
      return buf;
    } catch (err) {
      console.warn(`setup-whitebox: ${url} failed — ${err.message}`);
      errors.push(`${url}: ${err.message}`);
    }
  }
  throw new Error(`All download sources failed:\n${errors.join("\n")}`);
}

async function main() {
  if (fs.existsSync(BIN_PATH)) {
    console.log(`setup-whitebox: ${BIN_PATH} already present, skipping download.`);
    return;
  }

  const zipBuffer = await downloadZip();

  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const JSZip = require("jszip");
  const zip = await JSZip.loadAsync(zipBuffer);
  const entryName = Object.keys(zip.files).find((n) => !zip.files[n].dir && path.basename(n) === "whitebox_tools");
  if (!entryName) {
    console.warn(
      `setup-whitebox: WARNING — the downloaded zip didn't contain a "whitebox_tools" executable at any path. ` +
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
