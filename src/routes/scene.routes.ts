import { Router } from "express";
import { getScene, inspectScene } from "../controllers/scene.controller.js";
import { requireAuth } from "../middleware/auth.js";

export const sceneRouter = Router();

sceneRouter.get("/:sceneId", requireAuth, getScene);
sceneRouter.post("/:sceneId/inspect", requireAuth, inspectScene);