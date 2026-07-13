# GISNEXUS

A cloud-native GIS starter: upload spatial data, style it into layers, share maps,
run spatial analysis, and build dashboard charts — in the browser, backed by a
real Postgres/PostGIS database.

This is the **MVP slice** of the full GISNEXUS concept (see `/docs` from the
original design pass if you have it) — it implements:

- **Upload Anything** — GeoJSON, CSV, Shapefile (.zip), KML, and GPX upload, all
  parsed into PostGIS geometries. See "Supported upload formats" below for
  per-format notes and limitations.
- **Add Data** — a built-in catalog of free, keyless web services (basemaps,
  imagery, demo datasets) addable as layers in one click: XYZ/WMS/WMTS render
  live as raster tiles, WFS/ArcGIS FeatureServer layers are imported as
  vector features. See "Add Data — external service layers" below.
- **Layers** — styling (color/opacity/size), popup field configuration, a data
  table view.
- **Sharing & permissions** — private/unlisted/public visibility, share links,
  per-user collaborator roles (owner/editor/viewer).
- **Spatial analysis** — buffer (geodesic, via `ST_Buffer` on `geography`) and
  intersect, both run server-side in PostGIS and materialized as new layers.
- **Dashboards** — a bar-chart component that aggregates any field on a layer
  (categorical top-8 + "Other", or 5-bucket numeric ranges).

Not included in this pass (see the original architecture doc for the full
design): the AI assistant, the mobile Field App, real-time multiplayer editing,
and the embeddable App/SDK layer. The schema and API are laid out so those can
be added later without a rewrite — see **Roadmap** at the bottom.

## Stack

| Layer | Technology |
|---|---|
| Frontend | React + TypeScript + Vite, MapLibre GL JS |
| Backend | Node.js + Express + TypeScript |
| Database | PostgreSQL + PostGIS |
| Auth | Email/password, JWT |

No paid API keys are required to run this locally — the map uses OpenStreetMap's
public raster tiles for the basemap (fine for development; see "Basemap tiles"
below for production).

## Quick start (Docker)

Requires [Docker](https://docs.docker.com/get-docker/) and Docker Compose.

```bash
git clone <this-repo> gisnexus && cd gisnexus
docker compose up --build
```

This starts three containers: `db` (Postgres + PostGIS, with the schema
migration applied automatically on boot), `api` (on :4000), and `web` (on
:5173). Once it's up:

1. Open http://localhost:5173
2. Register an account
3. Create a map, upload a `.geojson` or `.csv` file (needs `lat`/`lon` columns),
   style the layer, and try the Dashboard and Spatial Analysis tabs.

## Manual setup (without Docker)

You'll need Node.js 20+ and a Postgres instance with PostGIS available (either
local, or a managed one — see `DEPLOYMENT.md`).

```bash
# 1. Install dependencies (from the repo root — this is an npm workspaces monorepo)
npm install

# 2. Configure the API
cp apps/api/.env.example apps/api/.env
# edit apps/api/.env — set DATABASE_URL to your Postgres connection string
# and JWT_SECRET to a random string (openssl rand -hex 32)

# 3. Run the database migration
npm run migrate

# 4. Configure the frontend
cp apps/web/.env.example apps/web/.env
# edit apps/web/.env if your API isn't on http://localhost:4000

# 5. Run both apps in dev mode (in two terminals)
npm run dev:api
npm run dev:web
```

The frontend dev server runs at http://localhost:5173, the API at
http://localhost:4000.

### Enabling PostGIS

If you're not using the bundled `postgis/postgis` Docker image, enable the
extension once on your database:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
```

Managed providers: on Supabase, enable "postgis" from Database → Extensions in
the dashboard before running the migration. See `DEPLOYMENT.md` for
provider-specific notes.

## Project structure

```
apps/
  api/            Express + TypeScript backend
    migrations/   Versioned SQL migrations (plain SQL, no ORM)
    scripts/      migrate.js — the migration runner
    src/
      routes/     auth, maps, layers, analysis, dashboard, public(share)
      lib/        geo.ts (CSV/GeoJSON parsing, buffer math, chart bucketing),
                  auth.ts (password/JWT), access.ts (permission checks)
  web/            React + Vite frontend
    src/
      pages/      Login, Register, MapsList, MapEditor, SharedMap
      components/ MapCanvas (MapLibre wrapper), LayerList, StylePanel,
                  PopupConfigPanel, UploadButton, AddDataPanel, DataTable,
                  DashboardChart, AnalysisPanel
      lib/        serviceCatalog.ts — the built-in "Add Data" catalog
      api/client.ts   typed fetch wrapper for the whole API
