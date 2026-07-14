import { useState } from "react";
import { api, Bbox } from "../api/client";

interface Props {
  mapId: string;
  bounds: Bbox | null;
  onCreated: () => void;
}

// Terrain analysis (GeoLibre-style "Processing" tools), backed by
// WhiteboxTools server-side — see apps/api/src/lib/terrain.ts. Unlike
// AnalysisPanel (buffer/intersect, which run against a selected vector
// layer), these tools run against "whatever DEM covers the current map
// view" — there's no selected layer involved, so this panel takes the
// live viewport bounds reported by MapCanvas instead of a layer prop.
export default function TerrainPanel({ mapId, bounds, onCreated }: Props) {
  const [azimuth, setAzimuth] = useState(315);
  const [altitude, setAltitude] = useState(45);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function runHillshade() {
    if (!bounds) return;
    setBusy(true);
    setError(null);
    try {
      await api.runHillshade(mapId, { bbox: bounds, azimuth, altitude });
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Hillshade failed.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="analysis-box">
      <p>
        Run terrain analysis on <b>the current map view</b>. Elevation data is fetched automatically for whatever's
        visible on screen — pan/zoom the map to the area you want first, then run a tool below. Results are added as
        a new raster layer on this map.
      </p>

      <h4>Hillshade</h4>
      <p className="muted-sm">
        Generates a shaded-relief raster from elevation data, showing terrain as if lit from a given sun position.
      </p>
      <div className="analysis-row">
        <label style={{ minWidth: 70 }}>Azimuth</label>
        <input
          type="number"
          min={0}
          max={360}
          step={5}
          value={azimuth}
          onChange={(e) => setAzimuth(parseFloat(e.target.value) || 0)}
        />
        <span className="muted-sm">° (sun direction)</span>
      </div>
      <div className="analysis-row">
        <label style={{ minWidth: 70 }}>Altitude</label>
        <input
          type="number"
          min={0}
          max={90}
          step={5}
          value={altitude}
          onChange={(e) => setAltitude(parseFloat(e.target.value) || 0)}
        />
        <span className="muted-sm">° (sun elevation)</span>
      </div>

      {!bounds ? (
        <div className="empty-note">Waiting for the map to finish loading…</div>
      ) : (
        <button className="btn btn-primary" disabled={busy} onClick={runHillshade}>
          {busy ? "Generating hillshade…" : "Run hillshade"}
        </button>
      )}

      {error && (
        <div className="auth-error" style={{ marginTop: 12 }}>
          {error}
        </div>
      )}

      <p className="muted-sm" style={{ marginTop: 22 }}>
        More terrain tools (slope, aspect, contours, watershed delineation) are coming soon.
      </p>
    </div>
  );
}
