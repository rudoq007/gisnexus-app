import { useState } from "react";
import { api, LayerDto } from "../api/client";

interface Props {
  layer: LayerDto;
  allLayers: LayerDto[];
  onCreated: () => void;
}

export default function AnalysisPanel({ layer, allLayers, onCreated }: Props) {
  const [distance, setDistance] = useState(500);
  const [otherLayerId, setOtherLayerId] = useState(allLayers.find((l) => l.id !== layer.id)?.id || "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function runBuffer() {
    setBusy(true);
    setError(null);
    try {
      await api.bufferLayer(layer.id, distance);
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Buffer analysis failed.");
    } finally {
      setBusy(false);
    }
  }

  async function runIntersect() {
    if (!otherLayerId) return;
    setBusy(true);
    setError(null);
    try {
      await api.intersectLayers(layer.id, otherLayerId);
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Intersect analysis failed.");
    } finally {
      setBusy(false);
    }
  }

  const otherLayers = allLayers.filter((l) => l.id !== layer.id);

  return (
    <div className="analysis-box">
      <p>
        Run spatial analysis on <b>{layer.name}</b>. Results are added as a new layer on this map.
      </p>

      <h4>Buffer</h4>
      <p className="muted-sm">Create a circular buffer polygon around every feature.</p>
      <div className="analysis-row">
        <input type="number" min={10} step={10} value={distance} onChange={(e) => setDistance(parseFloat(e.target.value) || 0)} />
        <span className="muted-sm">meters radius</span>
      </div>
      <button className="btn btn-primary" disabled={busy} onClick={runBuffer}>
        Create buffer layer
      </button>

      <h4 style={{ marginTop: 22 }}>Intersect</h4>
      <p className="muted-sm">Keep only features that intersect another layer.</p>
      {otherLayers.length === 0 ? (
        <div className="empty-note">Add another layer to run an intersect analysis.</div>
      ) : (
        <>
          <div className="analysis-row">
            <select value={otherLayerId} onChange={(e) => setOtherLayerId(e.target.value)}>
              {otherLayers.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          </div>
          <button className="btn btn-primary" disabled={busy} onClick={runIntersect}>
            Create intersect layer
          </button>
        </>
      )}

      {error && <div className="auth-error" style={{ marginTop: 12 }}>{error}</div>}
    </div>
  );
}
