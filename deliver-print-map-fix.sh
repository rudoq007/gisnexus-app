#!/usr/bin/env bash
# Fixes the print/export-to-PDF map: the map used to only fill part of the
# page width (and the zoom control buttons showed as blank boxes) in the
# actual printed PDF, even though the on-screen preview looked correct.
# Also adds an editable custom map title for the printed sheet.
#
# Run this from the root of your gisnexus-app checkout:
#   bash deliver-print-map-fix.sh
set -euo pipefail

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
.layer-item .zoom { opacity: 0; border: none; background: none; color: var(--ink-soft); font-weight: 800; padding: 0 4px; font-size: 13px; }
.layer-item:hover .zoom { opacity: 1; }
.layer-item .zoom:hover { color: var(--brand-2); }
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
.print-toolbar-actions { display: flex; gap: 10px; align-items: center; }

.print-title-field { display: flex; flex-direction: column; gap: 3px; font-size: 10.5px; font-weight: 700; color: var(--ink-soft); text-transform: uppercase; letter-spacing: .04em; }
.print-title-field input {
  font-size: 13px; font-weight: 600; text-transform: none; letter-spacing: normal; color: var(--ink);
  background: rgba(255,255,255,0.06); border: 1px solid var(--line); border-radius: 7px; padding: 6px 10px; min-width: 220px;
}
.print-title-field input:focus { outline: none; border-color: var(--brand-2); }

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
  /* Belt-and-suspenders: MapCanvas's printMode prop already skips adding
     MapLibre's NavigationControl/AttributionControl for the print map, but
     if that ever regresses, don't let a control with a print-unreliable
     icon silently reappear as a blank box in the PDF. */
  .print-map-frame .maplibregl-ctrl { display: none !important; }
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

echo "Writing apps/web/src/components/MapCanvas.tsx ..."
cat > apps/web/src/components/MapCanvas.tsx <<'EOF'
import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";
import maplibregl, { LngLatBoundsLike, Map as MapLibreMap, MapLayerMouseEvent, MapMouseEvent } from "maplibre-gl";
import { Bbox, GeoFeature, GeoFeatureCollection, LayerDto } from "../api/client";

// A free, no-API-key raster basemap. Swap for a vector style + MapTiler/Stadia
// key in production for sharper rendering — see README "Basemap tiles".
const BASEMAP_STYLE: maplibregl.StyleSpecification = {
  version: 8,
  sources: {
    osm: {
      type: "raster",
      tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      tileSize: 256,
      attribution: "&copy; OpenStreetMap contributors",
    },
  },
  layers: [{ id: "osm", type: "raster", source: "osm" }],
};

interface Props {
  layers: LayerDto[];
  featuresByLayer: Record<string, GeoFeatureCollection>;
  viewState: { center: [number, number]; zoom: number };
  onViewStateChange: (v: { center: [number, number]; zoom: number }) => void;
  onFeatureClick: (layer: LayerDto, feature: GeoFeature, lngLat: [number, number]) => void;
  // Current viewport bounds, reported on every move — the terrain tools
  // (Hillshade, ...) run against "whatever's on screen right now" rather
  // than a layer, so they need this and there's nowhere else to get it.
  onBoundsChange?: (bounds: { west: number; south: number; east: number; north: number }) => void;
  // Fires on every map click, regardless of whether it landed on a feature —
  // used by the Watershed tool's "pick a pour point" flow (see
  // TerrainPanel.tsx / MapEditorPage.tsx). Most of the time this is a no-op
  // in the parent; only meaningful while pour-point picking is active.
  onMapClick?: (lngLat: [number, number]) => void;
  // When set, shows a marker at this position — currently just the chosen
  // watershed pour point, so the user can see where they clicked.
  pickMarker?: [number, number] | null;
  // Set by PrintMapModal for the map instance embedded in the print sheet.
  // Interactive zoom/compass buttons and the default attribution bubble have
  // no purpose on a printed page (nothing to click, and the print sheet
  // already carries its own credits line) — and in testing, browsers'
  // print-to-PDF rasterizer intermittently drops these controls' background-
  // image icons, leaving blank boxes. Omitting them avoids both problems.
  printMode?: boolean;
}

