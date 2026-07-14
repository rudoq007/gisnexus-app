import { LayerDto } from "../api/client";

interface Props {
  layers: LayerDto[];
  visibleIds: Set<string>;
  selectedId: string | null;
  onToggleVisible: (id: string) => void;
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
  onDownload: (id: string) => void;
  canEdit: boolean;
}

// A layer is downloadable if it's vector data (uploads, buffer/intersect
// results, Contours, Watershed, ...) or a single georeferenced raster image
// produced by a terrain tool (Hillshade/Slope/Aspect). Tile-service raster
// layers (XYZ/WMS/WMTS basemaps added via "Add data") are a live service,
// not a fixed dataset, so there's nothing to export.
function isDownloadable(layer: LayerDto) {
  return layer.kind !== "raster" || layer.service?.type === "image";
}

export default function LayerList({
  layers,
  visibleIds,
  selectedId,
  onToggleVisible,
  onSelect,
  onDelete,
  onDownload,
  canEdit,
}: Props) {
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
          {isDownloadable(layer) && (
            <button
              className="dl"
              title="Download layer"
              onClick={(e) => {
                e.stopPropagation();
                onDownload(layer.id);
              }}
            >
              ⬇
            </button>
          )}
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
