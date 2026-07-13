import { useEffect, useState } from "react";
import { api, AggregateBar, GeoFeatureCollection, LayerDto } from "../api/client";

interface Props {
  layer: LayerDto;
  data: GeoFeatureCollection | null;
}

export default function DashboardChart({ layer, data }: Props) {
  const fields = Array.from(new Set((data?.features || []).flatMap((f) => Object.keys(f.properties || {}))));
  const [field, setField] = useState<string>(fields[0] || "");
  const [bars, setBars] = useState<AggregateBar[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (fields.length && !fields.includes(field)) setField(fields[0]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [layer.id]);

  useEffect(() => {
    if (!field) return;
    setError(null);
    api
      .aggregateField(layer.id, field)
      .then((res) => setBars(res.bars))
      .catch((err) => setError(err instanceof Error ? err.message : "Couldn't load chart."));
  }, [layer.id, field]);

  if (!fields.length) return <div className="empty-note">This layer has no attribute fields to chart.</div>;

  const maxVal = Math.max(...(bars || []).map((b) => b.value), 1);

  return (
    <div>
      <div className="dash-controls">
        <div className="fg">
          <label>Field</label>
          <select value={field} onChange={(e) => setField(e.target.value)}>
            {fields.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </div>
      </div>
      {error && <div className="auth-error">{error}</div>}
      {bars &&
        bars.map((b) => (
          <div className="bar-row" key={b.label}>
            <div className="bar-label" title={b.label}>
              {b.label}
            </div>
            <div className="bar-track">
              <div className="bar-fill" style={{ width: `${Math.max((b.value / maxVal) * 100, 3)}%` }}>
                <span className="bar-val">{b.value}</span>
              </div>
            </div>
          </div>
        ))}
    </div>
  );
}
