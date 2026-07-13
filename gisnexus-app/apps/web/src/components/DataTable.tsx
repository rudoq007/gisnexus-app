import { GeoFeatureCollection } from "../api/client";

interface Props {
  data: GeoFeatureCollection | null;
}

export default function DataTable({ data }: Props) {
  if (!data) return <div className="empty-note">Select a layer to view its data.</div>;
  const fields = new Set<string>();
  data.features.forEach((f) => Object.keys(f.properties || {}).forEach((k) => fields.add(k)));
  const fieldList = Array.from(fields);
  const rows = data.features.slice(0, 200);

  if (!fieldList.length) return <div className="empty-note">This layer has no attribute fields.</div>;

  return (
    <>
      <table className="datatable">
        <thead>
          <tr>
            {fieldList.map((f) => (
              <th key={f}>{f}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((f) => (
            <tr key={f.id}>
              {fieldList.map((k) => (
                <td key={k}>{String(f.properties[k] ?? "")}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {data.features.length > 200 && <div className="empty-note">Showing first 200 of {data.features.length} rows.</div>}
    </>
  );
}
