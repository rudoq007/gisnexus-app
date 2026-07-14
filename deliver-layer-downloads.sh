#!/usr/bin/env bash
# GISNEXUS — Download any layer (GeoJSON for vector, GeoTIFF for terrain
# raster outputs). Entirely a frontend feature — no backend/API changes,
# no Docker changes, nothing to redeploy on Render beyond the usual push.
#
# Run this from the ROOT of your gisnexus-app repo, in Git Bash:
#   bash deliver-layer-downloads.sh
set -e

echo "Writing apps/web/package.json ..."
cat > apps/web/package.json <<'EOF'
{
  "name": "@gisnexus/web",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview",
    "typecheck": "tsc --noEmit",
    "deploy": "npm run build && wrangler pages deploy dist --project-name=gisnexus-app"
  },
  "dependencies": {
    "geotiff": "^2.1.3",
    "maplibre-gl": "^4.5.0",
    "qrcode": "^1.5.4",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.25.1"
  },
  "devDependencies": {
    "@types/qrcode": "^1.5.5",
    "@types/react": "^18.3.3",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "^5.5.3",
    "vite": "^6.0.0",
    "wrangler": "^4.0.0"
  }
}
EOF

echo "Writing apps/web/src/styles.css ..."
cat > apps/web/src/styles.css <<'EOF'
:root {
  /* Premium/futuristic palette — deep space base, electric violet→cyan
     accent gradient, glass surfaces. See PrintMapModal-related rules below
     for the one deliberate exception: printed PDF output stays light/white
     for paper, so those rules hardcode light colors instead of these vars. */
  --bg: #05060c;
  --bg-glow-1: rgba(124, 92, 255, 0.22);
  --bg-glow-2: rgba(34, 211, 238, 0.14);
  --surface: #0d0f1c;
  --surface-2: #12152a;
  --surface-soft: rgba(255, 255, 255, 0.04);
  --glass: rgba(12, 14, 26, 0.72);
  --line: rgba(255, 255, 255, 0.1);
  --line-strong: rgba(255, 255, 255, 0.2);

  --brand: #7c5cff;
  --brand-2: #22d3ee;
  --brand-dark: #5b3df0;
  --brand-light: rgba(124, 92, 255, 0.14);
  --gradient: linear-gradient(135deg, #7c5cff 0%, #22d3ee 100%);
  --glow: 0 8px 30px rgba(124, 92, 255, 0.3);

  --ink: #f4f5fb;
  --ink-soft: #9aa3c7;
  --ink-faint: #626c92;
  --white: #ffffff;
  --danger: #ff5c7a;
  --danger-bg: rgba(255, 92, 122, 0.12);

  --font: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-display: "Space Grotesk", "Inter", -apple-system, BlinkMacSystemFont, sans-serif;
}
* { box-sizing: border-box; }
html, body, #root { height: 100%; margin: 0; }
body {
  font-family: var(--font);
  color: var(--ink);
  background:
    radial-gradient(1100px circle at 12% -10%, var(--bg-glow-1), transparent 60%),
    radial-gradient(900px circle at 100% 0%, var(--bg-glow-2), transparent 55%),
    var(--bg);
  background-attachment: fixed;
}
button { font-family: inherit; cursor: pointer; }
input, select { font-family: inherit; }
::selection { background: var(--brand); color: var(--white); }
*:focus-visible { outline: 2px solid var(--brand-2); outline-offset: 2px; }

/* Slim, glassy scrollbars for the panels that scroll */
.sidebar::-webkit-scrollbar, .add-data-groups::-webkit-scrollbar, .bottom-content::-webkit-scrollbar, .print-legend::-webkit-scrollbar {
  width: 8px;
}
.sidebar::-webkit-scrollbar-thumb, .add-data-groups::-webkit-scrollbar-thumb, .bottom-content::-webkit-scrollbar-thumb {
  background: var(--line-strong); border-radius: 8px;
}

.page-loading { display: flex; align-items: center; justify-content: center; height: 100vh; color: var(--ink-soft); font-family: var(--font-display); letter-spacing: 0.02em; }

/* Header */
.app-header {
  height: 56px; display: flex; align-items: center; justify-content: space-between;
  padding: 0 18px; border-bottom: 1px solid var(--line);
  background: var(--glass); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
}
.logo { font-family: var(--font-display); font-weight: 700; font-size: 17px; letter-spacing: -0.01em; background: var(--gradient); -webkit-background-clip: text; background-clip: text; color: transparent; }
.map-title { font-weight: 700; color: var(--ink-soft); flex: 1; text-align: center; }
.header-actions { display: flex; gap: 10px; align-items: center; }
.badge {
  background: var(--brand-light); color: var(--brand-2); font-size: 11px; font-weight: 700;
  padding: 4px 10px; border-radius: 999px; border: 1px solid rgba(124,92,255,0.3);
}

.btn {
  display: inline-flex; align-items: center; gap: 6px; padding: 8px 14px; border-radius: 9px;
  font-weight: 700; font-size: 13px; border: 1px solid var(--line); background: var(--surface-soft); color: var(--ink);
  transition: border-color .15s ease, color .15s ease, background .15s ease, transform .15s ease;
}
.btn:hover { border-color: var(--brand-2); color: var(--brand-2); background: rgba(124,92,255,0.08); }
.btn-primary {
  background: var(--gradient); color: #fff; border-color: transparent;
  box-shadow: 0 4px 18px rgba(124,92,255,0.35);
}
.btn-primary:hover { color: #fff; transform: translateY(-1px); box-shadow: 0 8px 26px rgba(124,92,255,0.5); background: var(--gradient); }
.btn-sm { padding: 5px 10px; font-size: 12px; border-radius: 6px; }

/* Auth pages */
.auth-page { min-height: 100vh; display: flex; align-items: center; justify-content: center; }
.auth-card {
  background: var(--glass); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
  border: 1px solid var(--line); border-radius: 18px; padding: 40px; width: 380px;
  box-shadow: 0 30px 70px rgba(0,0,0,0.5), 0 0 0 1px rgba(124,92,255,0.06);
}
.auth-logo { font-family: var(--font-display); font-weight: 700; background: var(--gradient); -webkit-background-clip: text; background-clip: text; color: transparent; margin-bottom: 8px; }
.auth-card h1 { font-family: var(--font-display); font-size: 22px; margin: 0 0 22px; color: var(--ink); }
.auth-card form { display: flex; flex-direction: column; gap: 14px; }
.auth-card label { font-size: 13px; font-weight: 700; color: var(--ink-soft); display: flex; flex-direction: column; gap: 6px; }
.auth-card input {
  padding: 10px 12px; border: 1px solid var(--line); border-radius: 9px; font-size: 14px;
  background: rgba(255,255,255,0.03); color: var(--ink);
}
.auth-card input:focus { border-color: var(--brand-2); }
.auth-error { color: var(--danger); font-size: 13px; font-weight: 600; }
.auth-switch { text-align: center; margin-top: 18px; font-size: 13px; color: var(--ink-soft); }
.auth-switch a { color: var(--brand-2); font-weight: 700; text-decoration: none; }

/* Landing page — all selectors are "landing-"-prefixed so nothing here can
   collide with (or be overridden by) the app-wide .btn/.logo/.header-actions
   etc. rules used on the authenticated side of the app. */
.landing-page { min-height: 100vh; line-height: 1.55; color: var(--ink); }
.landing-page * { box-sizing: border-box; }
.landing-page img, .landing-page svg { display: block; }
.landing-wrap { max-width: 1160px; margin: 0 auto; padding: 0 24px; }

.landing-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  padding: 11px 20px; border-radius: 999px; font-weight: 700; font-size: 14.5px;
  text-decoration: none; border: 1px solid transparent; cursor: pointer; transition: all .15s ease;
}
.landing-btn-primary { background: var(--gradient); color: var(--white); box-shadow: 0 6px 24px rgba(124,92,255,0.4); }
.landing-btn-primary:hover { transform: translateY(-1px); box-shadow: 0 10px 32px rgba(124,92,255,0.55); }
.landing-btn-ghost { color: var(--ink); border-color: var(--line); background: rgba(255,255,255,0.04); backdrop-filter: blur(8px); }
.landing-btn-ghost:hover { border-color: var(--brand-2); color: var(--brand-2); }
.landing-btn-lg { padding: 15px 26px; font-size: 15.5px; }

/* Nav */
.landing-nav-bar {
  position: sticky; top: 0; z-index: 50;
  background: rgba(5,6,12,0.7); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
  border-bottom: 1px solid var(--line);
}
.landing-nav { display: flex; align-items: center; justify-content: space-between; height: 72px; }
.landing-logo { display: flex; align-items: center; gap: 10px; font-family: var(--font-display); font-weight: 700; font-size: 20px; letter-spacing: -0.02em; color: var(--ink); }
.landing-logo-sm { font-size: 16px; }
.landing-nav-links { display: flex; gap: 28px; font-size: 14.5px; font-weight: 600; color: var(--ink-soft); }
.landing-nav-links a { text-decoration: none; color: inherit; }
.landing-nav-links a:hover { color: var(--brand-2); }
.landing-nav-cta { display: flex; gap: 12px; align-items: center; }
@media (max-width: 860px) { .landing-nav-links { display: none; } }

/* Hero */
.landing-hero { padding: 96px 0 72px; position: relative; overflow: hidden; }
.landing-eyebrow {
  display: inline-flex; align-items: center; gap: 8px;
  background: var(--brand-light); color: var(--brand-2); border: 1px solid rgba(124,92,255,0.3);
  font-size: 13px; font-weight: 700; padding: 7px 14px; border-radius: 999px; margin-bottom: 22px;
}
.landing-hero h1 {
  font-family: var(--font-display); font-size: clamp(36px, 5.2vw, 60px); line-height: 1.06; letter-spacing: -0.03em;
  margin: 0 0 22px; max-width: 820px; font-weight: 700; color: var(--ink);
}
.landing-hero h1 span { background: var(--gradient); -webkit-background-clip: text; background-clip: text; color: transparent; }
.landing-lead { font-size: 19px; color: var(--ink-soft); max-width: 620px; margin: 0 0 34px; }
.landing-hero-ctas { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 18px; }
.landing-hero-note { font-size: 13.5px; color: var(--ink-faint); }

.landing-map-preview {
  margin-top: 64px; border-radius: 20px; border: 1px solid var(--line);
  background: var(--glass); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px);
  box-shadow: 0 30px 80px rgba(0,0,0,0.55), 0 0 60px rgba(124,92,255,0.08); overflow: hidden;
}
.landing-preview-bar { display: flex; align-items: center; gap: 8px; padding: 14px 18px; border-bottom: 1px solid var(--line); }
.landing-dot { width: 10px; height: 10px; border-radius: 50%; }
.landing-map-canvas { height: 380px; position: relative; background: linear-gradient(180deg, #10132a 0%, #171b3a 100%); }
.landing-map-canvas svg { width: 100%; height: 100%; }
.landing-layer-panel {
  position: absolute; top: 18px; left: 18px; width: 200px; background: rgba(13,15,28,0.92);
  border: 1px solid var(--line); border-radius: 12px; padding: 14px; box-shadow: 0 14px 34px rgba(0,0,0,0.5); font-size: 12.5px;
}
.landing-layer-panel h4 { margin: 0 0 10px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-soft); }
.landing-layer-row { display: flex; align-items: center; gap: 8px; padding: 6px 0; color: var(--ink); font-weight: 600; }
.landing-swatch { width: 10px; height: 10px; border-radius: 3px; flex-shrink: 0; }
.landing-popup-card {
  position: absolute; bottom: 24px; right: 28px; width: 200px; background: rgba(13,15,28,0.92);
  border-radius: 12px; box-shadow: 0 14px 34px rgba(0,0,0,0.5); border: 1px solid var(--line); padding: 14px; font-size: 12.5px;
}
.landing-popup-t { font-weight: 800; margin-bottom: 4px; color: var(--ink); }
.landing-popup-m { color: var(--ink-soft); }

/* Sections */
.landing-page section { padding: 88px 0; }
.landing-section-head { max-width: 640px; margin: 0 auto 52px; text-align: center; }
.landing-kicker { color: var(--brand-2); font-weight: 800; font-size: 13px; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 12px; }
.landing-section-head h2 { font-family: var(--font-display); font-size: clamp(28px, 3.6vw, 40px); letter-spacing: -0.02em; margin: 0 0 14px; font-weight: 700; color: var(--ink); }
.landing-section-head p { color: var(--ink-soft); font-size: 17px; margin: 0; }

/* Feature grid */
.landing-features-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 22px; }
@media (max-width: 920px) { .landing-features-grid { grid-template-columns: repeat(2,1fr); } }
@media (max-width: 620px) { .landing-features-grid { grid-template-columns: 1fr; } }
.landing-feature-card {
  background: var(--glass); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
  border: 1px solid var(--line); border-radius: 16px;
  padding: 26px; transition: transform .15s ease, box-shadow .15s ease, border-color .15s ease;
}
.landing-feature-card:hover { transform: translateY(-3px); box-shadow: 0 16px 40px rgba(124,92,255,0.18); border-color: rgba(124,92,255,0.35); }
.landing-feature-card h3 { margin: 0 0 8px; font-size: 18px; font-weight: 800; letter-spacing: -0.01em; color: var(--ink); }
.landing-feature-card p { margin: 0; color: var(--ink-soft); font-size: 14.5px; }
.landing-feature-wide { grid-column: 1 / -1; }
.landing-feature-wide-inner { display: flex; gap: 24px; align-items: center; flex-wrap: wrap; }
.landing-feature-wide-tags { flex: 1; min-width: 240px; text-align: right; color: var(--brand-2); font-size: 14px; font-weight: 700; }

