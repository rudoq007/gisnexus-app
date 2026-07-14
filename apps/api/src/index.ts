import express from "express";
import cors from "cors";
import { env } from "./env";
import { authRouter } from "./routes/auth";
import { mapsRouter } from "./routes/maps";
import { layersRouter } from "./routes/layers";
import { analysisRouter } from "./routes/analysis";
import { terrainRouter } from "./routes/terrain";
import { dashboardRouter } from "./routes/dashboard";
import { publicRouter } from "./routes/public";
import { errorHandler, notFoundHandler } from "./middleware/errorHandler";

const app = express();

app.use(cors({ origin: env.corsOrigin }));
app.use(express.json({ limit: "2mb" }));

app.get("/health", (_req, res) => res.json({ ok: true }));

app.use("/api/auth", authRouter);
app.use("/api/maps", mapsRouter);
app.use("/api", layersRouter); // mounts /api/maps/:mapId/layers/upload and /api/layers/:id/*
app.use("/api", analysisRouter); // mounts /api/layers/:id/buffer and /intersects
app.use("/api", terrainRouter); // mounts /api/maps/:mapId/terrain/hillshade
app.use("/api", dashboardRouter); // mounts /api/layers/:id/aggregate
app.use("/api/public", publicRouter);

app.use(notFoundHandler);
app.use(errorHandler);

app.listen(env.port, () => {
  // eslint-disable-next-line no-console
  console.log(`GISNEXUS API listening on http://localhost:${env.port}`);
});
