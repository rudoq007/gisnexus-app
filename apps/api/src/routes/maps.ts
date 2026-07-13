import { Router } from "express";
import crypto from "node:crypto";
import { z } from "zod";
import { pool } from "../db";
import { requireAuth, AuthedRequest } from "../middleware/auth";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { canEdit, getMapRole } from "../lib/access";
import { LayerRow, MapRow } from "../types";

export const mapsRouter = Router();
mapsRouter.use(requireAuth);

// ---------------------------------------------------------------------------
// List my maps (owned + shared with me)
// ---------------------------------------------------------------------------
mapsRouter.get(
  "/",
  asyncRoute(async (req: AuthedRequest, res) => {
    const { rows } = await pool.query<MapRow & { role: string }>(
      `SELECT m.*, CASE WHEN m.owner_id = $1 THEN 'owner' ELSE mc.role END AS role
       FROM maps m
       LEFT JOIN map_collaborators mc ON mc.map_id = m.id AND mc.user_id = $1
       WHERE m.owner_id = $1 OR mc.user_id = $1
       ORDER BY m.updated_at DESC`,
      [req.user!.id]
    );
    res.json({ maps: rows });
  })
);

// ---------------------------------------------------------------------------
// Create a map
// ---------------------------------------------------------------------------
const createMapSchema = z.object({
  name: z.string().min(1).max(200),
  description: z.string().max(2000).optional(),
});

mapsRouter.post(
  "/",
  asyncRoute(async (req: AuthedRequest, res) => {
    const { name, description } = createMapSchema.parse(req.body);
    const { rows } = await pool.query<MapRow>(
      `INSERT INTO maps (owner_id, name, description) VALUES ($1, $2, $3) RETURNING *`,
      [req.user!.id, name, description || null]
    );
    res.status(201).json({ map: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Get one map (with its layers, no features — features are fetched per-layer)
// ---------------------------------------------------------------------------
mapsRouter.get(
  "/:id",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.id);
    if (!role) throw new ApiError(404, "Map not found.");

    const mapResult = await pool.query<MapRow>("SELECT * FROM maps WHERE id = $1", [req.params.id]);
    const layersResult = await pool.query<LayerRow>(
      "SELECT * FROM layers WHERE map_id = $1 ORDER BY sort_order, created_at",
      [req.params.id]
    );
    res.json({ map: mapResult.rows[0], layers: layersResult.rows, role });
  })
);

// ---------------------------------------------------------------------------
// Update a map (name/description/view_state/components)
// ---------------------------------------------------------------------------
const updateMapSchema = z.object({
  name: z.string().min(1).max(200).optional(),
  description: z.string().max(2000).nullable().optional(),
  view_state: z.object({ center: z.tuple([z.number(), z.number()]), zoom: z.number() }).optional(),
  components: z.array(z.unknown()).optional(),
});

mapsRouter.patch(
  "/:id",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.id);
    if (!canEdit(role)) throw new ApiError(403, "You don't have edit access to this map.");

    const body = updateMapSchema.parse(req.body);
    const fields: string[] = [];
    const values: unknown[] = [];
    let i = 1;
    for (const [key, value] of Object.entries(body)) {
      fields.push(`${key} = $${i++}`);
      values.push(key === "view_state" || key === "components" ? JSON.stringify(value) : value);
    }
    if (!fields.length) throw new ApiError(400, "No fields to update.");
    values.push(req.params.id);

    const { rows } = await pool.query<MapRow>(
      `UPDATE maps SET ${fields.join(", ")}, updated_at = now() WHERE id = $${i} RETURNING *`,
      values
    );
    res.json({ map: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Delete a map (owner only)
// ---------------------------------------------------------------------------
mapsRouter.delete(
  "/:id",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.id);
    if (role !== "owner") throw new ApiError(403, "Only the owner can delete this map.");
    await pool.query("DELETE FROM maps WHERE id = $1", [req.params.id]);
    res.status(204).send();
  })
);

// ---------------------------------------------------------------------------
// Sharing: set visibility & (re)generate a share token
// ---------------------------------------------------------------------------
const shareSchema = z.object({
  visibility: z.enum(["private", "unlisted", "public"]),
  regenerateToken: z.boolean().optional(),
});

mapsRouter.post(
  "/:id/share",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.id);
    if (role !== "owner") throw new ApiError(403, "Only the owner can change sharing settings.");

    const { visibility, regenerateToken } = shareSchema.parse(req.body);
    const existing = await pool.query<{ share_token: string | null }>("SELECT share_token FROM maps WHERE id = $1", [
      req.params.id,
    ]);
    let token = existing.rows[0]?.share_token;
    if (!token || regenerateToken) {
      token = crypto.randomBytes(9).toString("base64url");
    }

    const { rows } = await pool.query<MapRow>(
      "UPDATE maps SET visibility = $1, share_token = $2, updated_at = now() WHERE id = $3 RETURNING *",
      [visibility, token, req.params.id]
    );
    res.json({ map: rows[0] });
  })
);

// ---------------------------------------------------------------------------
// Collaborators
// ---------------------------------------------------------------------------
const addCollabSchema = z.object({
  email: z.string().email(),
  role: z.enum(["editor", "viewer"]),
});

mapsRouter.post(
  "/:id/collaborators",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.id);
    if (role !== "owner") throw new ApiError(403, "Only the owner can manage collaborators.");

    const { email, role: newRole } = addCollabSchema.parse(req.body);
    const userResult = await pool.query<{ id: string }>("SELECT id FROM users WHERE email = $1", [email.toLowerCase()]);
    if (!userResult.rows.length) throw new ApiError(404, "No user found with that email.");

    await pool.query(
      `INSERT INTO map_collaborators (map_id, user_id, role) VALUES ($1, $2, $3)
       ON CONFLICT (map_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
      [req.params.id, userResult.rows[0].id, newRole]
    );
    res.status(201).json({ ok: true });
  })
);

mapsRouter.delete(
  "/:id/collaborators/:userId",
  asyncRoute(async (req: AuthedRequest, res) => {
    const role = await getMapRole(req.user!.id, req.params.id);
    if (role !== "owner") throw new ApiError(403, "Only the owner can manage collaborators.");
    await pool.query("DELETE FROM map_collaborators WHERE map_id = $1 AND user_id = $2", [
      req.params.id,
      req.params.userId,
    ]);
    res.status(204).send();
  })
);
