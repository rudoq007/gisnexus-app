import { Link, Navigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const FEATURES = [
  {
    title: "Upload anything",
    body: "Drop in GeoJSON, a zipped Shapefile, CSV, or KML — GISNEXUS parses it and puts it on the map as a styled layer in seconds.",
  },
  {
    title: "Layers",
    body: "Every dataset becomes a layer you can style and analyze — with a live data table and configurable popups.",
  },
  {
    title: "Dashboards",
    body: "Turn any layer into a chart. Pick a field, see the breakdown — no configuration required.",
  },
  {
    title: "Live map services",
    body: "Add basemaps, imagery, and public datasets from free WFS, ArcGIS, WMS, WMTS, and XYZ services — no API key needed for the built-in catalog.",
  },
  {
    title: "Sharing & collaboration",
    body: "Invite collaborators as editors or viewers, then publish a read-only link — public or unlisted — for anyone to view without an account.",
  },
];

const PERSONAS = [
  { title: "Urban Planning", body: "Zoning review, parcel analysis, and public-engagement maps that residents can actually use." },
  { title: "Environmental Science", body: "Site monitoring, habitat mapping, and shareable maps for compliance reporting." },
  { title: "Real Estate", body: "Site selection, comps mapping, and investor-facing dashboards built without a designer." },
  { title: "Logistics", body: "Territory planning and service-area coverage analysis, mapped and shared in minutes." },
];

const STEPS = [
  { title: "Upload", body: "Drop in a GeoJSON, Shapefile, CSV, or KML file." },
  { title: "Style", body: "Turn the dataset into a layer — style it and configure popups." },
  { title: "Compose", body: "Layer up your map, then switch to the Dashboard tab to chart any field." },
  { title: "Share", body: "Publish as a public or unlisted link — no account needed to view." },
];

const STATS = [
  { n: "< 60s", l: "From upload to styled layer" },
  { n: "4 formats", l: "GeoJSON, Shapefile, CSV & KML uploads" },
  { n: "6 live services", l: "WFS, ArcGIS, WMS, WMTS, XYZ & more" },
  { n: "0 installs", l: "Runs entirely in your browser" },
];

function Logo({ small }: { small?: boolean }) {
  const s = small ? 24 : 30;
  return (
    <svg width={s} height={s} viewBox="0 0 32 32" fill="none">
      <rect width="32" height="32" rx="8" fill="#1F5F4A" />
      <path d="M6 21L12 12L17 18L22 9L26 15" stroke="#E9F2EE" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
      {!small && (
        <>
          <circle cx="12" cy="12" r="1.8" fill="#E08E45" />
          <circle cx="22" cy="9" r="1.8" fill="#E08E45" />
        </>
      )}
    </svg>
  );
}

export default function LandingPage() {
  const { user, loading } = useAuth();

  if (!loading && user) return <Navigate to="/maps" replace />;

  return (
    <div className="landing-page">
      <header className="landing-nav-bar">
        <div className="landing-wrap landing-nav">
          <div className="landing-logo">
            <Logo />
            GISNEXUS
          </div>
          <nav className="landing-nav-links">
            <a href="#features">Features</a>
            <a href="#personas">Who it's for</a>
            <a href="#workflow">How it works</a>
          </nav>
          <div className="landing-nav-cta">
            <Link className="landing-btn landing-btn-ghost" to="/login">
              Sign in
            </Link>
            <Link className="landing-btn landing-btn-primary" to="/register">
              Get started free
            </Link>
          </div>
        </div>
      </header>

      <section className="landing-hero">
        <div className="landing-wrap">
          <span className="landing-eyebrow">🗺️ Cloud-native GIS, reimagined</span>
          <h1>
            Create maps and <span>dashboards</span> in seconds.
          </h1>
          <p className="landing-lead">
            GISNEXUS turns spatial files — GeoJSON, Shapefiles, CSVs, KML — or live map services into a shareable,
            interactive map. No installs, no GIS degree required. Built for urban planning, environmental science,
            real estate, and logistics teams.
          </p>
          <div className="landing-hero-ctas">
            <Link className="landing-btn landing-btn-primary landing-btn-lg" to="/register">
              Start mapping free
            </Link>
            <a className="landing-btn landing-btn-ghost landing-btn-lg" href="#features">
              Explore features →
            </a>
          </div>
          <div className="landing-hero-note">No credit card required to get started.</div>

          <div className="landing-map-preview">
            <div className="landing-preview-bar">
              <span className="landing-dot" style={{ background: "#E4635A" }} />
              <span className="landing-dot" style={{ background: "#E6B84D" }} />
              <span className="landing-dot" style={{ background: "#4FAE7A" }} />
            </div>
            <div className="landing-map-canvas">
              <svg viewBox="0 0 1000 380" preserveAspectRatio="none">
                <path d="M0 260 L120 240 L220 270 L340 230 L460 255 L600 210 L720 245 L860 220 L1000 250 L1000 380 L0 380 Z" fill="#CFE6DB" />
                <path d="M0 300 L150 285 L280 305 L420 280 L560 300 L700 270 L860 295 L1000 280 L1000 380 L0 380 Z" fill="#B9DBC9" />
                <g stroke="#8FC2AA" strokeWidth="1.5" opacity="0.6">
                  <path d="M0 100 H1000" />
                  <path d="M0 160 H1000" />
                  <path d="M0 220 H1000" />
                  <path d="M150 0 V380" />
                  <path d="M400 0 V380" />
                  <path d="M650 0 V380" />
                  <path d="M900 0 V380" />
                </g>
                <circle cx="300" cy="150" r="7" fill="#1F5F4A" />
                <circle cx="430" cy="120" r="7" fill="#1F5F4A" />
                <circle cx="520" cy="190" r="7" fill="#E08E45" />
                <circle cx="620" cy="140" r="7" fill="#1F5F4A" />
                <circle cx="700" cy="200" r="7" fill="#1F5F4A" />
                <circle cx="760" cy="110" r="7" fill="#E08E45" />
                <path d="M300 150 L430 120 L620 140 L700 200" stroke="#1F5F4A" strokeWidth="2" fill="none" strokeDasharray="4 4" />
              </svg>
              <div className="landing-layer-panel">
                <h4>Layers</h4>
                <div className="landing-layer-row">
                  <span className="landing-swatch" style={{ background: "#1F5F4A" }} /> Zoning parcels
                </div>
                <div className="landing-layer-row">
                  <span className="landing-swatch" style={{ background: "#E08E45" }} /> Flood risk zones
                </div>
                <div className="landing-layer-row">
                  <span className="landing-swatch" style={{ background: "#4FAE7A" }} /> Transit routes
                </div>
              </div>
              <div className="landing-popup-card">
                <div className="landing-popup-t">Parcel #4821-A</div>
                <div className="landing-popup-m">
                  Zoning: Mixed-use · Flood zone: X
                  <br />
                  Updated 2 hours ago
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <div className="landing-stats">
        <div className="landing-wrap landing-stats-grid">
          {STATS.map((s) => (
            <div className="landing-stat" key={s.l}>
              <div className="landing-stat-n">{s.n}</div>
              <div className="landing-stat-l">{s.l}</div>
            </div>
          ))}
        </div>
      </div>

      <section id="features">
        <div className="landing-wrap">
          <div className="landing-section-head">
            <div className="landing-kicker">Key features</div>
            <h2>Everything you need to go from data to decision</h2>
            <p>One platform for ingesting, styling, analyzing, and sharing spatial data.</p>
          </div>
          <div className="landing-features-grid">
            {FEATURES.map((f) => (
              <div className="landing-feature-card" key={f.title}>
                <h3>{f.title}</h3>
                <p>{f.body}</p>
              </div>
            ))}
            <div className="landing-feature-card landing-feature-wide">
              <div className="landing-feature-wide-inner">
                <div style={{ flex: 1, minWidth: 240 }}>
                  <h3>Spatial Analysis</h3>
                  <p>
                    Run buffer and intersect analysis directly on your layers — no coding, no separate GIS software
                    required.
                  </p>
                </div>
                <div className="landing-feature-wide-tags">Buffer · Intersect</div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section id="personas" className="landing-personas">
        <div className="landing-wrap">
          <div className="landing-section-head">
            <div className="landing-kicker">Built for spatial decisions</div>
            <h2>Whatever "where" means for your work</h2>
            <p>GISNEXUS adapts to how spatial questions actually get asked across four core industries.</p>
          </div>
          <div className="landing-persona-grid">
            {PERSONAS.map((p) => (
              <div className="landing-persona-card" key={p.title}>
                <h3>{p.title}</h3>
                <p>{p.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section id="workflow">
        <div className="landing-wrap">
          <div className="landing-section-head">
            <div className="landing-kicker">How it works</div>
            <h2>From raw data to a published map</h2>
            <p>Four steps, no file exports, no waiting on a GIS specialist.</p>
          </div>
          <div className="landing-workflow-steps">
            {STEPS.map((s, i) => (
              <div className="landing-step" key={s.title}>
                <div className="landing-step-num">{i + 1}</div>
                <h3>{s.title}</h3>
                <p>{s.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section>
        <div className="landing-cta-band">
          <h2>Your next map takes seconds, not sprints.</h2>
          <p>Turn spreadsheets and shapefiles into shareable, interactive maps — today.</p>
          <Link className="landing-btn landing-btn-primary landing-btn-lg" to="/register">
            Start mapping free
          </Link>
        </div>
      </section>

      <footer className="landing-footer">
        <div className="landing-wrap landing-foot-grid">
          <div className="landing-logo landing-logo-sm">
            <Logo small />
            GISNEXUS
          </div>
          <div className="landing-foot-links">
            <a href="#features">Features</a>
            <a href="#personas">Who it's for</a>
            <a href="#workflow">How it works</a>
          </div>
          <div className="landing-foot-note">© {new Date().getFullYear()} GISNEXUS</div>
        </div>
      </footer>
    </div>
  );
}
