import type { Request, Response } from "express";
import { inspectBodySchema, sceneParamsSchema } from "../validators/scene.validator.js";
import * as sceneService from "../services/scene.service.js";

export async function getScene(req: Request, res: Response) {
  const { sceneId } = sceneParamsSchema.parse(req.params);
  const result = await sceneService.getScene(res.locals.user.id, sceneId);
  res.status(200).json(result);
}



export async function inspectScene(req: Request, res: Response) {
  const { sceneId } = sceneParamsSchema.parse(req.params);
  const input = inspectBodySchema.parse(req.body ?? {});
  const result = await sceneService.inspectPoint(res.locals.user.id, sceneId, input);
  res.status(200).json(result);
}