import { Router } from "express";
import { getPageLines } from "../controllers/document.controller.js";
import { requireAuth } from "../middleware/auth.js";

export const documentRouter = Router();

documentRouter.get("/pages/:evidenceId/lines", requireAuth, getPageLines);
