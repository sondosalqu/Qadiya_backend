import { Router } from "express";
import { authRouter } from "./auth.routes.js";
import { sceneRouter } from "./scene.routes.js";
import { findingRouter } from "./finding.routes.js";
import { enhanceRouter } from "./enhance.routes.js";
import { documentRouter } from "./document.routes.js";
export const apiRouter = Router();

apiRouter.use("/auth", authRouter);
apiRouter.use("/scenes", sceneRouter);
apiRouter.use("/findings", findingRouter);
apiRouter.use("/enhance", enhanceRouter);
apiRouter.use("/documents", documentRouter);