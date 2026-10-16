import cors from "cors";
import express from "express";
import helmet from "helmet";
import morgan from "morgan";
import { prisma } from "./lib/prisma.js";

export function createApp() {
  const app = express();

  app.use(helmet());                        // headers حماية
  app.use(cors());                          // بيسمح للفرونت يحكي مع السيرفر
  app.use(express.json({ limit: "1mb" }));  // بيقرا JSON من الطلبات
  app.use(morgan("dev"));                   // بيطبع كل طلب بالـterminal

  // فحص: السيرفر شغال والداتابيس متصلة
  app.get("/api/health", async (_req, res) => {
    await prisma.$queryRaw`SELECT 1`;
    res.json({ status: "ok", database: "connected", time: new Date().toISOString() });
  });

  // أي رابط مش موجود
  app.use((req, res) => {
    res.status(404).json({ error: { code: "ROUTE_NOT_FOUND", message: `Route ${req.method} ${req.path} not found` } });
  });

  return app;
}