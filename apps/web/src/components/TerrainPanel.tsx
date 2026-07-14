import { useState } from "react";
import { api, Bbox } from "../api/client";

interface Props {
  mapId: string;
  bounds: Bbox | null;
  onCreated: () => void;
  // Watershed pour-point picking is driven from here but the actual map
  // click subscription lives in MapEditorPage/MapCanvas — this panel just
  // reads the current pick and asks the parent to start/stop picking mode.
  pourPoint: { lon: number; lat: number } | null;
  pickingPourPoint: boolean;
  onStartPickPourPoint: () => void;
  onClearPourPoint: () => void;
}

// Human label shown in the sticky status banner while each tool runs.
const BUSY_LABELS: Record<string, string> = {
  hillshade: "Generating hillshade",
  slope: "Generating slope",
  aspect: "Generating aspect",
  contours: "Generating contours",
  watershed: "Delineating watershed",
};

// Terrain analysis (GeoLibre-style "Processing" tools), backed by
// WhiteboxTools server-side — see apps/api/src/lib/terrain.ts. Unlike
// AnalysisPanel (buffer/intersect, which run against a selected vector
// layer), these tools run against "whatever DEM covers the current map
// view" — there's no selected layer involved, so this panel takes the
// live viewport bounds reported by MapCanvas instead of a layer prop.
export default function TerrainPanel({
  mapId,
  bounds,
  onCreated,
  pourPoint,
  pickingPourPoint,
  onStartPickPourPoint,
  onClearPourPoint,
}: Props) {
  const [azimuth, setAzimuth] = useState(315);
  const [altitude, setAltitude] = useState(45);
  const [slopeUnits, setSlopeUnits] = useState<"degrees" | "percent">("degrees");
  const [contourInterval, setContourInterval] = useState(50);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // WhiteboxTools runs as a single request/response on the server — there's
  // no real incremental progress being streamed back, so this is a
  // time-based *estimate* meant to reassure the user something's actually
  // happening, not a literal measurement. It climbs quickly at first, eases
  // off approaching 95% while the request is still in flight (so it never
  // falsely claims to be done), then jumps to 100% the moment the response
  // actually arrives.
  const [progress, setProgress] = useState(0);

  async function run(tool: string, fn: () => Promise<unknown>) {
    setBusy(tool);
    setError(null);
    setProgress(5);
    const interval = window.setInterval(() => {
      setProgress((p) => (p >= 95 ? p : p + (95 - p) * 0.08 + 0.3));
    }, 250);
    try {
      await fn();
      window.clearInterval(interval);
      setProgress(100);
      // Brief pause so the bar visibly reaches 100% instead of jumping
      // straight from ~95% to disappearing.
      await new Promise((resolve) => setTimeout(resolve, 350));
      onCreated();
    } catch (err) {
      window.clearInterval(interval);
      setError(err instanceof Error ? err.message : `${tool} failed.`);
    } finally {
      window.clearInterval(interval);
      setBusy(null);
      setProgress(0);
    }
  }

  const runHillshade = () => bounds && run("hillshade", () => api.runHillshade(mapId, { bbox: bounds, azimuth, altitude }));
  const runSlope = () => bounds && run("slope", () => api.runSlope(mapId, { bbox: bounds, units: slopeUnits }));
  const runAspect = () => bounds && run("aspect", () => api.runAspect(mapId, { bbox: bounds }));
  const runContours = () => bounds && run("contours", () => api.runContours(mapId, { bbox: bounds, intervalMeters: contourInterval }));
  const runWatershed = () =>
    bounds && pourPoint && run("watershed", () => api.runWatershed(mapId, { bbox: bounds, pourPoint }));

  if (!bounds) {
    return <div className="empty-note">Waiting for the map to finish loading…</div>;
  }

  return (
    <div className="analysis-box">
      {/* Sticky to the top of this scrollable panel (not just placed first
          in the DOM) so it stays visible no matter which tool section below
          you're scrolled to when you click "Run" — previously this only
          appeared after Watershed, at the very bottom, so running Hillshade
          (the first tool) meant scrolling all the way down to see whether
          anything had happened. */}
      {(busy || error) && (
        <div className={"terrain-status" + (error ? " error" : " busy")}>
          {error ? (
            error
          ) : (
            <>
              <div>{(busy && BUSY_LABELS[busy]) || "Running"}… this can take up to a minute for a larger area.</div>
              <div className="terrain-progress-track">
                <div className="terrain-progress-fill" style={{ width: `${Math.round(progress)}%` }} />
              </div>
              <div className="terrain-progress-pct">{Math.round(progress)}%</div>
            </>
          )}
        </div>
      )}

      <p>
        Run terrain analysis on <b>the current map view</b>. Elevation data is fetched automatically for whatever's
        visible on screen — pan/zoom the map to the area you want first, then run a tool below. Results are added as
        a new layer on this map.
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
      <button className="btn btn-primary" disabled={!!busy} onClick={runHillshade}>
        {busy === "hillshade" ? "Generating hillshade…" : "Run hillshade"}
      </button>

      <h4 style={{ marginTop: 22 }}>Slope</h4>
      <p className="muted-sm">Steepness at every point, colorized from flat (green) to steep (red).</p>
      <div className="analysis-row">
        <select value={slopeUnits} onChange={(e) => setSlopeUnits(e.target.value as "degrees" | "percent")}>
          <option value="degrees">Degrees</option>
          <option value="percent">Percent</option>
        </select>
      </div>
      <button className="btn btn-primary" disabled={!!busy} onClick={runSlope}>
        {busy === "slope" ? "Generating slope…" : "Run slope"}
      </button>

      <h4 style={{ marginTop: 22 }}>Aspect</h4>
      <p className="muted-sm">
        Compass direction each slope faces, colorized as a hue wheel (north/south/east/west each get a distinct color).
      </p>
      <button className="btn btn-primary" disabled={!!busy} onClick={runAspect}>
        {busy === "aspect" ? "Generating aspect…" : "Run aspect"}
      </button>

      <h4 style={{ marginTop: 22 }}>Contours</h4>
      <p className="muted-sm">Elevation isolines at a fixed interval, added as a new line layer.</p>
      <div className="analysis-row">
        <input
          type="number"
          min={1}
          step={5}
          value={contourInterval}
          onChange={(e) => setContourInterval(parseFloat(e.target.value) || 0)}
        />
        <span className="muted-sm">meters interval</span>
      </div>
      <button className="btn btn-primary" disabled={!!busy} onClick={runContours}>
        {busy === "contours" ? "Generating contours…" : "Run contours"}
      </button>

      <h4 style={{ marginTop: 22 }}>Watershed</h4>
      <p className="muted-sm">
        Delineates the upstream catchment area that drains to a point you pick — click "Pick pour point," then click
        anywhere on the map.
      </p>
      <div className="analysis-row">
        <button className={"btn" + (pickingPourPoint ? " btn-primary" : "")} onClick={onStartPickPourPoint} disabled={!!busy}>
          {pickingPourPoint ? "Click the map…" : pourPoint ? "Pick a different point" : "Pick pour point"}
        </button>
        {pourPoint && (
          <button className="btn btn-sm" onClick={onClearPourPoint} disabled={!!busy}>
            Clear
          </button>
        )}
      </div>
      {pourPoint && (
        <p className="muted-sm">
          Pour point: {pourPoint.lat.toFixed(5)}, {pourPoint.lon.toFixed(5)}
        </p>
      )}
      <button className="btn btn-primary" disabled={!!busy || !pourPoint} onClick={runWatershed}>
        {busy === "watershed" ? "Delineating watershed…" : "Run watershed"}
      </button>
    </div>
  );
}
