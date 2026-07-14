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