docker-compose.yml    local dev: Postgres+PostGIS, API, web (all three services)
DEPLOYMENT.md         affordable hosting options with current pricing
```

## Supported upload formats

| Format | Extension | Notes |
|---|---|---|
| GeoJSON | `.geojson`, `.json` | `Feature`, `FeatureCollection`, or a bare geometry object. `Multi*` geometries are flattened into individual features. |
| CSV | `.csv` | Needs a latitude and longitude column (any of `lat`/`latitude`/`y` and `lon`/`lng`/`long`/`longitude`/`x`, case-insensitive). Every other column becomes a feature property, numeric-coerced where possible. |
| Shapefile | `.zip` | Upload the whole shapefile as a zip (containing at least `.shp`; `.dbf` for attributes and `.prj` for the projection are used if present). Parsed with the `shapefile` package. |
| KML | `.kml` | Parsed with `@tmcw/togeojson`. |
| GPX | `.gpx` | Parsed with `@tmcw/togeojson`. Tracks/routes become `LineString` features, waypoints become `Point` features. |

**Shapefile projection caveat:** this MVP does **not reproject** non-WGS84
shapefiles. If a `.prj` is present and doesn't look like WGS84/EPSG:4326, the
upload still succeeds but the API returns a `warning` in the response (shown
as a banner in the web app) telling you the layer may be positioned
incorrectly on the map. If you hit this, reproject the shapefile to WGS84
before uploading (e.g. `ogr2ogr -t_srs EPSG:4326 out.shp in.shp` if you have
GDAL, or re-export from your GIS tool in WGS84) — adding a full WKT→proj4
reprojection pipeline server-side is a reasonable follow-up but wasn't in
scope for this pass.

Raster formats (GeoTIFF/imagery) aren't supported as an *upload* — they need a
different storage and tiling path than vector features (Cloud-Optimized
GeoTIFF + a dynamic tile server), which is a separate, larger piece of work
covered in the original architecture doc's "Rendering & Map Client" section.
Pre-tiled raster *services* (XYZ/WMS/WMTS) are supported via Add Data, below.

## Add Data — external service layers

The "🌐 Add data" button in the map editor (next to Upload) opens a catalog of
free, keyless web services, grouped by category. Clicking **+ Add** on an
entry saves it to the map as a new layer — it shows up in the layer list,
persists across reloads, and is visible to anyone with access to the map,
same as an uploaded layer. The built-in catalog
(`apps/web/src/lib/serviceCatalog.ts`) is deliberately global in coverage
(no country-specific sources) and ships with:

| Name | Category | Type |
|---|---|---|
| OpenStreetMap | Basemaps | XYZ |
| OpenTopoMap | Basemaps | XYZ |
| NASA satellite imagery (MODIS true color) | Imagery | WMS |
| GEBCO Ocean Bathymetry | Imagery | WMS |
| Sentinel-2 cloudless (EOX) | Imagery | WMTS |
| World Countries (Natural Earth) | Demo data | GeoJSON URL |
| World Cities | Demo data | ArcGIS FeatureServer |

Three kinds of layer come out of this, handled differently end to end:

- **Raster (XYZ / WMS / WMTS)** — `POST /api/maps/:mapId/layers/service`
  builds a MapLibre-ready tile URL template server-side (for WMS, a `GetMap`
  query using MapLibre's `{bbox-epsg-3857}` placeholder, plus a `TIME=default`
  parameter for time-enabled services like NASA GIBS so the layer always shows
  the most recent available date) and stores it in the new layer's `service`
  jsonb column; no rows are written to `features`. The browser requests tiles
  directly from the remote service as you pan/zoom. These layers only support
  an opacity control (no color/size/popups — there's no per-feature attribute
  data) and are excluded from the data table, dashboard, and spatial analysis
  tools.
- **Vector via OGC/Esri service (WFS / ArcGIS FeatureServer)** — fetched
  **once**, server-side, at the moment you click Add, via a live query against
  the service, and normalized/imported into `features` exactly like an upload
  (same `lib/geo.ts#normalizeFeatureArray` path, same popup field
  auto-detection).
- **Vector via plain GeoJSON URL** — the simplest and most reliable of the
  three: no OGC query semantics, just fetches a hosted `.geojson` file (e.g.
  a dataset published on GitHub) and imports it the same way. Good for
  datasets that aren't behind a WFS/ArcGIS endpoint at all.

Both vector kinds are a **snapshot, not a live connection** — if the upstream
data changes, you won't see the update unless you delete the layer and add it
again. Building a live/refreshable connection is a reasonable follow-up but
wasn't in scope for this pass.

