import { LayerDto } from "../api/client";

interface Props {
  layers: LayerDto[];
  visibleIds: Set<string>;
  selectedId: string | null;
  onToggleVisible: (id: string) => void;
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
  canEdit: boolean;
}

export default function LayerList({ layers, visibleIds, selectedId, onToggleVisible, onSelect, onDelete, canEdit }: Props) {
  if (!layers.length) {
    return <div className="empty-note">No layers yet. Upload a file or add data from the catalog to get started.</div>;
  }
  return (
    <div className="layer-list">
      {layers.map((layer) => (
        <div key={layer.id} className={"layer-item" + (layer.id === selectedId ? " active" : "")} onClick={() => onSelect(layer.id)}>
          <input
            type="checkbox"
            checked={visibleIds.has(layer.id)}
            onChange={(e) => {
              e.stopPropagation();
              onToggleVisible(layer.id);
            }}
            onClick={(e) => e.stopPropagation()}
          />
          {layer.kind === "raster" ? (
            <span className="swatch swatch-raster" title="Basemap/imagery layer">
              🌐
            </span>
          ) : (
            <span className="swatch" style={{ background: layer.style.color }} />
          )}
          <span className="name">{layer.name}</span>
          {canEdit && (
            <button
              className="del"
              title="Delete layer"
              onClick={(e) => {
                e.stopPropagation();
                if (confirm(`Delete layer "${layer.name}"?`)) onDelete(layer.id);
              }}
            >
              ✕
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
