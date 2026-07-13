import { ServiceType } from "../api/client";

/**
 * Built-in "Add Data" catalog — a small, free/keyless set of demo web
 * services so the Add Data panel is useful out of the box, without any API
 * keys or accounts. Deliberately global in coverage rather than US-specific:
 * OpenStreetMap + OpenTopoMap basemaps, NASA GIBS daily satellite imagery,
 * GEBCO ocean bathymetry, EOX Sentinel-2 cloudless, Natural Earth world
 * country boundaries, and an Esri-hosted world cities FeatureServer. Swap or
 * extend this list with sources relevant to your own work — each entry is
 * just a name, category, service type, and a field bag that's sent straight
 * to `POST /api/maps/:mapId/layers/service`.
 */
export interface CatalogEntry {
  id: string;
  name: string;
  category: string;
  serviceType: ServiceType;
  /** Field values for the given service type — see apps/api/src/lib/geo.ts for what each type expects. */
  fields: Record<string, string | number | boolean>;
}

export const SERVICE_CATALOG: readonly CatalogEntry[] = [
  {
    id: "osm",
    name: "OpenStreetMap",
    category: "Basemaps",
    serviceType: "xyz",
    fields: {
      url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
      tileSize: 256,
      attribution: "© OpenStreetMap contributors",
    },
  },
  {
    id: "opentopomap",
    name: "OpenTopoMap",
    category: "Basemaps",
    serviceType: "xyz",
    fields: {
      url: "https://tile.opentopomap.org/{z}/{x}/{y}.png",
      tileSize: 256,
      attribution: "Map data: © OpenStreetMap contributors, SRTM | Map style: © OpenTopoMap (CC-BY-SA)",
    },
  },
  {
    id: "nasa-gibs-truecolor",
    name: "NASA satellite imagery (MODIS true color)",
    category: "Imagery",
    serviceType: "wms",
    fields: {
      endpoint: "https://gibs.earthdata.nasa.gov/wms/epsg3857/best/wms.cgi",
      layers: "MODIS_Terra_CorrectedReflectance_TrueColor",
      format: "image/jpeg",
      transparent: false,
      version: "1.3.0",
      tileSize: 256,
      // "default" always resolves to the most recent available daily composite.
      time: "default",
      attribution: "Imagery courtesy NASA Global Imagery Browse Services (GIBS) / MODIS",
    },
  },
  {
    id: "gebco-bathymetry",
    name: "GEBCO Ocean Bathymetry",
    category: "Imagery",
    serviceType: "wms",
    fields: {
      endpoint: "https://wms.gebco.net/mapserv",
      layers: "GEBCO_LATEST",
      format: "image/png",
      transparent: true,
      version: "1.3.0",
      tileSize: 256,
      attribution: "GEBCO Compilation Group — gebco.net",
    },
  },
  {
    id: "eox-s2cloudless",
    name: "Sentinel-2 cloudless (EOX)",
    category: "Imagery",
    serviceType: "wmts",
    fields: {
      url: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg",
      tileSize: 256,
      attribution: "Sentinel-2 cloudless by EOX IT Services GmbH (contains modified Copernicus Sentinel data)",
    },
  },
  {
    id: "natural-earth-countries",
    name: "World Countries (Natural Earth)",
    category: "Demo data",
    serviceType: "geojson",
    fields: {
      url: "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson",
    },
  },
  {
    id: "arcgis-world-cities",
    name: "World Cities",
    category: "Demo data",
    serviceType: "arcgis",
    fields: {
      url: "https://sampleserver6.arcgisonline.com/arcgis/rest/services/SampleWorldCities/MapServer/0",
    },
  },
];

/** Groups catalog entries by category, preserving each category's first-seen order. */
export function groupByCategory(entries: readonly CatalogEntry[]): { category: string; entries: CatalogEntry[] }[] {
  const order: string[] = [];
  const groups = new Map<string, CatalogEntry[]>();
  for (const entry of entries) {
    if (!groups.has(entry.category)) {
      groups.set(entry.category, []);
      order.push(entry.category);
    }
    groups.get(entry.category)!.push(entry);
  }
  return order.map((category) => ({ category, entries: groups.get(category)! }));
}

/** Short badge text for a service type, shown next to each catalog entry. */
export const SERVICE_TYPE_LABEL: Record<ServiceType, string> = {
  xyz: "XYZ",
  wms: "WMS",
  wmts: "WMTS",
  wfs: "WFS",
  arcgis: "ArcGIS",
  geojson: "GeoJSON",
};
