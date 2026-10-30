import type { Request, Response } from "express";
import { pageParamsSchema } from "../validators/document.validator.js";
import * as documentService from "../services/document.service.js";

export async function getPageLines(req: Request, res: Response) {
  const { evidenceId } = pageParamsSchema.parse(req.params);
  const result = await documentService.getPageLines(res.locals.user.id, evidenceId);
  res.status(200).json(result);
}
