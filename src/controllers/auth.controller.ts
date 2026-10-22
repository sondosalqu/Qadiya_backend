import type { Request, Response } from "express";
import { loginSchema, registerSchema } from "../validators/auth.validator.js";
import * as authService from "../services/auth.service.js";

export async function register(req: Request, res: Response) {
  const data = registerSchema.parse(req.body ?? {});
  const result = await authService.register(data);
  res.status(201).json(result);
}

export async function login(req: Request, res: Response) {
  const data = loginSchema.parse(req.body ?? {});
  const result = await authService.login(data);
  res.status(200).json(result);
}

export async function me(_req: Request, res: Response) {
  const user = await authService.getMe(res.locals.user.id);
  res.status(200).json(user);
}

export async function logout(_req: Request, res: Response) {
  // الـtoken بيمسحه الفرونت. السيرفر بس بيأكد.
  res.status(200).json({ message: "Logged out" });
}