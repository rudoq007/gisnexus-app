import { ChangeEvent, useRef, useState } from "react";

interface Props {
  onUpload: (file: File) => Promise<void>;
}

export default function UploadButton({ onUpload }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);

  async function handleChange(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setBusy(true);
    try {
      await onUpload(file);
    } finally {
      setBusy(false);
      if (inputRef.current) inputRef.current.value = "";
    }
  }

  return (
    <>
      <button className="btn btn-primary" disabled={busy} onClick={() => inputRef.current?.click()}>
        {busy ? "Uploading…" : "⬆ Upload file"}
      </button>
      <input
        ref={inputRef}
        type="file"
        accept=".geojson,.json,.csv,.zip,.kml,.gpx"
        style={{ display: "none" }}
        onChange={handleChange}
      />
    </>
  );
}
