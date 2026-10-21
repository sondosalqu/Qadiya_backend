import bcrypt from "bcryptjs";
import { prisma } from "../lib/prisma.js";
import { signToken } from "../utils/jwt.js";
import { HttpError } from "../utils/HttpError.js";
import type { LoginInput } from "../validators/auth.validator.js";

export async function login({ login, password }: LoginInput) {
  // 1. دوّر على المستخدم بالإيميل أو الـusername
  const user = await prisma.users.findFirst({
    where: { OR: [{ email: login.toLowerCase() }, { username: login }] },
  });

  // 2. افحص الباسورد (نفس الرسالة للحالتين، عشان ما نكشف إذا الحساب موجود)
  const ok = user && user.is_active && (await bcrypt.compare(password, user.password_hash));
  if (!ok) {
    throw new HttpError(401, "Wrong email/username or password", "INVALID_CREDENTIALS");
  }

  // 3. سجّل وقت آخر دخول
  await prisma.users.update({
    where: { user_id: user.user_id },
    data: { last_login_at: new Date() },
  });

  // 4. اعمل الـtoken
  const token = signToken({
    sub: user.user_id.toString(),
    role: user.role as "investigator" | "admin",
  });

  return {
    token,
    user: {
      user_id: user.user_id.toString(),
      full_name: user.full_name,
      username: user.username,
      email: user.email,
      role: user.role,
    },
  };
}

export async function getMe(userId: bigint) {
  const user = await prisma.users.findUnique({
    where: { user_id: userId },
    select: { user_id: true, full_name: true, username: true, email: true, role: true },
  });
  if (!user) throw new HttpError(404, "User not found", "NOT_FOUND");
  return { ...user, user_id: user.user_id.toString() };
}