// Imperative actions the parent (MapEditorPage) can trigger directly, for
// things that are one-off commands rather than state the map should keep
// reacting to — e.g. "zoom to this specific layer's extent" doesn't fit the
// usual prop-driven-by-state pattern (the same bounds could be requested
// twice in a row, which wouldn't re-trigger a useEffect keyed on that prop).
export interface MapCanvasHandle {
  fitToBounds: (bbox: Bbox) => void;
}

function sourceIdFor(layerId: string) {
  return `src-${layerId}`;
}
function fillLayerIdFor(layerId: string) {
  return `lyr-${layerId}-fill`;
}
function lineLayerIdFor(layerId: string) {
  return `lyr-${layerId}-line`;
}
function rasterLayerIdFor(layerId: string) {
  return `lyr-${layerId}-raster`;
}

const MapCanvas = forwardRef<MapCanvasHandle, Props>(function MapCanvas(
  { layers, featuresByLayer, viewState, onViewStateChange, onFeatureClick, onBoundsChange, onMapClick, pickMarker, printMode },
  ref
) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const loadedRef = useRef(false);
  const markerRef = useRef<maplibregl.Marker | null>(null);

  useImperativeHandle(ref, () => ({
    fitToBounds(bbox: Bbox) {
      const map = mapRef.current;
      if (!map) return;
      map.fitBounds(
        [
          [bbox.west, bbox.south],
          [bbox.east, bbox.north],
        ],
        { padding: 80, maxZoom: 18, duration: 600 }
      );
    },
  }));

  // The map-init effect below only runs once (empty deps), so it captures
  // whatever onMapClick was passed at mount time. Unlike onBoundsChange/
  // onFeatureClick (which just call stable setState functions), the pour-
  // point picker's onMapClick needs to see fresh "am I in picking mode right
  // now" state on every click — so it's read through a ref that's kept
  // current every render, rather than closed over directly.
  const onMapClickRef = useRef(onMapClick);
  onMapClickRef.current = onMapClick;

  function reportBounds(map: MapLibreMap) {
    if (!onBoundsChange) return;
    const b = map.getBounds();
    onBoundsChange({ west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth() });
  }

  // Initialize map once.
  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: BASEMAP_STYLE,
      center: viewState.center,
      zoom: viewState.zoom,
      // See the `printMode` comment on Props above — the print sheet builds
      // its own attribution/credits line from each layer's
      // service.attribution (PrintMapModal.tsx), so MapLibre's own
      // AttributionControl would just be a redundant, print-unreliable icon.
      attributionControl: !printMode,
    });
    if (!printMode) {
      map.addControl(new maplibregl.NavigationControl(), "bottom-left");
    }
    map.on("load", () => {
      loadedRef.current = true;
      syncLayers();
      reportBounds(map);
    });
    map.on("moveend", () => {
      const c = map.getCenter();
      onViewStateChange({ center: [c.lng, c.lat], zoom: map.getZoom() });
      reportBounds(map);
    });
    map.on("click", (e: MapMouseEvent) => {
      onMapClickRef.current?.([e.lngLat.lng, e.lngLat.lat]);
    });
    mapRef.current = map;

    // MapLibre resizes its canvas via a ResizeObserver on the container, and
    // that callback fires asynchronously. The browser's print pipeline
    // applies @media print layout (the print sheet snapping from its capped
    // on-screen width to the full page width) and can rasterize the page
    // without waiting a full event-loop turn for that async callback — so
    // the canvas stays sized for the on-screen layout, leaving the newly-
    // widened container's extra width blank in the PDF. `beforeprint` fires
    // after the browser has already applied print styles, so forcing a
    // synchronous resize() here reads the correct, already-reflowed
    // dimensions before the page is captured. `afterprint` puts it back once
    // the dialog closes and the sheet returns to its on-screen size.
    const handleBeforePrint = () => map.resize();
    const handleAfterPrint = () => map.resize();
    window.addEventListener("beforeprint", handleBeforePrint);
    window.addEventListener("afterprint", handleAfterPrint);

    return () => {
      window.removeEventListener("beforeprint", handleBeforePrint);
      window.removeEventListener("afterprint", handleAfterPrint);
      map.remove();
      mapRef.current = null;
      loadedRef.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Show/move/hide the pour-point marker as it's picked, changed, or cleared.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (pickMarker) {
      if (!markerRef.current) {
        markerRef.current = new maplibregl.Marker({ color: "#22d3ee" }).setLngLat(pickMarker).addTo(map);
      } else {
        markerRef.current.setLngLat(pickMarker);
      }
    } else if (markerRef.current) {
      markerRef.current.remove();
      markerRef.current = null;
    }
  }, [pickMarker]);

  function syncLayers() {
    const map = mapRef.current;
    if (!map || !loadedRef.current) return;

    const currentLayerIds = new Set(layers.map((l) => l.id));

    // Remove map layers/sources for GISNEXUS layers that no longer exist
    // (deleted, or filtered out by a visibility toggle).
    const style = map.getStyle();
    for (const styleLayer of style.layers || []) {
      const match = /^lyr-(.+)-(fill|line|raster)$/.exec(styleLayer.id);
      if (match && !currentLayerIds.has(match[1])) {
        if (map.getLayer(styleLayer.id)) map.removeLayer(styleLayer.id);
      }
    }
    for (const srcId of Object.keys(style.sources || {})) {
      const match = /^src-(.+)$/.exec(srcId);
      if (match && !currentLayerIds.has(match[1]) && map.getSource(srcId)) {
        map.removeSource(srcId);
      }
    }

    for (const layer of layers) {
      const srcId = sourceIdFor(layer.id);

      // Raster layers come in two flavors:
      //  - service.type xyz/wms/wmts: live tiles from a tile URL template
      //    built server-side — no featuresByLayer entry, no click handler.
      //  - service.type 'image': a single georeferenced image produced
      //    server-side by a terrain tool (Hillshade, ...) — same idea, just
      //    a bounded ImageSource instead of a tiled RasterSource.
      if (layer.kind === "raster") {
        if (!layer.service?.url) continue;
        if (!map.getSource(srcId)) {
          if (layer.service.type === "image" && layer.service.coordinates) {
            map.addSource(srcId, {
              type: "image",
              url: layer.service.url,
              coordinates: layer.service.coordinates as [[number, number], [number, number], [number, number], [number, number]],
            });
          } else {
            map.addSource(srcId, {
              type: "raster",
              tiles: [layer.service.url],
              tileSize: layer.service.tileSize || 256,
              attribution: layer.service.attribution,
            });
          }
        }
        const rasterId = rasterLayerIdFor(layer.id);
        if (!map.getLayer(rasterId)) {
          // Newly-added basemap/imagery layers should sit below any existing
          // GISNEXUS layers (not on top, covering the data) — insert just
          // below the first custom layer currently in the style, if any.
          const firstCustomLayer = (map.getStyle().layers || []).find((l) => l.id.startsWith("lyr-"));
          map.addLayer(
            { id: rasterId, type: "raster", source: srcId, paint: { "raster-opacity": layer.style.opacity } },
            firstCustomLayer?.id
          );
        } else {
          map.setPaintProperty(rasterId, "raster-opacity", layer.style.opacity);
        }
        continue;
      }

      const fc = featuresByLayer[layer.id];
      if (!fc) continue;
      const existingSource = map.getSource(srcId) as maplibregl.GeoJSONSource | undefined;
      if (existingSource) {
        existingSource.setData(fc as unknown as any);
      } else {
        map.addSource(srcId, { type: "geojson", data: fc as unknown as any });
      }

      if (layer.geom_type === "Point") {
        const id = fillLayerIdFor(layer.id);
        if (!map.getLayer(id)) {
          map.addLayer({
            id,
            type: "circle",
            source: srcId,
            paint: {
              "circle-radius": layer.style.size,
              "circle-color": layer.style.color,
              "circle-opacity": layer.style.opacity,
              "circle-stroke-color": "#ffffff",
              "circle-stroke-width": 1.4,
            },
          });
          attachClickHandler(id, layer);
        } else {
          map.setPaintProperty(id, "circle-radius", layer.style.size);
          map.setPaintProperty(id, "circle-color", layer.style.color);
          map.setPaintProperty(id, "circle-opacity", layer.style.opacity);
        }
      } else if (layer.geom_type === "LineString") {
        const id = lineLayerIdFor(layer.id);
        if (!map.getLayer(id)) {
          map.addLayer({
            id,
            type: "line",
            source: srcId,
            layout: { "line-cap": "round", "line-join": "round" },
            paint: { "line-color": layer.style.color, "line-width": layer.style.size, "line-opacity": layer.style.opacity },
          });
          attachClickHandler(id, layer);
        } else {
          map.setPaintProperty(id, "line-color", layer.style.color);
          map.setPaintProperty(id, "line-width", layer.style.size);
          map.setPaintProperty(id, "line-opacity", layer.style.opacity);
        }
      } else if (layer.geom_type === "Polygon") {
        const fillId = fillLayerIdFor(layer.id);
        const lineId = lineLayerIdFor(layer.id);
        if (!map.getLayer(fillId)) {
          map.addLayer({
            id: fillId,
            type: "fill",
            source: srcId,
            paint: { "fill-color": layer.style.color, "fill-opacity": layer.style.opacity },
          });
          map.addLayer({
            id: lineId,
            type: "line",
            source: srcId,
            paint: { "line-color": layer.style.color, "line-width": Math.max(layer.style.size, 1) },
          });
          attachClickHandler(fillId, layer);
        } else {
          map.setPaintProperty(fillId, "fill-color", layer.style.color);
          map.setPaintProperty(fillId, "fill-opacity", layer.style.opacity);
          map.setPaintProperty(lineId, "line-color", layer.style.color);
        }
      }
    }
  }

  function attachClickHandler(mapLayerId: string, layer: LayerDto) {
    const map = mapRef.current;
    if (!map) return;
    map.on("click", mapLayerId, (e: MapLayerMouseEvent) => {
      const feature = e.features?.[0];
      if (!feature) return;
      onFeatureClick(layer, feature as unknown as GeoFeature, [e.lngLat.lng, e.lngLat.lat]);
    });
    map.on("mouseenter", mapLayerId, () => (map.getCanvas().style.cursor = "pointer"));
    map.on("mouseleave", mapLayerId, () => (map.getCanvas().style.cursor = ""));
  }

  // Re-sync whenever layers/features change.
  useEffect(() => {
    syncLayers();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [layers, featuresByLayer]);

  // Fit bounds once, the first time we have any features.
  const fitDoneRef = useRef(false);
  useEffect(() => {
    const map = mapRef.current;
    if (!map || fitDoneRef.current) return;
    const allCoords: [number, number][] = [];
    const collectCoords = (geom: { type: string; coordinates: unknown }) => {
      if (geom.type === "Point") allCoords.push(geom.coordinates as [number, number]);
      else if (geom.type === "LineString") allCoords.push(...(geom.coordinates as [number, number][]));
      else if (geom.type === "Polygon") (geom.coordinates as [number, number][][]).forEach((r) => allCoords.push(...r));
    };
    Object.values(featuresByLayer).forEach((fc) => fc.features.forEach((f) => collectCoords(f.geometry)));
    if (!allCoords.length) return;

    const lons = allCoords.map((c) => c[0]);
    const lats = allCoords.map((c) => c[1]);
    const bounds: LngLatBoundsLike = [
      [Math.min(...lons), Math.min(...lats)],
      [Math.max(...lons), Math.max(...lats)],
    ];
    map.fitBounds(bounds, { padding: 60, maxZoom: 15, duration: 400 });
    fitDoneRef.current = true;
  }, [featuresByLayer]);

  return <div ref={containerRef} className="map-canvas-el" />;
});

