import { Pool } from "pg";
import { env } from "./env";

export const pool = new Pool({
  connectionString: env.databaseUrl,
  // Most managed Postgres providers (Supabase, Render, Railway) require SSL.
  // Disable only for plain local docker-compose Postgres.
  ssl: env.databaseUrl.includes("localhost") ? undefined : { rejectUnauthorized: false },
});

pool.on("error", (err) => {
  // eslint-disable-next-line no-console
  console.error("Unexpected Postgres pool error", err);
});
