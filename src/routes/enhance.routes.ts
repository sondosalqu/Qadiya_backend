import { Router } from "express";
import { previewEnhance, saveEnhance } from "../controllers/enhance.controller.js";
import { requireAuth } from "../middleware/auth.js";

export const enhanceRouter = Router();

enhanceRouter.post("/preview", requireAuth, previewEnhance);
enhanceRouter.post("/save", requireAuth, saveEnhance);
