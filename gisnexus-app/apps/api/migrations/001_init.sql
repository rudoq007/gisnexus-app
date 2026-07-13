-- GISNEXUS initial schema
-- Requires PostGIS. On managed providers (e.g. Supabase) enable the "postgis" extension
-- in the dashboard first, or run: CREATE EXTENSION IF NOT EXISTS postgis;

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text UNIQUE NOT NULL,
  password_hash text NOT NULL,
  name          text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Maps
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS maps (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         text NOT NULL,
  description  text,
  visibility   text NOT NULL DEFAULT 'private' CHECK (visibility IN ('private','unlisted','public')),
  share_token  text UNIQUE,
  view_state   jsonb NOT NULL DEFAULT '{"center":[-122.42,37.77],"zoom":11}'::jsonb,
  components   jsonb NOT NULL DEFAULT '[]'::jsonb, -- dashboard component layout
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS maps_owner_idx ON maps(owner_id);
CREATE INDEX IF NOT EXISTS maps_share_token_idx ON maps(share_token);

-- ---------------------------------------------------------------------------
-- Map collaborators (sharing / permissions beyond the owner)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS map_collaborators (
  map_id     uuid NOT NULL REFERENCES maps(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('editor','viewer')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (map_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Layers
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS layers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  map_id       uuid NOT NULL REFERENCES maps(id) ON DELETE CASCADE,
  name         text NOT NULL,
  geom_type    text NOT NULL CHECK (geom_type IN ('Point','LineString','Polygon')),
  style        jsonb NOT NULL DEFAULT '{"color":"#1F5F4A","opacity":0.8,"size":6}'::jsonb,
  popup_fields jsonb NOT NULL DEFAULT '[]'::jsonb,
  source       text NOT NULL DEFAULT 'upload', -- upload | buffer | intersect
  sort_order   int NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS layers_map_idx ON layers(map_id);

-- ---------------------------------------------------------------------------
-- Features (geometry stored in WGS84 / EPSG:4326)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS features (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  layer_id   uuid NOT NULL REFERENCES layers(id) ON DELETE CASCADE,
  geom       geometry(Geometry, 4326) NOT NULL,
  properties jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS features_layer_idx ON features(layer_id);
CREATE INDEX IF NOT EXISTS features_geom_idx ON features USING GIST(geom);
CREATE INDEX IF NOT EXISTS features_properties_idx ON features USING GIN(properties);
