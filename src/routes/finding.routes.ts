import { Router } from "express";
import { saveFinding } from "../controllers/finding.controller.js";
import { requireAuth } from "../middleware/auth.js";

export const findingRouter = Router();

findingRouter.post("/", requireAuth, saveFinding);
