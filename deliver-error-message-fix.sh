#!/usr/bin/env bash
# Fixes the unhelpful "Invalid request" error shown when a terrain tool (or
# any other validated API call) is rejected — the server was catching the
# validation error but always replying with the generic string "Invalid
# request.", discarding the specific, human-readable reason (e.g. "Zoom in
# further — terrain analysis only works on an area up to about 2° across."
# or a specific field being out of range). The frontend already shows
# whatever the server sends back verbatim, so this alone makes every future
# validation error across the whole app (not just terrain tools) tell you
# exactly what was wrong.
#
# This is a BACKEND (apps/api) file — it deploys to Render, not Cloudflare
# Pages, and needs `npm run build --workspace=apps/api`, not apps/web.
#
# Run this from the root of your gisnexus-app checkout:
#   bash deliver-error-message-fix.sh
set -euo pipefail

echo "Writing apps/api/src/middleware/errorHandler.ts ..."
cat > apps/api/src/middleware/errorHandler.ts <<'EOF'
import { NextFunction, Request, Response } from "express";
import { ZodError } from "zod";

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function notFoundHandler(_req: Request, res: Response) {
  res.status(404).json({ error: "Not found." });
}

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction) {
  if (err instanceof ApiError) {
    return res.status(err.status).json({ error: err.message });
  }
  if (err instanceof ZodError) {
    // err.issues[0].message carries the actually-useful text — either a
    // built-in Zod message ("Expected number, received nan") or, more often
    // in this codebase, a hand-written .refine() message meant to be shown
    // to the user (e.g. terrain.ts's "Zoom in further — terrain analysis
    // only works on an area up to about 2° across."). The client's request()
    // helper (api/client.ts) surfaces this `error` string verbatim in the
    // UI, so the generic "Invalid request." previously shipped here was
    // silently swallowing that message and leaving the user with no way to
    // tell what was actually wrong. `details` is kept for anyone inspecting
    // the raw network response/logs.
    const firstIssue = err.issues[0];
    const error = firstIssue ? `Invalid request: ${firstIssue.message}` : "Invalid request.";
    return res.status(400).json({ error, details: err.flatten() });
  }
  // eslint-disable-next-line no-console
  console.error(err);
  const message = err instanceof Error ? err.message : "Internal server error.";
  res.status(500).json({ error: message });
}

/** Wraps an async route handler so thrown/rejected errors reach errorHandler. */
export function asyncRoute<T extends (...args: any[]) => Promise<any>>(fn: T) {
  return (req: Request, res: Response, next: NextFunction) => {
    fn(req, res, next).catch(next);
  };
}
EOF

echo ""
echo "Done writing file. Now review, build, and push:"
echo ""
echo "  git status"
echo "  git diff --stat"
echo "  npm run build --workspace=apps/api"
echo "  git add -A"
echo "  git commit -m \"Surface the real validation reason instead of generic 'Invalid request'\""
echo "  git push"
echo ""
echo "This deploys to Render (the API), not Cloudflare Pages — after pushing,"
echo "check Render's dashboard for the deploy to finish, then try Hillshade"
echo "again. The error banner should now say something specific instead of"
echo "just 'Invalid request' — send me that exact new message if it still"
echo "fails and I can pin down the root cause immediately."