export default MapCanvas;
EOF

echo "Writing apps/web/src/components/PrintMapModal.tsx ..."
cat > apps/web/src/components/PrintMapModal.tsx <<'EOF'
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
  // Defaults to the map/project's own name, but printed output is often
  // meant for someone who doesn't care what the project is called internally
  // (a funder, a field team) — so it's editable here without renaming the
  // project itself. Blank falls back to the project name at render time
  // rather than printing an empty header.
  const [printTitle, setPrintTitle] = useState(map.name);
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
          <label className="print-title-field">
            Map title
            <input
              type="text"
              value={printTitle}
              onChange={(e) => setPrintTitle(e.target.value)}
              placeholder={map.name}
            />
          </label>
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
          <h1>{printTitle.trim() || map.name}</h1>
          {map.description && <p>{map.description}</p>}
        </div>

        <div className="print-map-frame">
          <MapCanvas
            layers={layers}
            featuresByLayer={featuresByLayer}
            viewState={map.view_state}
            onViewStateChange={() => {}}
            onFeatureClick={() => {}}
            printMode
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
EOF

echo ""
echo "Done writing files. Now review, build, and push:"
echo ""
echo "  git status"
echo "  git diff --stat"
echo "  npm run build --workspace=apps/web"
echo "  git add -A"
echo "  git commit -m \"Fix print/export map cutoff and blank zoom icons, add custom print title\""
echo "  git push"