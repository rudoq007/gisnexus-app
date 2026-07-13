import { NextFunction, Request, Response } from "express";
import { verifyToken } from "../lib/auth";

export interface AuthedRequest extends Request {
  user?: { id: string; email: string };
}

/** Requires a valid Bearer token. Rejects with 401 if missing/invalid. */
export function requireAuth(req: AuthedRequest, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing Authorization header." });
  }
  try {
    const payload = verifyToken(header.slice("Bearer ".length));
    req.user = { id: payload.sub, email: payload.email };
    next();
  } catch {
    return res.status(401).json({ error: "Invalid or expired token." });
  }
}

/** Populates req.user if a valid token is present, but doesn't reject otherwise. */
export function optionalAuth(req: AuthedRequest, _res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (header && header.startsWith("Bearer ")) {
    try {
      const payload = verifyToken(header.slice("Bearer ".length));
      req.user = { id: payload.sub, email: payload.email };
    } catch {
      // ignore invalid token on optional routes
    }
  }
  next();
}
