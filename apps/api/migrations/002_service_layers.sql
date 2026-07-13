-- Adds support for "service" layers: external raster tile services (XYZ/WMS/WMTS)
-- rendered live by MapLibre with no rows in `features`, and external vector
-- services (WFS/ArcGIS FeatureServer) whose features are fetched once at
-- add-time and imported into `features` just like an upload.
--
-- `kind` distinguishes the two: 'vector' layers (uploads, buffer/intersect
-- results, imported WFS/ArcGIS data) have rows in `features` and a geom_type;
-- 'raster' layers are rendered directly from `service` and have neither.

ALTER TABLE layers ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'vector' CHECK (kind IN ('vector','raster'));
ALTER TABLE layers ADD COLUMN IF NOT EXISTS service jsonb; -- null for uploads/analysis outputs; service config for source='service' layers

-- Raster layers have no geometry type — relax the existing NOT NULL/CHECK so
-- geom_type can be left NULL for them.
ALTER TABLE layers ALTER COLUMN geom_type DROP NOT NULL;
ALTER TABLE layers DROP CONSTRAINT IF EXISTS layers_geom_type_check;
ALTER TABLE layers ADD CONSTRAINT layers_geom_type_check CHECK (geom_type IS NULL OR geom_type IN ('Point','LineString','Polygon'));
ALTER TABLE layers ADD CONSTRAINT layers_kind_geom_type_check CHECK (
  (kind = 'raster' AND geom_type IS NULL) OR (kind = 'vector' AND geom_type IS NOT NULL)
);
