import { FormEvent, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, MapDto } from "../api/client";
import { useAuth } from "../context/AuthContext";

export default function MapsListPage() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();
  const [maps, setMaps] = useState<MapDto[] | null>(null);
  const [creating, setCreating] = useState(false);
  const [newName, setNewName] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .listMaps()
      .then(({ maps }) => setMaps(maps))
      .catch((err) => setError(err.message));
  }, []);

  async function createMap(e: FormEvent) {
    e.preventDefault();
    if (!newName.trim()) return;
    try {
      const { map } = await api.createMap(newName.trim());
      navigate(`/maps/${map.id}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Couldn't create map.");
    }
  }

  return (
    <div className="maps-list-page">
      <header className="app-header">
        <div className="logo">GISNEXUS</div>
        <div className="header-actions">
          <span className="muted">{user?.email}</span>
          <button className="btn" onClick={logout}>
            Sign out
          </button>
        </div>
      </header>

      <div className="maps-list-body">
        <div className="maps-list-top">
          <h1>Your maps</h1>
          <button className="btn btn-primary" onClick={() => setCreating(true)}>
            + New map
          </button>
        </div>

        {creating && (
          <form className="new-map-form" onSubmit={createMap}>
            <input
              autoFocus
              placeholder="Map name (e.g. Downtown zoning review)"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
            />
            <button className="btn btn-primary" type="submit">
              Create
            </button>
            <button className="btn" type="button" onClick={() => setCreating(false)}>
              Cancel
            </button>
          </form>
        )}

        {error && <div className="auth-error">{error}</div>}

        {maps === null ? (
          <div className="muted">Loading your maps…</div>
        ) : maps.length === 0 ? (
          <div className="empty-state">You don't have any maps yet — create one to get started.</div>
        ) : (
          <div className="maps-grid">
            {maps.map((m) => (
              <div key={m.id} className="map-card" onClick={() => navigate(`/maps/${m.id}`)}>
                <div className="map-card-thumb">🗺️</div>
                <div className="map-card-name">{m.name}</div>
                <div className="map-card-meta">
                  {m.role} · {new Date(m.updated_at).toLocaleDateString()}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
