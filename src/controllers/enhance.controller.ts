import type { Request, Response } from "express";
import { enhanceSchema } from "../validators/enhance.validator.js";
import * as enhanceService from "../services/enhance.service.js";

export async function previewEnhance(req: Request, res: Response) {
  const input = enhanceSchema.parse(req.body ?? {});
  const result = await enhanceService.previewEnhance(res.locals.user.id, input);
  res.status(200).json(result);
}

export async function saveEnhance(req: Request, res: Response) {
  const input = enhanceSchema.parse(req.body ?? {});
  const result = await enhanceService.saveEnhance(res.locals.user.id, input);
  res.status(201).json(result);
}