/* Personas */
.landing-personas { background: linear-gradient(180deg, rgba(124,92,255,0.08), rgba(34,211,238,0.04)); border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
.landing-personas .landing-section-head h2 { color: var(--ink); }
.landing-personas .landing-kicker { color: var(--brand-2); }
.landing-personas .landing-section-head p { color: var(--ink-soft); }
.landing-persona-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; }
@media (max-width: 920px) { .landing-persona-grid { grid-template-columns: repeat(2,1fr); } }
@media (max-width: 560px) { .landing-persona-grid { grid-template-columns: 1fr; } }
.landing-persona-card { background: rgba(255,255,255,0.04); border: 1px solid var(--line); border-radius: 14px; padding: 24px; transition: border-color .15s ease, transform .15s ease; }
.landing-persona-card:hover { border-color: rgba(124,92,255,0.4); transform: translateY(-2px); }
.landing-persona-card h3 { margin: 0 0 8px; font-size: 16.5px; font-weight: 800; color: var(--ink); }
.landing-persona-card p { margin: 0; color: var(--ink-soft); font-size: 13.5px; }

/* Workflow */
.landing-workflow-steps { display: grid; grid-template-columns: repeat(4, 1fr); gap: 22px; }
@media (max-width: 920px) { .landing-workflow-steps { grid-template-columns: repeat(2,1fr); } }
@media (max-width: 560px) { .landing-workflow-steps { grid-template-columns: 1fr; } }
.landing-step-num {
  width: 34px; height: 34px; border-radius: 50%; background: var(--gradient); color: var(--white);
  display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 14px; margin-bottom: 16px;
  box-shadow: 0 6px 18px rgba(124,92,255,0.35);
}
.landing-step h3 { margin: 0 0 8px; font-size: 16px; font-weight: 800; color: var(--ink); }
.landing-step p { margin: 0; color: var(--ink-soft); font-size: 14px; }

