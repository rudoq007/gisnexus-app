# Deploying GISNEXUS affordably

Three things need to go somewhere: the **frontend** (static files), the
**backend API** (a long-running Node process), and the **database**
(Postgres + PostGIS). This doc lays out a recommended stack for each budget
stage, with current pricing and sources. Prices below were checked in July
2026 — always confirm on the provider's pricing page before committing, since
these change.

## Recommended stack

| Component | Recommendation | Why |
|---|---|---|
| Frontend | **Cloudflare Pages** | Free, unmetered bandwidth, no "non-commercial only" restriction. |
| Backend API | **Render** (or Railway) | Simple git-push deploys, predictable pricing, no cold-start surprises on the paid tier. |
| Database | **Supabase** (Postgres + PostGIS) | PostGIS is a supported first-party extension; generous free tier to start. |
| File uploads (optional, for large layers) | **Cloudflare R2** | No egress fees — matters once people are viewing maps a lot. |

### Why not Vercel for the frontend?

Vercel's Hobby (free) plan is explicitly restricted to **non-commercial,
personal use** — see the fair-use guidelines linked from
[vercel.com/docs/plans/hobby](https://vercel.com/docs/plans/hobby). If
GISNEXUS is ever going to have real users or make money, Vercel Hobby isn't
licensed for that; you'd need Pro at $20/user/month. Cloudflare Pages has no
such restriction on its free tier, so it's the safer default even though
Vercel's developer experience is excellent — feel free to use Vercel if you
upgrade to Pro or stay strictly personal/non-commercial.

### Why Supabase over Neon or plain RDS?

PostGIS needs to be an available Postgres extension. Supabase documents and
supports enabling `postgis` directly
([supabase.com/docs/guides/database/extensions/postgis](https://supabase.com/docs/guides/database/extensions/postgis)).
Neon's PostGIS support has historically been more limited. If you'd rather
self-manage, any Postgres 14+ with PostGIS works — Render and Railway also
offer managed Postgres, just without a guarantee that PostGIS is preloaded
(check before committing).

## Cost by stage

### Stage 1 — Demo / just you (target: $0/month)

- **Frontend:** Cloudflare Pages Free — 500 builds/month, unmetered bandwidth,
  up to 20,000 files per site.
  ([developers.cloudflare.com/pages/platform/limits](https://developers.cloudflare.com/pages/platform/limits/))
- **Backend:** Render's free Web Service tier — 512MB RAM / 0.1 CPU. It
  **spins down after inactivity** and cold-starts on the next request (a few
  seconds delay), which is fine for a demo, not for real users.
  ([render.com/pricing](https://render.com/pricing))
- **Database:** Supabase Free — 500MB database, 1GB file storage, 5GB egress,
  50,000 monthly active users cap. ([supabase.com/pricing](https://supabase.com/pricing))
- **File storage:** Cloudflare R2 Free — 10GB storage, 1M Class A ops/month,
  10M Class B ops/month, zero egress fees.
  ([developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/))

**Total: $0/month.** Good for showing people the product and personal use.
The tradeoff is the backend's cold start and the database's 500MB cap
(roughly a few hundred thousand small features, depending on geometry
complexity).

### Stage 2 — Small team / early real users (target: ~$12–19/month)

- **Frontend:** Cloudflare Pages Free — still free at this scale.
- **Backend:** Render Starter — **$7/month**, 512MB RAM / 0.5 CPU, always-on
  (no cold starts). ([render.com/pricing](https://render.com/pricing))
- **Database:** Supabase Free, or move to **Pro at $25/month** once you're
  past 500MB or need daily backups (Pro includes 8GB disk + $10/month of
  compute credit covering one "Micro" instance).
  ([supabase.com/pricing](https://supabase.com/pricing))
- **File storage:** Cloudflare R2 Free tier still likely covers this stage.

**Total: ~$7–32/month** depending on whether you've upgraded the database yet.

### Stage 3 — Growing usage (target: ~$45–80/month)

- **Frontend:** still free on Cloudflare Pages — frontend hosting rarely
  becomes the expensive part.
- **Backend:** Render Standard tier, or move to **Railway** if you want
  usage-based billing instead of fixed tiers — Railway's Hobby plan is
  **$5/month** including $5 of usage credit, billed beyond that at
  **$10/GB RAM/month, $20/vCPU/month, $0.05/GB egress, $0.15/GB storage/month**.
  ([docs.railway.com/pricing/plans](https://docs.railway.com/pricing/plans))
- **Database:** Supabase Pro ($25/month) is usually enough until you're at a
  genuinely large dataset (past 8GB, extra disk is $0.125/GB/month; past
  250GB egress, $0.09/GB).
- **File storage:** Cloudflare R2 usage-based beyond the free tier: **$0.015/GB-
  month storage**, **$4.50/million Class A requests** (writes/lists),
  **$0.36/million Class B requests** (reads), **still $0 egress**.
  ([developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/))

**Total: ~$45–80/month** — this is the range where you'd also start
considering Fly.io if you want the backend running physically close to your
users (Fly's shared-cpu-1x VMs run roughly **$1.94–10.70/month** depending on
RAM, but Fly no longer offers a real free tier for new accounts as of the
2024–2026 pricing changes — budget for it from day one if you go that route).
([fly.io/docs/about/pricing](https://fly.io/docs/about/pricing/))

## Step-by-step: Stage 1/2 deployment

### 1. Database — Supabase

1. Create a project at [supabase.com](https://supabase.com).
2. In the dashboard, go to **Database → Extensions**, search "postgis", and
   enable it.
3. Go to **Project Settings → Database → Connection string**, copy the URI
   (use "Session" mode pooling for a simple Node app).
4. Locally (or from a one-off Render/Railway shell), run the migration
   against that connection string:
   ```bash
   DATABASE_URL="<your supabase connection string>" npm run migrate --workspace=apps/api
   ```

### 2. Backend — Render

1. Push this repo to GitHub.
2. In Render, **New → Web Service**, connect the repo, set the root directory
   to `apps/api`.
3. Build command: `npm install && npm run build`. Start command:
   `npm run migrate && npm start`.
4. Set environment variables: `DATABASE_URL` (from Supabase),
   `JWT_SECRET` (generate with `openssl rand -hex 32`), `CORS_ORIGIN` (your
   frontend's URL, added after step 3), `PORT=4000` (Render sets `PORT`
   automatically — you can omit this and let Render inject it, since the API
   reads `process.env.PORT`).
5. Deploy. Note the resulting `https://your-api.onrender.com` URL.

### 3. Frontend — Cloudflare Pages

1. In the Cloudflare dashboard, **Workers & Pages → Create → Pages → Connect
   to Git**, select this repo.
2. Build settings: root directory `apps/web`, build command `npm run build`,
   output directory `dist`.
3. Environment variable: `VITE_API_URL` = your Render API URL from step 2.
4. Deploy. Cloudflare gives you a `*.pages.dev` URL (custom domains are free
   to attach).
5. Go back to Render and set `CORS_ORIGIN` to this Cloudflare Pages URL, then
   redeploy the API so the browser is allowed to call it.

### 4. Smoke test

Visit your Cloudflare Pages URL, register an account, create a map, and
upload a small GeoJSON or CSV file. If the map doesn't load features, check
the browser console for CORS errors first (almost always a `CORS_ORIGIN`
mismatch) and the Render logs second (almost always a `DATABASE_URL` or
missing-PostGIS-extension issue).

## A note on cost discipline

All of the providers above bill primarily on usage past a threshold, not
flat enterprise contracts — so the "Total" numbers here are ceilings you set
by your own plan choice, not surprise bills, with one exception: Supabase's
Pro tier egress and Cloudflare R2's Class A/B operations are genuinely
usage-based and could grow with traffic. Set up billing alerts on both from
day one.
