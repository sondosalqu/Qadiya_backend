import cors from "cors";
import express from "express";
import helmet from "helmet";
import morgan from "morgan";
import { prisma } from "./lib/prisma.js";
import { apiRouter } from "./routes/index.js";
import { errorHandler, notFoundHandler } from "./middleware/errorHandler.js";

export function createApp() {
  const app = express();

  app.use(helmet());
  app.use(cors());
  app.use(express.json({ limit: "1mb" }));
  app.use(morgan("dev"));

  app.get("/api/health", async (_req, res) => {
    await prisma.$queryRaw`SELECT 1`;
    res.json({ status: "ok", database: "connected", time: new Date().toISOString() });
  });

  app.use("/api", apiRouter);
  app.use(notFoundHandler); 
  app.use(errorHandler);     

  return app;
}