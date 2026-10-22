import bcrypt from "bcryptjs";
import { prisma } from "../lib/prisma.js";
import { signToken } from "../utils/jwt.js";
import { HttpError } from "../utils/HttpError.js";
import type { LoginInput, RegisterInput } from "../validators/auth.validator.js";

// الرد المشترك للـLogin والـSign up
function buildAuthResponse(user: {
  user_id: bigint; full_name: string; username: string; email: string; role: string;
}) {
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

export async function register(data: RegisterInput) {
  // 1. الإيميل أو الـusername مستخدمين؟
  const exists = await prisma.users.findFirst({
    where: { OR: [{ email: data.email }, { username: data.username }] },
  });
  if (exists) {
    throw new HttpError(409, "Email or username is already taken", "ACCOUNT_EXISTS");
  }

  // 2. شفّر الباسورد واعمل الحساب (دايماً investigator)
  const user = await prisma.users.create({
    data: {
      full_name: data.full_name,
      username: data.username,
      email: data.email,
      password_hash: await bcrypt.hash(data.password, 10),
      role: "investigator",
    },
  });

  // 3. سجّل دخوله مباشرة
  return buildAuthResponse(user);
}

export async function login({ login, password }: LoginInput) {
  const user = await prisma.users.findFirst({
    where: { OR: [{ email: login.toLowerCase() }, { username: login }] },
  });

  const ok = user && user.is_active && (await bcrypt.compare(password, user.password_hash));
  if (!ok) {
    throw new HttpError(401, "Wrong email/username or password", "INVALID_CREDENTIALS");
  }

  await prisma.users.update({
    where: { user_id: user.user_id },
    data: { last_login_at: new Date() },
  });

  return buildAuthResponse(user);
}

export async function getMe(userId: bigint) {
  const user = await prisma.users.findUnique({
    where: { user_id: userId },
    select: { user_id: true, full_name: true, username: true, email: true, role: true },
  });
  if (!user) throw new HttpError(404, "User not found", "NOT_FOUND");
  return { ...user, user_id: user.user_id.toString() };
}