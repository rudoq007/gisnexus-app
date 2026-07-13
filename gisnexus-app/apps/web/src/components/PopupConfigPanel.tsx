interface Props {
  allFields: string[];
  selectedFields: string[];
  onChange: (fields: string[]) => void;
}

export default function PopupConfigPanel({ allFields, selectedFields, onChange }: Props) {
  if (!allFields.length) {
    return (
      <div className="sidebar-section">
        <h4>Popup fields</h4>
        <div className="empty-note">This layer has no attribute fields.</div>
      </div>
    );
  }
  return (
    <div className="sidebar-section">
      <h4>Popup fields</h4>
      <div className="popup-fields">
        {allFields.map((key) => (
          <label key={key}>
            <input
              type="checkbox"
              checked={selectedFields.includes(key)}
              onChange={(e) => {
                if (e.target.checked) onChange([...selectedFields, key]);
                else onChange(selectedFields.filter((k) => k !== key));
              }}
            />
            {key}
          </label>
        ))}
      </div>
    </div>
  );
}