/* Stat band */
.landing-stats { border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
.landing-stats-grid { display: grid; grid-template-columns: repeat(4,1fr); gap: 24px; padding: 44px 24px; }
@media (max-width: 760px) { .landing-stats-grid { grid-template-columns: repeat(2,1fr); } }
.landing-stat { text-align: center; }
.landing-stat-n { font-family: var(--font-display); font-size: 34px; font-weight: 700; background: var(--gradient); -webkit-background-clip: text; background-clip: text; color: transparent; letter-spacing: -0.02em; }
.landing-stat-l { font-size: 13px; color: var(--ink-soft); margin-top: 4px; }

/* CTA band */
.landing-cta-band {
  background: var(--gradient); color: var(--white); border-radius: 28px; margin: 0 24px; padding: 64px 40px; text-align: center;
  box-shadow: 0 40px 90px rgba(124,92,255,0.35);
}
.landing-cta-band h2 { font-family: var(--font-display); font-size: clamp(26px,3.4vw,36px); margin: 0 0 14px; font-weight: 700; letter-spacing: -0.02em; }
.landing-cta-band p { color: rgba(255,255,255,0.85); margin: 0 0 30px; font-size: 16px; }

/* Footer */
.landing-footer { padding: 48px 0 32px; }
.landing-foot-grid { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 20px; border-top: 1px solid var(--line); padding-top: 28px; }
.landing-foot-links { display: flex; gap: 22px; font-size: 13.5px; color: var(--ink-soft); flex-wrap: wrap; }
.landing-foot-links a { text-decoration: none; color: inherit; }
.landing-foot-links a:hover { color: var(--brand-2); }
.landing-foot-note { font-size: 13px; color: var(--ink-faint); }
.landing-foot-note a { color: var(--brand-2); font-weight: 700; text-decoration: none; }
.landing-foot-note a:hover { text-decoration: underline; }
.landing-credits { margin-top: 14px; font-size: 12px; color: var(--ink-faint); line-height: 1.6; }
.landing-credits a { color: inherit; text-decoration: underline; text-decoration-color: rgba(154,163,199,0.4); }
.landing-credits a:hover { color: var(--brand-2); text-decoration-color: var(--brand-2); }

/* Maps list */
.maps-list-body { max-width: 1000px; margin: 0 auto; padding: 32px 24px; }
.maps-list-top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
.maps-list-top h1 { font-family: var(--font-display); color: var(--ink); }
.new-map-form { display: flex; gap: 10px; margin-bottom: 20px; }
.new-map-form input {
  flex: 1; padding: 10px 12px; border: 1px solid var(--line); border-radius: 9px;
  background: rgba(255,255,255,0.03); color: var(--ink);
}
.new-map-form input:focus { border-color: var(--brand-2); }
.maps-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; }
.map-card {
  background: var(--glass); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
  border: 1px solid var(--line); border-radius: 14px; padding: 20px; cursor: pointer;
  transition: border-color .15s ease, box-shadow .15s ease, transform .15s ease;
}
.map-card:hover { border-color: rgba(124,92,255,0.4); box-shadow: 0 16px 40px rgba(124,92,255,0.18); transform: translateY(-2px); }
.map-card-thumb { font-size: 30px; margin-bottom: 10px; }
.map-card-name { font-weight: 700; margin-bottom: 4px; color: var(--ink); }
.map-card-meta { font-size: 12px; color: var(--ink-soft); text-transform: capitalize; }
.empty-state { color: var(--ink-soft); padding: 40px 0; text-align: center; }
.muted { color: var(--ink-soft); font-size: 13px; }
.muted-sm { color: var(--ink-soft); font-size: 12.5px; line-height: 1.5; }

