import { env } from "../config/env.js";
import { HttpError } from "../utils/HttpError.js";

export type Box = { x: number; y: number; w: number; h: number };

export function padBox(b: Box, ratio = 0.25): Box {
  const px = b.w * ratio;
  const py = b.h * ratio;
  const x = Math.max(0, b.x - px);
  const y = Math.max(0, b.y - py);
  const right = Math.min(1, b.x + b.w + px);
  const bottom = Math.min(1, b.y + b.h + py);
  return { x, y, w: right - x, h: bottom - y };
}

export async function cropImage(image: Buffer, box: Box) {
  const form = new FormData();
  form.append("image", new Blob([new Uint8Array(image)]), "image");
  form.append("x", String(box.x));
  form.append("y", String(box.y));
  form.append("w", String(box.w));
  form.append("h", String(box.h));

  let res: Response;
  try {
    res = await fetch(`${env.AI_SERVICE_URL}/api/crime-scene/crop`, {
      method: "POST",
      body: form,
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new HttpError(503, "Image service is not available", "AI_SERVICE_DOWN");
  }

  if (!res.ok) {
    const body = await res.json().catch(() => null);
    const detail = typeof body?.detail === "string" ? body.detail : `status ${res.status}`;
    throw new HttpError(502, `Image service error: ${detail}`, "AI_SERVICE_ERROR");
  }

  return {
    png: Buffer.from(await res.arrayBuffer()),
    width: Number(res.headers.get("X-Crop-Width")),
    height: Number(res.headers.get("X-Crop-Height")),
  };
}