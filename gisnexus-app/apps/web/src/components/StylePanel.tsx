import { LayerDto } from "../api/client";

interface Props {
  layer: LayerDto;
  onChange: (style: Partial<LayerDto["style"]>) => void;
}

export default function StylePanel({ layer, onChange }: Props) {
  const sizeLabel = layer.geom_type === "LineString" ? "Line width" : layer.geom_type === "Polygon" ? "Border width" : "Point radius";
  const sizeMax = layer.geom_type === "Polygon" ? 6 : 16;

  return (
    <div className="sidebar-section">
      <h4>Style — {layer.name}</h4>
      <div className="field-row">
        <label>Color</label>
        <input type="color" value={layer.style.color} onChange={(e) => onChange({ color: e.target.value })} />
      </div>
      <div className="field-row">
        <label>Opacity</label>
        <input
          type="range"
          min={0.1}
          max={1}
          step={0.05}
          value={layer.style.opacity}
          onChange={(e) => onChange({ opacity: parseFloat(e.target.value) })}
        />
        <span className="field-val">{Math.round(layer.style.opacity * 100)}%</span>
      </div>
      <div className="field-row">
        <label>{sizeLabel}</label>
        <input
          type="range"
          min={1}
          max={sizeMax}
          step={0.5}
          value={layer.style.size}
          onChange={(e) => onChange({ size: parseFloat(e.target.value) })}
        />
        <span className="field-val">{layer.style.size}</span>
      </div>
    </div>
  );
}
