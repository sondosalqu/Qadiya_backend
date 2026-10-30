import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { env } from "../config/env.js";
import { HttpError } from "../utils/HttpError.js";

// ─────────────────────────────────────────────────────────────
// قاعدة التخزين:
//   بالداتا بيس بنحفظ "مفتاح" بس، مثل:  findings/3f2a....png
//   والرابط الكامل بنركّبه لحظة الرد:  PUBLIC_BASE_URL/uploads/findings/3f2a....png
// هيك لو تغير عنوان السيرفر (localhost ← IP الجهاز ← سيرفر حقيقي)
// ما بنلمس الداتا، بس بنغير PUBLIC_BASE_URL بالـ.env
//
// روابط خارجية كاملة (https://res.cloudinary.com/...) بتضل زي ما هي.
// ─────────────────────────────────────────────────────────────

const UPLOADS_DIR = path.resolve("uploads");

// روابط قديمة انحفظت قبل هالتعديل: http://localhost:4000/uploads/... (أو 127.0.0.1 أو IP محلي)
const LEGACY_LOCAL = /^https?:\/\/(localhost|127\.0\.0\.1|\d{1,3}(\.\d{1,3}){3})(:\d+)?\/uploads\//i;

// بيرجع المفتاح إذا الملف عنا، أو null إذا رابط خارجي
function toKey(stored: string): string | null {
  if (LEGACY_LOCAL.test(stored)) return stored.replace(LEGACY_LOCAL, "");
  if (/^https?:\/\//i.test(stored)) return null; // خارجي (Cloudinary...)
  return stored.replace(/^\/?(uploads\/)?/, ""); // "/uploads/x.png" أو "x.png" ← "x.png"
}

// للرد على الفرونت/الجوال: دايماً رابط كامل بيفتح
export function toPublicUrl(stored: string | null | undefined): string | null {
  if (!stored) return null;
  const key = toKey(stored);
  if (key === null) return stored;
  const base = env.PUBLIC_BASE_URL.replace(/\/+$/, "");
  return `${base}/uploads/${key}`;
}

// قراءة الملف (مفتاح عنا، أو رابط خارجي)
export async function readStoredFile(stored: string): Promise<Buffer> {
  const key = toKey(stored);

  if (key === null) {
    const res = await fetch(stored, { signal: AbortSignal.timeout(15000) }).catch(() => null);
    if (!res?.ok) throw new HttpError(502, "Could not download the image", "FILE_DOWNLOAD_FAILED");
    return Buffer.from(await res.arrayBuffer());
  }

  const full = path.resolve(UPLOADS_DIR, key);
  // حماية: ما بنسمح نطلع برا مجلد uploads (مثل ../../.env)
  if (!full.startsWith(UPLOADS_DIR + path.sep)) {
    throw new HttpError(400, "Invalid file path", "INVALID_PATH");
  }
  try {
    return await readFile(full);
  } catch {
    throw new HttpError(404, "Image file is missing on the server", "FILE_MISSING");
  }
}

// حفظ ملف جديد: بيرجع المفتاح (هاد اللي بينحفظ بالداتا بيس)
export async function saveFile(data: Buffer, folder: string, ext: string): Promise<string> {
  const dir = path.join(UPLOADS_DIR, folder);
  await mkdir(dir, { recursive: true });

  const name = `${randomUUID()}.${ext}`;
  await writeFile(path.join(dir, name), data);

  return `${folder}/${name}`;
}
