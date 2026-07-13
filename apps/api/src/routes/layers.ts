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

/** Inserts a batch of normalized features for a layer inside a transaction. */
async function insertFeatures(layerId: string, features: NormalizedFeature[]) {
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

function collectPopupFields(features: NormalizedFeature[]): string[] {
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
