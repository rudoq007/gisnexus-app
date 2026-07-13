import { useEffect, useMemo, useState } from "react";
import QRCode from "qrcode";
import MapCanvas from "./MapCanvas";
import { GeoFeatureCollection, LayerDto, MapDto } from "../api/client";

interface Props {
  map: MapDto;
  layers: LayerDto[];
  featuresByLayer: Record<string, GeoFeatureCollection>;
  // null when there's no public/unlisted link to point the QR code at yet.
  shareUrl: string | null;
  onClose: () => void;
}

// Standard "nice" scale-bar distances, in meters.
const NICE_SCALE_STEPS_M = [
  1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000,
];

// Web Mercator meters-per-pixel at a given latitude/zoom (standard 256px tile formula).
function metersPerPixel(lat: number, zoom: number) {
  return (156543.03392 * Math.cos((lat * Math.PI) / 180)) / Math.pow(2, zoom);
}

// Picks the largest "nice" round distance that still renders under ~140px,
// so the printed scale bar reads a clean number ("200 m") instead of
// whatever raw distance happens to span an arbitrary pixel width.
function pickScale(lat: number, zoom: number) {
  const mpp = metersPerPixel(lat, zoom);
  const maxBarMeters = mpp * 140;
  let chosen = NICE_SCALE_STEPS_M[0];
  for (const step of NICE_SCALE_STEPS_M) {
    if (step > maxBarMeters) break;
    chosen = step;
  }
  const widthPx = Math.max(24, chosen / mpp);
  const label = chosen >= 1000 ? `${chosen / 1000} km` : `${chosen} m`;
  return { widthPx, label };
}

// Everything a printed map "should" carry per standard cartographic
// convention (title, legend, scale, north arrow, neatline, credits/labels) —
// see https://www.spatialpost.com/basic-map-elements/ — plus a QR code
// linking back to the live, interactive version.
export default function PrintMapModal({ map, layers, featuresByLayer, shareUrl, onClose }: Props) {
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const printedAt = useMemo(() => new Date(), []);
  const scale = useMemo(() => pickScale(map.view_state.center[1], map.view_state.zoom), [map.view_state]);

  useEffect(() => {
    if (!shareUrl) {
      setQrDataUrl(null);
      return;
    }
    let cancelled = false;
    QRCode.toDataURL(shareUrl, { margin: 1, width: 240, color: { dark: "#16281f", light: "#ffffff" } })
      .then((url) => {
        if (!cancelled) setQrDataUrl(url);
      })
      .catch(() => {
        if (!cancelled) setQrDataUrl(null);
      });
    return () => {
      cancelled = true;
    };
  }, [shareUrl]);

  // Every basemap/imagery attribution string actually attached to a layer on
  // this map, deduped — the raster/service credit chain. OSM is credited
  // unconditionally below since it's always the base layer.
  const dataCredits = Array.from(new Set(layers.map((l) => l.service?.attribution).filter((a): a is string => Boolean(a))));

  return (
    <div className="print-modal-backdrop">
      <div className="print-toolbar">
        <div className="print-toolbar-title">Print preview — adjust the map below, then print</div>
        <div className="print-toolbar-actions">
          <button className="btn btn-primary" onClick={() => window.print()}>
            🖨️ Print / Save as PDF
          </button>
          <button className="btn" onClick={onClose}>
            Close
          </button>
        </div>
      </div>

      <div className="print-sheet">
        <div className="print-sheet-header">
          <h1>{map.name}</h1>
          {map.description && <p>{map.description}</p>}
        </div>

        <div className="print-map-frame">
          <MapCanvas
            layers={layers}
            featuresByLayer={featuresByLayer}
            viewState={map.view_state}
            onViewStateChange={() => {}}
            onFeatureClick={() => {}}
          />

          <div className="print-north-arrow" title="North is up">
            <svg viewBox="0 0 24 34" width="26" height="36">
              <path d="M12 0 L22 34 L12 27 L2 34 Z" fill="#16281f" />
              <text x="12" y="13" textAnchor="middle" fontSize="10" fill="#fff" fontWeight="700">
                N
              </text>
            </svg>
          </div>

          <div className="print-scalebar">
            <div className="print-scalebar-bar" style={{ width: `${scale.widthPx}px` }} />
            <div className="print-scalebar-label">{scale.label}</div>
          </div>

          {layers.length > 0 && (
            <div className="print-legend">
              <h4>Legend</h4>
              {layers.map((l) => (
                <div className="print-legend-row" key={l.id}>
                  {l.kind === "raster" ? (
                    <span className="print-legend-swatch print-legend-swatch-raster">🌐</span>
                  ) : (
                    <span className="print-legend-swatch" style={{ background: l.style.color }} />
                  )}
                  {l.name}
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="print-sheet-footer">
          <div className="print-credits">
            <div>
              <b>Data sources:</b> © OpenStreetMap contributors{dataCredits.length ? `, ${dataCredits.join(", ")}` : ""}.
            </div>
            <div>
              <b>Created:</b> {new Date(map.created_at).toLocaleDateString()} &nbsp;·&nbsp; <b>Printed:</b>{" "}
              {printedAt.toLocaleDateString()}
            </div>
            <div>
              <b>Projection:</b> Web Mercator (EPSG:3857) &nbsp;·&nbsp; Made with GISNEXUS
            </div>
          </div>
          <div className="print-qr">
            {qrDataUrl ? (
              <>
                <img src={qrDataUrl} width={72} height={72} alt="QR code linking to this map" />
                <span>Scan to open online</span>
              </>
            ) : (
              <span className="print-qr-note">Set sharing to Unlisted or Public to include a scannable link.</span>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
