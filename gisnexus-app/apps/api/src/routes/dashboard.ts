import { Router } from "express";
import { z } from "zod";
import { pool } from "../db";
import { optionalAuth, AuthedRequest } from "../middleware/auth";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { canView, getMapRole } from "../lib/access";
import { aggregateField } from "../lib/geo";

export const dashboardRouter = Router();

const querySchema = z.object({ field: z.string().min(1) });

// ---------------------------------------------------------------------------
// Aggregate a property across every feature in a layer, for dashboard charts.
// Numeric fields are bucketed into 5 ranges; categorical fields are counted
// (top 8 + "Other"). See lib/geo.ts#aggregateField for the shared logic used
// by both this endpoint and the client-side prototype.
// ---------------------------------------------------------------------------
dashboardRouter.get(
  "/layers/:id/aggregate",
  optionalAuth,
  asyncRoute(async (req: AuthedRequest, res) => {
    const { field } = querySchema.parse(req.query);

    const layerResult = await pool.query<{ map_id: string }>("SELECT map_id FROM layers WHERE id = $1", [req.params.id]);
    if (!layerResult.rows.length) throw new ApiError(404, "Layer not found.");
    const mapId = layerResult.rows[0].map_id;

    const mapResult = await pool.query<{ visibility: string }>("SELECT visibility FROM maps WHERE id = $1", [mapId]);
    const isPublic = mapResult.rows[0]?.visibility !== "private";
    if (!isPublic) {
      if (!req.user) throw new ApiError(401, "Sign in to view this layer.");
      const role = await getMapRole(req.user.id, mapId);
      if (!canView(role)) throw new ApiError(403, "You don't have access to this map.");
    }

    // MVP approach: pull the field's values and bucket in application code
    // (mirrors the client prototype). For very large layers this should move
    // to SQL-side GROUP BY / width_bucket — noted in README as a scaling TODO.
    const { rows } = await pool.query<{ v: string | null }>(
      `SELECT properties->>$1 AS v FROM features WHERE layer_id = $2 AND properties ? $1`,
      [field, req.params.id]
    );

    const bars = aggregateField(rows.map((r) => r.v));
    res.json({ field, bars });
  })
);
