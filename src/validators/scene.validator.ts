import { z } from "zod";

export const sceneParamsSchema = z.object({
  sceneId: z
    .string()
    .regex(/^\d+$/, "Scene id must be a number")
    .transform((v) => BigInt(v)),
});

export const inspectBodySchema = z.object({
  x: z.number().min(0).max(1),
  y: z.number().min(0).max(1),
  tolerance: z.number().min(0).max(1).default(0),
});

export type InspectInput = z.infer<typeof inspectBodySchema>;