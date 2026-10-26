import type { Request, Response } from "express";
import { saveFindingSchema } from "../validators/finding.validator.js";
import * as findingService from "../services/finding.service.js";

export async function saveFinding(req: Request, res: Response) {
  const input = saveFindingSchema.parse(req.body ?? {});
  const result = await findingService.saveFinding(res.locals.user.id, input);
  res.status(result.already_saved ? 200 : 201).json(result);
}