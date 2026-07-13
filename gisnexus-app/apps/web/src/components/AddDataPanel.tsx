import { useState } from "react";
import { CatalogEntry, groupByCategory, SERVICE_CATALOG, SERVICE_TYPE_LABEL } from "../lib/serviceCatalog";

interface Props {
  onAdd: (entry: CatalogEntry) => Promise<void>;
  onClose: () => void;
}

export default function AddDataPanel({ onAdd, onClose }: Props) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [addedIds, setAddedIds] = useState<Set<string>>(new Set());
  const [errors, setErrors] = useState<Record<string, string>>({});
  const groups = groupByCategory(SERVICE_CATALOG);

  async function handleAdd(entry: CatalogEntry) {
    setBusyId(entry.id);
    setErrors((prev) => ({ ...prev, [entry.id]: "" }));
    try {
      await onAdd(entry);
      setAddedIds((prev) => new Set(prev).add(entry.id));
      setTimeout(() => {
        setAddedIds((prev) => {
          const next = new Set(prev);
          next.delete(entry.id);
          return next;
        });
      }, 2500);
    } catch (err) {
      setErrors((prev) => ({ ...prev, [entry.id]: err instanceof Error ? err.message : "Couldn't add this layer." }));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal add-data-modal" onClick={(e) => e.stopPropagation()}>
        <h3>Add data</h3>
        <p className="muted-sm">
          Add a basemap, imagery, or demo layer from a free, keyless web service — saved to this map like any other
          layer. XYZ/WMS/WMTS render live as tiles; WFS/ArcGIS/GeoJSON layers are imported once as a snapshot, like an
          upload.
        </p>
        <div className="add-data-groups">
          {groups.map(({ category, entries }) => (
            <div className="add-data-group" key={category}>
              <h4>{category}</h4>
              {entries.map((entry) => (
                <div className="add-data-item" key={entry.id}>
                  <span className={`type-badge type-${entry.serviceType}`}>{SERVICE_TYPE_LABEL[entry.serviceType]}</span>
                  <span className="add-data-name">{entry.name}</span>
                  {addedIds.has(entry.id) && <span className="add-data-added">Added ✓</span>}
                  <button className="btn btn-sm" disabled={busyId === entry.id} onClick={() => handleAdd(entry)}>
                    {busyId === entry.id ? "Adding…" : "+ Add"}
                  </button>
                  {errors[entry.id] && <div className="add-data-error">{errors[entry.id]}</div>}
                </div>
              ))}
            </div>
          ))}
        </div>
        <button className="btn" style={{ marginTop: 16 }} onClick={onClose}>
          Close
        </button>
      </div>
    </div>
  );
}
