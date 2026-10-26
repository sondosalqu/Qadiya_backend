import { z } from "zod";

const idString = z
  .string()
  .regex(/^\d+$/, "Must be a numeric id")
  .transform((v) => BigInt(v));

const ratio = z.number().min(0).max(1);
const size = z.number().gt(0).max(1);

export const saveFindingSchema = z.discriminatedUnion("kind", [

  z.object({
    kind: z.literal("device_file"),
    evidence_id: idString,
  }),

  z.object({
    kind: z.literal("object"),
    scene_id: idString,
    x: ratio,
    y: ratio,
    tolerance: ratio.default(0),
  }),

  z.object({
    kind: z.literal("scene_area"),
    scene_id: idString,
    x: ratio,
    y: ratio,
    w: size,
    h: size,
  }),
 
  z.object({
    kind: z.literal("file_area"),
    evidence_id: idString,
    x: ratio,
    y: ratio,
    w: size,
    h: size,
  }),
]);

export type SaveFindingInput = z.infer<typeof saveFindingSchema>;