import { Router } from "express";
import { z } from "zod";
import { pool } from "../db";
import { requireAuth, AuthedRequest } from "../middleware/auth";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { canEdit, getMapRoleForLayer } from "../lib/access";
import { LayerRow } from "../types";

export const analysisRouter = Router();
analysisRouter.use(requireAuth);

// ---------------------------------------------------------------------------
// Buffer: create a new polygon layer with a circular buffer around every
// feature in a point layer. Distance-aware buffering (geography cast) is
// done in PostGIS directly for accuracy; bufferRing() is kept in lib/geo.ts
// for the CSV/GeoJSON-only in-browser prototype and as a fallback.
// ---------------------------------------------------------------------------
const bufferSchema = z.object({
  distanceMeters: z.number().positive().max(500000),
  name: z.string().min(1).max(200).optional(),
});

analysisRouter.post(
  "/layers/:id/buffer",
  asyncRoute(async (req: AuthedRequest, res) => {
    const { role, mapId } = await getMapRoleForLayer(req.user!.id, req.params.id);
    if (!canEdit(role) || !mapId) throw new ApiError(403, "You don't have edit access to this layer.");

    const { distanceMeters, name } = bufferSchema.parse(req.body);
    const source = await pool.query<LayerRow>("SELECT * FROM layers WHERE id = $1", [req.params.id]);
    if (!source.rows.length) throw new ApiError(404, "Layer not found.");

    const newLayerResult = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, geom_type, source, popup_fields)
       VALUES ($1, $2, 'Polygon', 'buffer', '["source_name","buffer_m"]')
       RETURNING *`,
      [mapId, name || `${source.rows[0].name} — ${distanceMeters}m buffer`]
    );
    const newLayer = newLayerResult.rows[0];

    // Use PostGIS geography buffering for a geodesically accurate result,
    // regardless of source geometry type (point, line, or polygon).
    await pool.query(
      `INSERT INTO features (layer_id, geom, properties)
       SELECT $1,
              ST_Buffer(geom::geography, $2)::geometry,
              jsonb_build_object(
                'source_name', COALESCE(properties->>'name', id::text),
                'buffer_m', $2
              )
       FROM features
       WHERE layer_id = $3`,
      [newLayer.id, distanceMeters, req.params.id]
    );

    const countResult = await pool.query<{ count: string }>("SELECT count(*) FROM features WHERE layer_id = $1", [
      newLayer.id,
    ]);
    res.status(201).json({ layer: newLayer, featureCount: parseInt(countResult.rows[0].count, 10) });
  })
);

// ---------------------------------------------------------------------------
// Intersect: create a new layer with the features of layer A that intersect
// any feature of layer B.
// ---------------------------------------------------------------------------
const intersectSchema = z.object({
  otherLayerId: z.string().uuid(),
  name: z.string().min(1).max(200).optional(),
});

analysisRouter.post(
  "/layers/:id/intersects",
  asyncRoute(async (req: AuthedRequest, res) => {
    const { role, mapId } = await getMapRoleForLayer(req.user!.id, req.params.id);
    if (!canEdit(role) || !mapId) throw new ApiError(403, "You don't have edit access to this layer.");

    const { otherLayerId, name } = intersectSchema.parse(req.body);
    const [a, b] = await Promise.all([
      pool.query<LayerRow>("SELECT * FROM layers WHERE id = $1", [req.params.id]),
      pool.query<LayerRow>("SELECT * FROM layers WHERE id = $1", [otherLayerId]),
    ]);
    if (!a.rows.length || !b.rows.length) throw new ApiError(404, "One or both layers were not found.");
    if (b.rows[0].map_id !== mapId) throw new ApiError(400, "Both layers must belong to the same map.");

    const newLayerResult = await pool.query<LayerRow>(
      `INSERT INTO layers (map_id, name, geom_type, source, popup_fields)
       VALUES ($1, $2, $3, 'intersect', $4)
       RETURNING *`,
      [mapId, name || `${a.rows[0].name} ∩ ${b.rows[0].name}`, a.rows[0].geom_type, a.rows[0].popup_fields]
    );
    const newLayer = newLayerResult.rows[0];

    await pool.query(
      `INSERT INTO features (layer_id, geom, properties)
       SELECT $1, f1.geom, f1.properties
       FROM features f1
       WHERE f1.layer_id = $2
         AND EXISTS (
           SELECT 1 FROM features f2 WHERE f2.layer_id = $3 AND ST_Intersects(f1.geom, f2.geom)
         )`,
      [newLayer.id, req.params.id, otherLayerId]
    );

    const countResult = await pool.query<{ count: string }>("SELECT count(*) FROM features WHERE layer_id = $1", [
      newLayer.id,
    ]);
    res.status(201).json({ layer: newLayer, featureCount: parseInt(countResult.rows[0].count, 10) });
  })
);
