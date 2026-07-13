import { pool } from "../db";
import { MapRole } from "../types";

/**
 * Resolve a user's role on a map: 'owner' | 'editor' | 'viewer' | null (no access).
 * Owner is derived from maps.owner_id; editor/viewer come from map_collaborators.
 * This does NOT account for public/unlisted visibility — check that separately
 * for unauthenticated / non-collaborator access.
 */
export async function getMapRole(userId: string, mapId: string): Promise<MapRole> {
  const { rows } = await pool.query<{ owner_id: string }>(
    "SELECT owner_id FROM maps WHERE id = $1",
    [mapId]
  );
  if (!rows.length) return null;
  if (rows[0].owner_id === userId) return "owner";

  const collab = await pool.query<{ role: "editor" | "viewer" }>(
    "SELECT role FROM map_collaborators WHERE map_id = $1 AND user_id = $2",
    [mapId, userId]
  );
  if (collab.rows.length) return collab.rows[0].role;
  return null;
}

export function canEdit(role: MapRole): boolean {
  return role === "owner" || role === "editor";
}

export function canView(role: MapRole): boolean {
  return role !== null;
}

/** Role required for a given layer, resolved via its parent map. */
export async function getMapRoleForLayer(userId: string, layerId: string): Promise<{ role: MapRole; mapId: string | null }> {
  const { rows } = await pool.query<{ map_id: string }>("SELECT map_id FROM layers WHERE id = $1", [layerId]);
  if (!rows.length) return { role: null, mapId: null };
  const role = await getMapRole(userId, rows[0].map_id);
  return { role, mapId: rows[0].map_id };
}
