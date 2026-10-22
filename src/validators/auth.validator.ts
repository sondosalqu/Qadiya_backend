import { z } from "zod";

export const loginSchema = z.object({
  login: z.string().trim().min(1, "Email or username is required"),
  password: z.string().min(1, "Password is required"),
});
export const registerSchema = z.object({
  full_name: z.string().trim().min(2, "Name is too short").max(120),
  username: z
    .string()
    .trim()
    .min(3, "Username must be at least 3 characters")
    .max(50)
    .regex(/^[a-zA-Z0-9_.]+$/, "Only letters, numbers, _ and ."),
  email: z.string().trim().toLowerCase().email("Invalid email"),
  password: z.string().min(8, "Password must be at least 8 characters").max(100),
});

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;