**Adding your own service**: the catalog is just a plain array of `{ name,
category, serviceType, fields }` objects — edit `serviceCatalog.ts` to point
at services relevant to your own work (a hazard/imagery WMS, an internal
ArcGIS FeatureServer, a dataset specific to your region, etc.) instead of, or
alongside, the generic demo set. See `apps/api/src/lib/geo.ts`
(`buildXyzService`/`buildWmsService`/`buildWmtsService`/`wfsToFeatures`/
`arcgisFeatureToFeatures`/`geojsonUrlToFeatures`) for exactly what fields each
service type expects. There's no custom-URL form in the UI yet — that's the
natural next step if you want people to paste in arbitrary service URLs
rather than editing the catalog file.

**WMTS caveat**: only RESTful WMTS templates with `{z}`/`{x}`/`{y}`
placeholders are supported (the same shape as an XYZ URL) — paste the tile
template, not a `GetCapabilities` document. KVP-style WMTS (`GetTile` query
parameters) isn't handled.

## How data flows

1. **Upload**: a file is posted to `POST /api/maps/:mapId/layers/upload` as
   multipart form data. The API parses it (`apps/api/src/lib/geo.ts`), creates
   a `layers` row, and bulk-inserts one row per feature into `features`, with
   geometry stored as PostGIS `geometry(Geometry,4326)` and attributes as
   `jsonb`.
2. **Add Data**: `POST /api/maps/:mapId/layers/service` either builds a raster
   tile URL template (XYZ/WMS/WMTS, no `features` rows) or fetches and imports
   vector features once (WFS/ArcGIS, same path as Upload) — see "Add Data"
   above.
3. **Render**: the frontend fetches `GET /api/layers/:id/features` for every
   vector layer, which returns a GeoJSON FeatureCollection (`ST_AsGeoJSON`)
   handed to MapLibre as a GeoJSON source; raster layers skip this and are
   added straight from their stored tile URL as a MapLibre raster source.
4. **Style**: `PATCH /api/layers/:id` updates the layer's `style` jsonb column;
   the frontend re-applies MapLibre paint properties immediately (opacity only
   for raster layers).
5. **Analysis**: `POST /api/layers/:id/buffer` and `/intersects` run PostGIS
   functions server-side and write the result as a brand-new `layers` +
   `features` row set — analysis outputs are just more layers, so they're
   styleable/shareable/chartable like any uploaded layer. Raster layers are
   excluded as analysis inputs/targets (no geometry to operate on).
6. **Dashboard**: `GET /api/layers/:id/aggregate?field=x` pulls that field's
   values and buckets them (`lib/geo.ts#aggregateField`) — categorical fields
   get top-8 + "Other", numeric fields get 5 even-width buckets.

## Known scaling limits (MVP tradeoffs, called out on purpose)

- **Feature inserts are row-by-row in a transaction**, not bulk `COPY`. Fine
  for uploads up to tens of thousands of rows; revisit with `pg-copy-streams`
  for very large datasets.
- **Dashboard aggregation pulls the full column into Node** and buckets it in
  JS rather than `GROUP BY`/`width_bucket` in SQL. Simple and consistent with
  the logic that runs in-browser, but won't scale to millions of features per
  layer without moving the bucketing into SQL.
- **The whole map's features are fetched up front** in the editor (one request
  per layer) rather than viewport-based paging/tiling. Fine for MVP-scale
  layers; production-scale layers should move to on-the-fly vector tiles
  (`ST_AsMVT`) — the original architecture doc covers this.
- **Buffer/intersect run synchronously** inside the HTTP request. For very
  large layers, move these to a background job queue.

None of these affect correctness at MVP scale — they're the first things to
revisit as usage grows, and the schema (PostGIS + jsonb properties + GIST/GIN
indexes already in the migration) is built so that upgrade path doesn't require
a redesign.

## Basemap tiles

The frontend uses OpenStreetMap's public raster tiles
(`tile.openstreetmap.org`) so the app works with zero API keys out of the box.
OSM's tile server has a
[usage policy](https://operations.osmfoundation.org/policies/tiles/) that
isn't meant for production traffic. Before you have real users, swap the style
in `apps/web/src/components/MapCanvas.tsx` for a vector style from a provider
with a free/cheap tier — MapTiler, Stadia Maps, and Protomaps (self-hosted,
essentially free) are good options.

## Roadmap beyond this MVP

- **AI assistant** — a tool-using agent for popup/app generation and SQL
  generation, gated behind the same permission checks as manual edits.
- **Field App** — React Native, offline-first via SQLite, syncing through this
  same API.
- **Real-time multiplayer editing** — a CRDT (e.g. Yjs) layer over WebSocket,
  additive to the current REST API.
- **Dashboards & Apps publishing** — the `maps.components` jsonb column is
  already there for a component-based dashboard layout; this MVP only reads/
  writes it implicitly via the single bar-chart view.

See `DEPLOYMENT.md` for how to actually put this online affordably.
