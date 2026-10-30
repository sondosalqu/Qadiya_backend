import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { ocrImage, type OcrResult } from "./ai.service.js";
import { readStoredFile } from "./storage.service.js";

// ─────────────────────────────────────────────────────────────
// قراءة صفحة كاملة بتاخد ثواني، ونفس الصفحة ما بتتغير.
// فبنقرأ كل صفحة مرة وحدة وبنحفظ النتيجة بملف (cache/ocr/...json).
// مش جوا uploads/ لأنه هداك مكشوف للكل على الإنترنت.
// ─────────────────────────────────────────────────────────────

const CACHE_DIR = path.resolve("cache", "ocr");
const CACHE_VERSION = "v1"; // إذا غيرنا طريقة القراءة، بنغير الرقم فبتنقرأ الصفحات من جديد

// إذا طلبين إجو لنفس الصفحة بنفس اللحظة، بيستنوا نفس القراءة بدل ما نقرأ مرتين
const inFlight = new Map<string, Promise<OcrResult>>();

function cacheFile(stored: string) {
  const key = createHash("sha1").update(`${CACHE_VERSION}|${stored}`).digest("hex");
  return path.join(CACHE_DIR, `${key}.json`);
}

async function readAndCache(stored: string, file: string): Promise<OcrResult> {
  try {
    return JSON.parse(await readFile(file, "utf-8")) as OcrResult;
  } catch {
    // مش موجود بالـcache: بنقرأ
  }
  const result = await ocrImage(await readStoredFile(stored), { lang: "auto" });
  await mkdir(CACHE_DIR, { recursive: true });
  await writeFile(file, JSON.stringify(result), "utf-8");
  return result;
}

/** نص صفحة كاملة (stored = المفتاح أو الرابط المحفوظ بالداتا بيس). */
export function getCachedOcr(stored: string): Promise<OcrResult> {
  const file = cacheFile(stored);
  let job = inFlight.get(file);
  if (!job) {
    job = readAndCache(stored, file).finally(() => inFlight.delete(file));
    inFlight.set(file, job);
  }
  return job;
}
