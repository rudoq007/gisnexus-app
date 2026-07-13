import { Router } from "express";
import { z } from "zod";
import { pool } from "../db";
import { hashPassword, signToken, verifyPassword } from "../lib/auth";
import { ApiError, asyncRoute } from "../middleware/errorHandler";
import { requireAuth, AuthedRequest } from "../middleware/auth";
import { User } from "../types";

export const authRouter = Router();

const registerSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8, "Password must be at least 8 characters."),
  name: z.string().min(1).max(100).optional(),
});

authRouter.post(
  "/register",
  asyncRoute(async (req, res) => {
    const { email, password, name } = registerSchema.parse(req.body);

    const existing = await pool.query<{ id: string }>("SELECT id FROM users WHERE email = $1", [email.toLowerCase()]);
    if (existing.rows.length) {
      throw new ApiError(409, "An account with that email already exists.");
    }

    const passwordHash = await hashPassword(password);
    const { rows } = await pool.query<User>(
      `INSERT INTO users (email, password_hash, name) VALUES ($1, $2, $3)
       RETURNING id, email, name, created_at, password_hash`,
      [email.toLowerCase(), passwordHash, name || null]
    );
    const user = rows[0];
    const token = signToken({ sub: user.id, email: user.email });
    res.status(201).json({ token, user: { id: user.id, email: user.email, name: user.name } });
  })
);

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

authRouter.post(
  "/login",
  asyncRoute(async (req, res) => {
    const { email, password } = loginSchema.parse(req.body);
    const { rows } = await pool.query<User>("SELECT * FROM users WHERE email = $1", [email.toLowerCase()]);
    if (!rows.length) throw new ApiError(401, "Invalid email or password.");

    const user = rows[0];
    const ok = await verifyPassword(password, user.password_hash);
    if (!ok) throw new ApiError(401, "Invalid email or password.");

    const token = signToken({ sub: user.id, email: user.email });
    res.json({ token, user: { id: user.id, email: user.email, name: user.name } });
  })
);

authRouter.get(
  "/me",
  requireAuth,
  asyncRoute(async (req: AuthedRequest, res) => {
    const { rows } = await pool.query<User>("SELECT id, email, name, created_at FROM users WHERE id = $1", [req.user!.id]);
    if (!rows.length) throw new ApiError(404, "User not found.");
    res.json({ user: rows[0] });
  })
);
