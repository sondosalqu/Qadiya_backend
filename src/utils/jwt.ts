import jwt from "jsonwebtoken";
import { env } from "../config/env.js";

export interface TokenPayload {
  sub: string;                      // user_id
  role: "investigator" | "admin";
}

// إنشاء الـtoken (بالـLogin)
export function signToken(payload: TokenPayload): string {
  return jwt.sign(payload, env.JWT_SECRET, {
    expiresIn: env.JWT_EXPIRES_IN as jwt.SignOptions["expiresIn"],
  });
}

// فحص الـtoken (بالـmiddleware): بيرمي error إذا الـtoken غلط أو منتهي
export function verifyToken(token: string): TokenPayload {
  return jwt.verify(token, env.JWT_SECRET) as TokenPayload;
}