import { Router } from "express";
import { pool } from "../db";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { LayerRow, MapRow } from "../types";

export const publicRouter = Router();

// ---------------------------------------------------------------------------
// View a map via its share token — no authentication required.
// Only works if the map's visibility is 'public' or 'unlisted'.
// (Feature data for each layer is still fetched via GET /api/layers/:id/features,
// which independently allows public/unlisted maps.)
// ---------------------------------------------------------------------------
publicRouter.get(
  "/maps/:token",
  asyncRoute(async (req, res) => {
    const mapResult = await pool.query<MapRow>(
      "SELECT * FROM maps WHERE share_token = $1 AND visibility IN ('public','unlisted')",
      [req.params.token]
    );
    if (!mapResult.rows.length) throw new ApiError(404, "This map isn't available or the link is invalid.");

    const map = mapResult.rows[0];
    const layersResult = await pool.query<LayerRow>(
      "SELECT * FROM layers WHERE map_id = $1 ORDER BY sort_order, created_at",
      [map.id]
    );
    res.json({ map, layers: layersResult.rows });
  })
);
