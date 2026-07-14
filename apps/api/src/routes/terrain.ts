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
