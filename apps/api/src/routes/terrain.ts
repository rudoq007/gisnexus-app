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