/* Editor layout */
.editor-page { height: 100vh; display: flex; flex-direction: column; }
.app { flex: 1; display: flex; min-height: 0; }
.sidebar {
  width: 290px; flex-shrink: 0; border-right: 1px solid var(--line); overflow-y: auto;
  background: var(--glass); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
}
.sidebar-section { padding: 16px; border-bottom: 1px solid var(--line); }
.sidebar-section h4 { margin: 0 0 10px; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--ink-soft); font-weight: 800; }
.layer-item { display: flex; align-items: center; gap: 8px; padding: 8px; border-radius: 8px; cursor: pointer; font-size: 13px; transition: background .12s ease; }
.layer-item:hover { background: var(--brand-light); }
.layer-item.active { background: var(--brand-light); box-shadow: inset 0 0 0 1px var(--brand); }
.layer-item .swatch { width: 11px; height: 11px; border-radius: 3px; flex-shrink: 0; }
.layer-item .name { flex: 1; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--ink); }
.layer-item .del { opacity: 0; border: none; background: none; color: var(--danger); font-weight: 800; padding: 0 4px; }
.layer-item:hover .del { opacity: 1; }
.layer-item .dl { opacity: 0; border: none; background: none; color: var(--ink-soft); font-weight: 800; padding: 0 4px; font-size: 12px; }
.layer-item:hover .dl { opacity: 1; }
.layer-item .dl:hover { color: var(--brand); }
.empty-note { font-size: 12.5px; color: var(--ink-soft); padding: 6px 2px; line-height: 1.5; }
.banner-error { background: var(--danger-bg); color: #ff8fa4; padding: 8px 18px; font-size: 13px; font-weight: 600; border-bottom: 1px solid rgba(255,92,122,0.25); }
.banner-notice {
  background: var(--brand-light); color: var(--brand-2); padding: 8px 18px; font-size: 13px; font-weight: 600;
  display: flex; justify-content: space-between; align-items: center; gap: 12px; border-bottom: 1px solid rgba(124,92,255,0.25);
}
.banner-notice button { border: none; background: none; color: var(--brand-2); font-weight: 800; cursor: pointer; }

.field-row { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; font-size: 12.5px; gap: 10px; }
.field-row label { color: var(--ink-soft); font-weight: 600; flex-shrink: 0; }
.field-row input[type=range] { flex: 1; accent-color: var(--brand); }
.field-row input[type=color] { width: 32px; height: 26px; border: 1px solid var(--line); border-radius: 6px; padding: 0; background: transparent; }
.field-val { width: 34px; text-align: right; color: var(--ink-soft); }
.popup-fields label { display: flex; align-items: center; gap: 7px; font-size: 12.5px; padding: 4px 0; font-weight: 600; color: var(--ink); }

.map-wrap { flex: 1; position: relative; }
.map-canvas-el { width: 100%; height: 100%; }
.shared-map-wrap { height: calc(100vh - 56px); }

.map-popup { position: absolute; inset: 0; }
.popup-card-inline {
  position: absolute; top: 20px; right: 20px; background: var(--glass); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
  border: 1px solid var(--line); border-radius: 12px;
  box-shadow: 0 20px 50px rgba(0,0,0,0.5); padding: 12px 14px; font-size: 12.5px; min-width: 180px; max-width: 260px;
}
.popup-card-inline .pt { font-weight: 800; margin-bottom: 6px; color: var(--brand-2); display: flex; justify-content: space-between; gap: 8px; }
.popup-card-inline .pt button { border: none; background: none; color: var(--ink-soft); font-weight: 800; cursor: pointer; }
.popup-card-inline .prow { display: flex; justify-content: space-between; gap: 10px; padding: 2px 0; color: var(--ink-soft); }
.popup-card-inline .prow b { color: var(--ink); font-weight: 700; }

/* Bottom panel */
.bottom-panel {
  height: 270px; flex-shrink: 0; border-top: 1px solid var(--line); display: flex; flex-direction: column;
  background: var(--glass); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
}
.bottom-tabs { display: flex; gap: 2px; padding: 8px 14px 0; border-bottom: 1px solid var(--line); }
.bottom-tabs button { padding: 9px 14px; border: none; background: none; font-weight: 700; font-size: 12.5px; color: var(--ink-soft); border-bottom: 2px solid transparent; margin-bottom: -1px; }
.bottom-tabs button.active { color: var(--brand-2); border-bottom-color: var(--brand-2); }
.bottom-content { flex: 1; overflow: auto; padding: 14px 18px; }

table.datatable { border-collapse: collapse; font-size: 12.5px; width: 100%; color: var(--ink); }
table.datatable th { position: sticky; top: 0; background: var(--surface-2); text-align: left; padding: 7px 10px; color: var(--brand-2); font-weight: 800; border-bottom: 1px solid var(--line); }
table.datatable td { padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.06); white-space: nowrap; }

.dash-controls { display: flex; gap: 16px; align-items: center; margin-bottom: 14px; }
.dash-controls .fg { display: flex; flex-direction: column; gap: 4px; }
.dash-controls label { font-size: 11px; font-weight: 800; color: var(--ink-soft); text-transform: uppercase; }
.dash-controls select { padding: 7px 10px; border: 1px solid var(--line); border-radius: 8px; font-size: 13px; min-width: 150px; background: rgba(255,255,255,0.03); color: var(--ink); }
.bar-row { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; height: 24px; }
.bar-label { width: 120px; flex-shrink: 0; font-size: 12px; color: var(--ink-soft); text-align: right; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-weight: 600; }
.bar-track { flex: 1; position: relative; height: 24px; background: rgba(255,255,255,0.04); border-radius: 5px; }
.bar-fill { height: 22px; border-radius: 5px; background: var(--gradient); position: relative; display: flex; align-items: center; box-shadow: 0 0 16px rgba(124,92,255,0.35); }
.bar-val { position: absolute; left: calc(100% + 8px); font-size: 12px; font-weight: 800; color: var(--ink); }

.analysis-box { max-width: 420px; }
.analysis-box h4 { margin: 0 0 4px; font-size: 13px; color: var(--ink); }
.analysis-row { display: flex; gap: 10px; align-items: center; margin: 10px 0; }
.analysis-row input[type=number], .analysis-row select {
  padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; font-size: 13px;
  background: rgba(255,255,255,0.03); color: var(--ink);
}

/* Share modal */
.modal-backdrop { position: fixed; inset: 0; background: rgba(2,3,8,.72); backdrop-filter: blur(4px); display: flex; align-items: center; justify-content: center; z-index: 50; }
.modal {
  background: var(--surface-2); border: 1px solid var(--line); border-radius: 16px; padding: 26px; width: 420px;
  box-shadow: 0 40px 90px rgba(0,0,0,0.6), 0 0 0 1px rgba(124,92,255,0.08);
}
.modal h3 { font-family: var(--font-display); color: var(--ink); margin-top: 0; }
.share-options { display: flex; gap: 8px; margin: 16px 0; }
.share-options button { text-transform: capitalize; flex: 1; }
.share-link { display: flex; gap: 8px; align-items: center; background: rgba(255,255,255,0.04); border: 1px solid var(--line); border-radius: 9px; padding: 8px 10px; }
.share-link code { flex: 1; font-size: 12px; overflow-x: auto; white-space: nowrap; color: var(--brand-2); }

/* Print map (PDF export) — on screen this is a full-page preview styled to
   match the app's dark theme; the @media print block hides everything but
   .print-sheet. IMPORTANT: .print-sheet and its descendants deliberately use
   hardcoded light colors, NOT the --ink/--line/--surface vars above — those
   vars mean "dark theme" everywhere else in this file, but the print sheet
   is a page of paper and must stay white with dark text regardless of the
   app's theme (var(--white) is still literally #fff, so that one is safe to
   keep from the shared palette). */
