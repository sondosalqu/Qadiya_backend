import { z } from "zod";

export const pageParamsSchema = z.object({
  evidenceId: z
    .string()
    .regex(/^\d+$/, "Page id must be a number")
    .transform((v) => BigInt(v)),
});
