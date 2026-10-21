import type { Request, Response } from "express";
import { loginSchema } from "../validators/auth.validator.js";
import * as authService from "../services/auth.service.js";

export async function login(req: Request, res: Response) {
  // 1. افحص البيانات اللي جاية (إذا غلط → ZodError → 422)
  const data = loginSchema.parse(req.body);

  // 2. نادي الـservice (إذا الباسورد غلط → HttpError → 401)
  const result = await authService.login(data);

  // 3. رجّع النتيجة
  res.status(200).json(result);
}
export async function me(_req: Request, res: Response) {
  const user = await authService.getMe(res.locals.user.id);
  res.status(200).json(user);
}