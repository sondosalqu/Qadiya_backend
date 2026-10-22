import type { NextFunction, Request, Response } from "express";
import { ZodError } from "zod";
import { HttpError } from "../utils/HttpError.js";

export function notFoundHandler(req: Request, _res: Response, next: NextFunction) {
  next(new HttpError(404, `Route ${req.method} ${req.path} not found`, "ROUTE_NOT_FOUND"));
}

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction) {
  if (err instanceof ZodError) {
    return res.status(422).json({
      error: {
        code: "VALIDATION_ERROR",
        message: "Some fields are invalid",
        details: err.issues.map((i) => ({ field: i.path.join("."), message: i.message })),
      },
    });
  }
  if (err instanceof HttpError) {
    return res.status(err.status).json({ error: { code: err.code, message: err.message } });
  }
  console.error(err);
  return res.status(500).json({ error: { code: "INTERNAL_ERROR", message: "Something went wrong" } });
}