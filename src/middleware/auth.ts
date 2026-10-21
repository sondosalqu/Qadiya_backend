import type { NextFunction, Request, Response } from "express";
import { verifyToken, type TokenPayload } from "../utils/jwt.js";
import { HttpError } from "../utils/HttpError.js";

// لازم يكون مسجّل دخول
export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? "";      // ← "Bearer eyJhbGc..."
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) throw new HttpError(401, "Login required", "UNAUTHENTICATED");

  let payload: TokenPayload;
  try {
    payload = verifyToken(token);
  } catch {
    throw new HttpError(401, "Session expired, please log in again", "INVALID_TOKEN");
  }

  res.locals.user = { id: BigInt(payload.sub), role: payload.role };
  next();
}

// لازم يكون إله الدور المطلوب
export function requireRole(...roles: TokenPayload["role"][]) {
  return (_req: Request, res: Response, next: NextFunction) => {
    if (!roles.includes(res.locals.user?.role)) {
      throw new HttpError(403, "You are not allowed to do this", "FORBIDDEN");
    }
    next();
  };
}

