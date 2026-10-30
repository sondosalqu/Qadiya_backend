import { z } from "zod";

const idString = z
  .string()
  .regex(/^\d+$/, "Must be a numeric id")
  .transform((v) => BigInt(v));

const ratio = z.number().min(0).max(1);
const size = z.number().gt(0).max(1);

const opsSchema = z.object({

  brightness: z.number().int().min(-100).max(100).default(0),
  contrast: z.number().min(0.5).max(3).default(1),
  grayscale: z.boolean().default(false),

  sharpen: z.number().min(0).max(3).default(0),
  denoise: z.number().int().min(0).max(30).default(0),
  clahe: z.boolean().default(false),
  upscale: z.number().int().min(1).max(4).default(1),
});

export const enhanceSchema = z.object({
  source: z.enum(["scene", "file"]),
  id: idString, 
  box: z.object({ x: ratio, y: ratio, w: size, h: size }).optional(), 
  ops: opsSchema.prefault({}), 
});

export type EnhanceInput = z.infer<typeof enhanceSchema>;
