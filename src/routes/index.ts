import { Router } from "express";
import { authRouter } from "./auth.routes.js";
import { sceneRouter } from "./scene.routes.js";
import { findingRouter } from "./finding.routes.js";
export const apiRouter = Router();

apiRouter.use("/auth", authRouter);
apiRouter.use("/scenes", sceneRouter);
apiRouter.use("/findings", findingRouter);