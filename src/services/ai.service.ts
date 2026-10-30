import { env } from "../config/env.js";
import { HttpError } from "../utils/HttpError.js";

export type Box = { x: number; y: number; w: number; h: number };

// إعدادات التحسين (نفس أسماء الحقول بالـPython)
export type EnhanceOps = {
  brightness: number;
  contrast: number;
  grayscale: boolean;
  sharpen: number;
  denoise: number;
  clahe: boolean;
  upscale: number;
};

export function padBox(b: Box, ratio = 0.25): Box {
  const px = b.w * ratio;
  const py = b.h * ratio;
  const x = Math.max(0, b.x - px);
  const y = Math.max(0, b.y - py);
  const right = Math.min(1, b.x + b.w + px);
  const bottom = Math.min(1, b.y + b.h + py);
  return { x, y, w: right - x, h: bottom - y };
}

// كل طلبات خدمة الـPython بتمرق من هون: بتبعت الصورة + الحقول، وبترجع الرد (بعد فحص الأخطاء)
async function postToAiService(path: string, image: Buffer, fields: Record<string, string>, timeoutMs: number) {
  const form = new FormData();
  form.append("image", new Blob([new Uint8Array(image)]), "image");
  for (const [key, value] of Object.entries(fields)) form.append(key, value);

  let res: Response;
  try {
    res = await fetch(`${env.AI_SERVICE_URL}${path}`, {
      method: "POST",
      body: form,
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw new HttpError(503, "Image service is not available", "AI_SERVICE_DOWN");
  }

  if (!res.ok) {
    const body = await res.json().catch(() => null);
    const detail = typeof body?.detail === "string" ? body.detail : `status ${res.status}`;
    // 400 من الـPython = مشكلة بالصورة نفسها (مثلاً كبيرة على التكبير)، مش عطل بالخدمة
    if (res.status === 400) throw new HttpError(422, detail, "IMAGE_PROCESSING_FAILED");
    throw new HttpError(502, `Image service error: ${detail}`, "AI_SERVICE_ERROR");
  }

  return res;
}

// للقص والتحسين: الرد صورة PNG
async function callAiService(path: string, image: Buffer, fields: Record<string, string>, timeoutMs = 15000) {
  const res = await postToAiService(path, image, fields, timeoutMs);
  return { png: Buffer.from(await res.arrayBuffer()), headers: res.headers };
}

export async function cropImage(image: Buffer, box: Box) {
  const { png, headers } = await callAiService("/api/crime-scene/crop", image, {
    x: String(box.x),
    y: String(box.y),
    w: String(box.w),
    h: String(box.h),
  });
  return {
    png,
    width: Number(headers.get("X-Crop-Width")),
    height: Number(headers.get("X-Crop-Height")),
  };
}

// ── OCR ──
export type OcrLang = "auto" | "en" | "ar";

export type OcrLine = {
  text: string;
  confidence: number;
  box: [number, number, number, number]; // x, y, w, h كنسبة من الصورة اللي انقرت
};

export type OcrResult = {
  lang: "en" | "ar";
  text: string;
  lines: OcrLine[];
  confidence: number;
  low_confidence: boolean;
  found_text: boolean;
};

// قراءة النص (الصورة كلها، أو مربع منها). الرد JSON.
export async function ocrImage(image: Buffer, options: { lang?: OcrLang; box?: Box } = {}) {
  const fields: Record<string, string> = { lang: options.lang ?? "auto" };
  if (options.box) {
    fields.x = String(options.box.x);
    fields.y = String(options.box.y);
    fields.w = String(options.box.w);
    fields.h = String(options.box.h);
  }
  // 60 ثانية: أول مرة بعد تشغيل الخدمة ممكن النماذج لسا عم تتحمّل
  const res = await postToAiService("/api/image/ocr", image, fields, 60000);
  return (await res.json()) as OcrResult;
}

export async function enhanceImage(image: Buffer, ops: EnhanceOps) {
  const { png, headers } = await callAiService(
    "/api/image/enhance",
    image,
    {
      brightness: String(ops.brightness),
      contrast: String(ops.contrast),
      grayscale: String(ops.grayscale),
      sharpen: String(ops.sharpen),
      denoise: String(ops.denoise),
      clahe: String(ops.clahe),
      upscale: String(ops.upscale),
    },
    30000, // الـdenoise على صورة كبيرة بياخد وقت
  );
  return {
    png,
    width: Number(headers.get("X-Image-Width")),
    height: Number(headers.get("X-Image-Height")),
  };
}