.print-modal-backdrop { position: fixed; inset: 0; z-index: 60; background: var(--bg); overflow: auto; }
.print-toolbar {
  position: sticky; top: 0; z-index: 2; display: flex; justify-content: space-between; align-items: center;
  padding: 12px 20px; background: var(--glass); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
  border-bottom: 1px solid var(--line); box-shadow: 0 2px 20px rgba(0,0,0,0.4);
}
.print-toolbar-title { font-size: 13px; font-weight: 700; color: var(--ink-soft); }
.print-toolbar-actions { display: flex; gap: 10px; }

.print-sheet {
  width: 1000px; max-width: calc(100% - 48px); margin: 28px auto; background: var(--white);
  border: 2px solid #171a2e; border-radius: 4px; padding: 22px; box-shadow: 0 30px 80px rgba(0,0,0,0.55);
}
.print-sheet-header { margin-bottom: 14px; }
.print-sheet-header h1 { margin: 0 0 4px; font-size: 24px; font-weight: 800; letter-spacing: -0.01em; color: #171a2e; font-family: var(--font-display); }
.print-sheet-header p { margin: 0; font-size: 13.5px; color: #5b6280; }

.print-map-frame { position: relative; height: 560px; border: 1px solid #dfe3ee; overflow: hidden; }
.print-map-frame .map-canvas-el { width: 100%; height: 100%; }

.print-north-arrow { position: absolute; top: 14px; right: 14px; background: rgba(255,255,255,.9); border: 1px solid #dfe3ee; border-radius: 6px; padding: 3px; }

.print-scalebar { position: absolute; left: 14px; bottom: 14px; background: rgba(255,255,255,.92); border: 1px solid #dfe3ee; padding: 6px 10px; border-radius: 6px; }
.print-scalebar-bar { height: 5px; background: #171a2e; border: 1px solid #171a2e; }
.print-scalebar-label { margin-top: 3px; font-size: 11px; font-weight: 700; color: #171a2e; text-align: center; }

.print-legend {
  position: absolute; top: 14px; left: 14px; max-width: 220px; max-height: calc(100% - 28px); overflow-y: auto;
  background: rgba(255,255,255,.96); border: 1px solid #dfe3ee; border-radius: 8px; padding: 10px 12px;
}
.print-legend h4 { margin: 0 0 8px; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #5b6280; font-weight: 800; }
.print-legend-row { display: flex; align-items: center; gap: 8px; padding: 3px 0; font-size: 12px; color: #171a2e; }
.print-legend-swatch { width: 11px; height: 11px; border-radius: 3px; flex-shrink: 0; }
.print-legend-swatch-raster { display: inline-flex; align-items: center; justify-content: center; font-size: 10px; width: 14px; height: 14px; margin: -1.5px 0; }

.print-sheet-footer { display: flex; justify-content: space-between; align-items: flex-end; gap: 20px; margin-top: 16px; padding-top: 14px; border-top: 1px solid #dfe3ee; }
.print-credits { font-size: 11.5px; color: #5b6280; line-height: 1.7; }
.print-qr { display: flex; flex-direction: column; align-items: center; gap: 4px; font-size: 10.5px; color: #5b6280; font-weight: 700; text-align: center; flex-shrink: 0; }
.print-qr img { border: 1px solid #dfe3ee; border-radius: 4px; }
.print-qr-note { max-width: 130px; font-weight: 600; }

@media print {
  @page { size: landscape; margin: 10mm; }
  body * { visibility: hidden; }
  .print-modal-backdrop, .print-modal-backdrop * { visibility: visible; }
  .print-modal-backdrop { position: absolute; inset: 0; background: var(--white); overflow: visible; }
  .print-toolbar { display: none; }
  .print-sheet { width: 100%; max-width: none; margin: 0; box-shadow: none; border-width: 1.5px; }
}

/* Raster/service layer indicator in the layer list */
.swatch-raster { width: 16px; height: 16px; margin: -2.5px 0; display: inline-flex; align-items: center; justify-content: center; font-size: 11px; line-height: 1; }

/* Add Data modal */
.add-data-modal { width: 480px; max-height: 82vh; display: flex; flex-direction: column; }
.add-data-groups { overflow-y: auto; margin-top: 6px; padding-right: 4px; }
.add-data-group { margin-bottom: 18px; }
.add-data-group h4 { margin: 0 0 8px; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--ink-soft); font-weight: 800; }
.add-data-item {
  display: flex; align-items: center; gap: 10px; padding: 8px 4px; border-bottom: 1px solid var(--line); font-size: 13px;
  flex-wrap: wrap;
}
.add-data-item:last-child { border-bottom: none; }
.add-data-name { flex: 1; font-weight: 600; color: var(--ink); }
.add-data-added { font-size: 12px; font-weight: 700; color: var(--brand-2); }
.add-data-error { flex-basis: 100%; color: var(--danger); font-size: 12px; font-weight: 600; margin-top: 4px; }

.type-badge {
  font-size: 10px; font-weight: 800; letter-spacing: .03em; padding: 3px 7px; border-radius: 5px;
  color: var(--white); flex-shrink: 0; width: 54px; text-align: center;
}
.type-xyz { background: #4d7ff2; }
.type-wms { background: #26c98a; }
.type-wmts { background: #f0973f; }
.type-wfs { background: #b46bf0; }
.type-arcgis { background: #f0616b; }
.type-geojson { background: #22d3ee; }
EOF

echo "Writing apps/web/src/types/geotiff.d.ts ..."
mkdir -p apps/web/src/types
cat > apps/web/src/types/geotiff.d.ts <<'EOF'
// Minimal ambient shim for the `geotiff` npm package.
//
// This project only uses `geotiff` for one thing — encoding a georeferenced
// raster to a GeoTIFF entirely client-side, see lib/downloadLayer.ts. We
// couldn't confirm at write-time whether the installed version of `geotiff`
// ships its own TypeScript declarations, or whether `writeArrayBuffer`'s
// real signature matches this shim exactly (no network access to inspect
// the package). Declaring it here — loosely, with `unknown`/`any` — means
// the web build can't fail because of a type mismatch with the *real*
// package; if the shim is wrong, the failure shows up at runtime instead
// (caught by the try/catch around downloadRasterLayer's caller), not as a
// build break blocking every other feature in this delivery.
//
// If TypeScript reports "Duplicate identifier" or similar here once you
// build, it means `geotiff` DOES ship its own types and this file can just
// be deleted.
declare module "geotiff" {
  export function writeArrayBuffer(values: unknown, metadata: Record<string, unknown>): Promise<ArrayBuffer>;
}
EOF

echo "Writing apps/web/src/lib/downloadLayer.ts ..."
cat > apps/web/src/lib/downloadLayer.ts <<'EOF'
import { writeArrayBuffer } from "geotiff";
import { GeoFeatureCollection, LayerDto } from "../api/client";

// Triggers a browser download of an in-memory Blob — shared by both the
// vector (GeoJSON) and raster (GeoTIFF) download paths below.
function downloadBlob(filename: string, blob: Blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Give the browser a moment to start the download before freeing the URL.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function safeFilename(name: string) {
  const cleaned = name.replace(/[^a-z0-9\-_. ]/gi, "_").trim();
  return cleaned || "layer";
}

// Vector layers (uploads, buffer/intersect results, Contours, Watershed, ...)
// already have their full feature set loaded client-side in featuresByLayer
// (see MapEditorPage's loadMap, which fetches every non-raster layer's
// features up front) — no server round-trip needed here, just package what's
// already in memory as a standalone .geojson file.
export function downloadVectorLayer(layer: LayerDto, features: GeoFeatureCollection) {
  const blob = new Blob([JSON.stringify(features, null, 2)], { type: "application/geo+json" });
  downloadBlob(`${safeFilename(layer.name)}.geojson`, blob);
}

// Raster layers produced by the terrain tools (Hillshade/Slope/Aspect) are
// stored as a single georeferenced PNG — a data: URL already sitting in
// layer.service.url, with the four corner coordinates in
// layer.service.coordinates (see colorizeSequential/colorizeAspect and
// imageLayerService() in apps/api/src/lib/terrain.ts). To hand the user
// something a GIS tool can position correctly with no separate "bounds"
// file, this decodes that PNG via <canvas> and re-encodes it as a GeoTIFF
// with the same bounds embedded, entirely in the browser — no backend
// changes, no server-side image library, no Docker/binary dependency.
//
// NOTE: this is the least battle-tested part of this feature. We could not
// verify the exact runtime shape `geotiff`'s writeArrayBuffer expects (see
// types/geotiff.d.ts) without network access to inspect the package, so
// this is a best-effort implementation based on the documented GeoTIFF/TIFF
// tag names. If a downloaded .tif won't open, or opens with the wrong
// position/CRS, in QGIS or another GIS tool, that's the first place to look.
// Tile-service raster layers (XYZ/WMS/WMTS basemap layers, added via "Add
// data" rather than generated by a terrain tool) are NOT covered — they're
// a live service, not a single fixed image, so there's nothing to export.
export async function downloadRasterLayer(layer: LayerDto) {
  const service = layer.service;
  if (!service || service.type !== "image" || !service.url || !service.coordinates || service.coordinates.length < 4) {
    throw new Error("This layer isn't a downloadable image (it's a live tile service, not a single georeferenced raster).");
  }

  const img = new Image();
  img.src = service.url;
  await new Promise<void>((resolve, reject) => {
    img.onload = () => resolve();
    img.onerror = () => reject(new Error("Couldn't decode this layer's image data."));
  });

  const canvas = document.createElement("canvas");
  canvas.width = img.naturalWidth;
  canvas.height = img.naturalHeight;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("This browser doesn't support the canvas APIs needed to export this layer.");
  ctx.drawImage(img, 0, 0);

  const { data, width, height } = ctx.getImageData(0, 0, canvas.width, canvas.height);
  if (!width || !height) throw new Error("This layer's image appears to be empty.");

  // De-interleave RGBA -> four separate band arrays. geotiff's reader
  // returns rasters this way (one typed array per band), so its writer is
  // expected to accept the same shape symmetrically.
  const pixelCount = width * height;
  const r = new Uint8Array(pixelCount);
  const g = new Uint8Array(pixelCount);
  const b = new Uint8Array(pixelCount);
  const a = new Uint8Array(pixelCount);
  for (let i = 0; i < pixelCount; i++) {
    r[i] = data[i * 4];
    g[i] = data[i * 4 + 1];
    b[i] = data[i * 4 + 2];
    a[i] = data[i * 4 + 3];
  }

  // coordinates is [[west,north],[east,north],[east,south],[west,south]] —
  // see imageLayerService() in apps/api/src/lib/terrain.ts. NoData pixels
  // (areas the DEM didn't cover) come through with alpha = 0 in this 4th
  // band, same convention the app already uses to render them transparent
  // on the map — if a GIS tool doesn't auto-treat band 4 as a mask/alpha
  // channel, that's a one-time "treat band 4 as alpha" setting to apply.
  const [west, north] = service.coordinates[0];
  const [east] = service.coordinates[1];
  const [, south] = service.coordinates[2];

  const arrayBuffer = await writeArrayBuffer([r, g, b, a], {
    height,
    width,
    ModelPixelScale: [(east - west) / width, (north - south) / height, 0],
    ModelTiepoint: [0, 0, 0, west, north, 0],
    GTModelTypeGeoKey: 2, // Geographic (lat/lon), not a projected CRS
    GTRasterTypeGeoKey: 1, // RasterPixelIsArea
    GeographicTypeGeoKey: 4326, // WGS84 — matches the DEM source, see fetchDem() in terrain.ts
  });

  downloadBlob(`${safeFilename(layer.name)}.tif`, new Blob([arrayBuffer], { type: "image/tiff" }));
}
EOF

echo "Writing apps/web/src/components/LayerList.tsx ..."
cat > apps/web/src/components/LayerList.tsx <<'EOF'
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
EOF

echo "Writing apps/web/src/pages/MapEditorPage.tsx ..."
cat > apps/web/src/pages/MapEditorPage.tsx <<'EOF'
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { api, Bbox, GeoFeature, GeoFeatureCollection, LayerDto, MapDto, MapVisibility } from "../api/client";
import MapCanvas from "../components/MapCanvas";
import LayerList from "../components/LayerList";
import StylePanel from "../components/StylePanel";
import PopupConfigPanel from "../components/PopupConfigPanel";
import UploadButton from "../components/UploadButton";
import DataTable from "../components/DataTable";
import DashboardChart from "../components/DashboardChart";
import AnalysisPanel from "../components/AnalysisPanel";
import TerrainPanel from "../components/TerrainPanel";
import AddDataPanel from "../components/AddDataPanel";
import PrintMapModal from "../components/PrintMapModal";
import { CatalogEntry } from "../lib/serviceCatalog";
import { downloadRasterLayer, downloadVectorLayer } from "../lib/downloadLayer";

type BottomTab = "table" | "dashboard" | "analysis" | "terrain";

export default function MapEditorPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [map, setMap] = useState<MapDto | null>(null);
  const [role, setRole] = useState<string>("viewer");
  const [layers, setLayers] = useState<LayerDto[]>([]);
  const [featuresByLayer, setFeaturesByLayer] = useState<Record<string, GeoFeatureCollection>>({});
  const [visibleIds, setVisibleIds] = useState<Set<string>>(new Set());
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [tab, setTab] = useState<BottomTab>("table");
  const [bounds, setBounds] = useState<Bbox | null>(null);
  const [pourPoint, setPourPoint] = useState<{ lon: number; lat: number } | null>(null);
  const [pickingPourPoint, setPickingPourPoint] = useState(false);
  const [popup, setPopup] = useState<{ layer: LayerDto; feature: GeoFeature; lngLat: [number, number] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [shareOpen, setShareOpen] = useState(false);
  const [printOpen, setPrintOpen] = useState(false);
  const [addDataOpen, setAddDataOpen] = useState(false);

  const canEdit = role === "owner" || role === "editor";

  const loadMap = useCallback(async () => {
    if (!id) return;
    try {
      const { map, layers, role } = await api.getMap(id);
      setMap(map);
      setLayers(layers);
      setRole(role);
      setVisibleIds(new Set(layers.map((l) => l.id)));
      if (!selectedId && layers.length) setSelectedId(layers[0].id);
      // Fetch features for every vector layer (fine for MVP-scale datasets).
      // Raster (service) layers render straight from their tile URL — they
      // have no rows in `features`, so there's nothing to fetch for them.
      const entries = await Promise.all(
        layers.filter((l) => l.kind !== "raster").map(async (l) => [l.id, await api.getLayerFeatures(l.id)] as const)
      );
      setFeaturesByLayer(Object.fromEntries(entries));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Couldn't load this map.");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  useEffect(() => {
    loadMap();
  }, [loadMap]);

  const selectedLayer = layers.find((l) => l.id === selectedId) || null;
  const visibleLayers = layers.filter((l) => visibleIds.has(l.id));

  async function handleUpload(file: File) {
    if (!id) return;
    setError(null);
    setNotice(null);
    try {
      const { featureCount, skipped, warning } = await api.uploadLayer(id, file);
      await loadMap();
      const notes: string[] = [`Loaded ${featureCount} feature${featureCount === 1 ? "" : "s"}.`];
      if (skipped) notes.push(`${skipped} row${skipped === 1 ? "" : "s"} skipped (unsupported or invalid geometry).`);
      if (warning) notes.push(warning);
      setNotice(notes.join(" "));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Upload failed.");
    }
  }

  // Called by AddDataPanel per-item; errors are intentionally left to
  // propagate so the panel can show them inline next to the item that failed
  // rather than as a page-level banner.
  async function handleAddService(entry: CatalogEntry) {
    if (!id) return;
    setError(null);
    const { featureCount, skipped } = await api.addServiceLayer(id, {
      name: entry.name,
      serviceType: entry.serviceType,
      fields: entry.fields,
    });
    await loadMap();
    if (entry.serviceType === "wfs" || entry.serviceType === "arcgis" || entry.serviceType === "geojson") {
      const notes = [`Added "${entry.name}" — imported ${featureCount} feature${featureCount === 1 ? "" : "s"}.`];
      if (skipped) notes.push(`${skipped} skipped (unsupported or invalid geometry).`);
      setNotice(notes.join(" "));
    } else {
      setNotice(`Added "${entry.name}" as a basemap layer.`);
    }
  }

  async function handleStyleChange(style: Partial<LayerDto["style"]>) {
    if (!selectedLayer) return;
    const mergedStyle = { ...selectedLayer.style, ...style };
    const updated = { ...selectedLayer, style: mergedStyle };
    setLayers((prev) => prev.map((l) => (l.id === updated.id ? updated : l)));
    await api.updateLayer(selectedLayer.id, { style: mergedStyle });
  }

  async function handlePopupFieldsChange(fields: string[]) {
    if (!selectedLayer) return;
    setLayers((prev) => prev.map((l) => (l.id === selectedLayer.id ? { ...l, popup_fields: fields } : l)));
    await api.updateLayer(selectedLayer.id, { popup_fields: fields });
  }

  async function handleDeleteLayer(layerId: string) {
    await api.deleteLayer(layerId);
    if (selectedId === layerId) setSelectedId(null);
    await loadMap();
  }

  // Vector layers already have their full feature set in featuresByLayer
  // (fetched up front by loadMap), so that path is synchronous and can't
  // fail beyond "not loaded yet". Raster (image) layers re-encode the PNG
  // as a GeoTIFF in the browser (see lib/downloadLayer.ts) — that's the
  // least-proven part of this feature, so its errors are surfaced via the
  // same error banner as everything else rather than silently swallowed.
  function handleDownloadLayer(layerId: string) {
    const layer = layers.find((l) => l.id === layerId);
    if (!layer) return;
    setError(null);
    if (layer.kind === "raster") {
      downloadRasterLayer(layer).catch((err) =>
        setError(err instanceof Error ? err.message : "Couldn't download this layer.")
      );
    } else {
      const fc = featuresByLayer[layerId];
      if (!fc) {
        setError("This layer's features haven't finished loading yet — try again in a moment.");
        return;
      }
      downloadVectorLayer(layer, fc);
    }
  }

  async function handleShare(visibility: MapVisibility) {
    if (!id) return;
    const { map } = await api.shareMap(id, visibility);
    setMap(map);
  }

  function handleMapClick(lngLat: [number, number]) {
    if (!pickingPourPoint) return;
    setPourPoint({ lon: lngLat[0], lat: lngLat[1] });
    setPickingPourPoint(false);
  }

  const selectedFeatures = selectedLayer ? featuresByLayer[selectedLayer.id] || null : null;
  const allFields: string[] = Array.from(
    new Set((selectedFeatures?.features || []).flatMap((f) => Object.keys(f.properties || {})))
  );

  if (!map) {
    return <div className="page-loading">{error || "Loading map…"}</div>;
  }

  return (
    <div className="editor-page">
      <header className="app-header">
        <div className="logo" onClick={() => navigate("/maps")} style={{ cursor: "pointer" }}>
          GISNEXUS
        </div>
        <div className="map-title">{map.name}</div>
        <div className="header-actions">
          <UploadButton onUpload={handleUpload} />
          {canEdit && (
            <button className="btn" onClick={() => setAddDataOpen(true)}>
              🌐 Add data
            </button>
          )}
          {role === "owner" && (
            <button className="btn" onClick={() => setShareOpen(true)}>
              Share
            </button>
          )}
        </div>
      </header>

      {error && <div className="banner-error">{error}</div>}
      {notice && (
        <div className="banner-notice">
          {notice}
          <button onClick={() => setNotice(null)}>✕</button>
        </div>
      )}
      {pickingPourPoint && (
        <div className="banner-notice">
          Click anywhere on the map to set the watershed pour point.
          <button onClick={() => setPickingPourPoint(false)}>✕</button>
        </div>
      )}

      <div className="app">
        <aside className="sidebar">
          <div className="sidebar-section">
            <h4>Layers</h4>
            <LayerList
              layers={layers}
              visibleIds={visibleIds}
              selectedId={selectedId}
              canEdit={canEdit}
              onToggleVisible={(lid) =>
                setVisibleIds((prev) => {
                  const next = new Set(prev);
                  next.has(lid) ? next.delete(lid) : next.add(lid);
                  return next;
                })
              }
              onSelect={setSelectedId}
              onDelete={handleDeleteLayer}
              onDownload={handleDownloadLayer}
            />
          </div>
          {selectedLayer && canEdit && selectedLayer.kind === "raster" ? (
            <div className="sidebar-section">
              <h4>Layer — {selectedLayer.name}</h4>
              <div className="field-row">
                <label>Opacity</label>
                <input
                  type="range"
                  min={0.1}
                  max={1}
                  step={0.05}
                  value={selectedLayer.style.opacity}
                  onChange={(e) => handleStyleChange({ opacity: parseFloat(e.target.value) })}
                />
                <span className="field-val">{Math.round(selectedLayer.style.opacity * 100)}%</span>
              </div>
              {selectedLayer.service?.attribution && <p className="muted-sm">{selectedLayer.service.attribution}</p>}
            </div>
          ) : (
            selectedLayer &&
            canEdit && (
              <>
                <StylePanel layer={selectedLayer} onChange={handleStyleChange} />
                <PopupConfigPanel allFields={allFields} selectedFields={selectedLayer.popup_fields} onChange={handlePopupFieldsChange} />
              </>
            )
          )}
        </aside>

        <div className="map-wrap">
          <MapCanvas
            layers={visibleLayers}
            featuresByLayer={featuresByLayer}
            viewState={map.view_state}
            onViewStateChange={(v) => api.updateMap(map.id, { view_state: v }).catch(() => {})}
            onFeatureClick={(layer, feature, lngLat) => setPopup({ layer, feature, lngLat })}
            onBoundsChange={setBounds}
            onMapClick={handleMapClick}
            pickMarker={pourPoint ? [pourPoint.lon, pourPoint.lat] : null}
          />
          {popup && (
            <div className="map-popup" onClick={() => setPopup(null)}>
              <div className="popup-card-inline" onClick={(e) => e.stopPropagation()}>
                <div className="pt">
                  <span>{popup.layer.name}</span>
                  <button onClick={() => setPopup(null)}>✕</button>
                </div>
                {(popup.layer.popup_fields.length ? popup.layer.popup_fields : Object.keys(popup.feature.properties).slice(0, 4)).map(
                  (k) => (
                    <div className="prow" key={k}>
                      <span>{k}</span>
                      <b>{String(popup.feature.properties[k] ?? "—")}</b>
                    </div>
                  )
                )}
              </div>
            </div>
          )}
        </div>
      </div>

      <div className="bottom-panel">
        <div className="bottom-tabs">
          <button className={tab === "table" ? "active" : ""} onClick={() => setTab("table")}>
            Data table
          </button>
          <button className={tab === "dashboard" ? "active" : ""} onClick={() => setTab("dashboard")}>
            Dashboard
          </button>
          <button className={tab === "analysis" ? "active" : ""} onClick={() => setTab("analysis")}>
            Spatial analysis
          </button>
          <button className={tab === "terrain" ? "active" : ""} onClick={() => setTab("terrain")}>
            Terrain
          </button>
        </div>
        <div className="bottom-content">
          {tab === "terrain" ? (
            canEdit ? (
              <TerrainPanel
                mapId={id!}
                bounds={bounds}
                onCreated={loadMap}
                pourPoint={pourPoint}
                pickingPourPoint={pickingPourPoint}
                onStartPickPourPoint={() => setPickingPourPoint(true)}
                onClearPourPoint={() => {
                  setPourPoint(null);
                  setPickingPourPoint(false);
                }}
              />
            ) : (
              <div className="empty-note">You need edit access to run terrain analysis.</div>
            )
          ) : !selectedLayer ? (
            <div className="empty-note">Select a layer to get started.</div>
          ) : selectedLayer.kind === "raster" ? (
            <div className="empty-note">
              "{selectedLayer.name}" is a basemap/imagery layer — there's no feature data to show in the table,
              dashboard, or spatial analysis tools. Use the opacity slider in the sidebar to adjust it.
            </div>
          ) : tab === "table" ? (
            <DataTable data={selectedFeatures} />
          ) : tab === "dashboard" ? (
            <DashboardChart layer={selectedLayer} data={selectedFeatures} />
          ) : canEdit ? (
            <AnalysisPanel layer={selectedLayer} allLayers={layers.filter((l) => l.kind !== "raster")} onCreated={loadMap} />
          ) : (
            <div className="empty-note">You need edit access to run spatial analysis.</div>
          )}
        </div>
      </div>

      {shareOpen && (
        <div className="modal-backdrop" onClick={() => setShareOpen(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h3>Share "{map.name}"</h3>
            <p className="muted-sm">Anyone with the link can view this map if visibility is set to Unlisted or Public.</p>
            <div className="share-options">
              {(["private", "unlisted", "public"] as MapVisibility[]).map((v) => (
                <button key={v} className={"btn" + (map.visibility === v ? " btn-primary" : "")} onClick={() => handleShare(v)}>
                  {v}
                </button>
              ))}
            </div>
            {map.visibility !== "private" && map.share_token && (
              <div className="share-link">
                <code>{`${window.location.origin}/share/${map.share_token}`}</code>
                <button className="btn btn-sm" onClick={() => navigator.clipboard.writeText(`${window.location.origin}/share/${map.share_token}`)}>
                  Copy
                </button>
              </div>
            )}
            <button
              className="btn"
              style={{ marginTop: 16, width: "100%" }}
              onClick={() => {
                setShareOpen(false);
                setPrintOpen(true);
              }}
            >
              🖨️ Print map as PDF
            </button>
            <button className="btn" style={{ marginTop: 10 }} onClick={() => setShareOpen(false)}>
              Close
            </button>
          </div>
        </div>
      )}

      {printOpen && (
        <PrintMapModal
          map={map}
          layers={visibleLayers}
          featuresByLayer={featuresByLayer}
          shareUrl={map.visibility !== "private" && map.share_token ? `${window.location.origin}/share/${map.share_token}` : null}
          onClose={() => setPrintOpen(false)}
        />
      )}

      {addDataOpen && <AddDataPanel onAdd={handleAddService} onClose={() => setAddDataOpen(false)} />}
    </div>
  );
}
EOF

echo ""
echo "Done writing files. Now review, build, and push:"
echo ""
echo "  git status"
echo "  git diff --stat"
echo "  npm install --workspace=apps/web"
echo "  npm run build --workspace=apps/web"
echo "  git add -A"
echo "  git commit -m \"Add layer download: GeoJSON for vector, GeoTIFF for terrain raster outputs\""
echo "  git push"