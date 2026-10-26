import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { env } from "../config/env.js";
import { HttpError } from "../utils/HttpError.js";

const UPLOADS_DIR = path.resolve("uploads");
const PUBLIC_PREFIX = `${env.PUBLIC_BASE_URL}/uploads/`;

export async function readFileFromUrl(url: string): Promise<Buffer> {
  if (url.startsWith(PUBLIC_PREFIX)) {
    const relative = url.slice(PUBLIC_PREFIX.length);
    const full = path.resolve(UPLOADS_DIR, relative);


    if (!full.startsWith(UPLOADS_DIR + path.sep)) {
      throw new HttpError(400, "Invalid file path", "INVALID_PATH");
    }
    try {
      return await readFile(full);
    } catch {
      throw new HttpError(404, "Image file is missing on the server", "FILE_MISSING");
    }
  }

  const res = await fetch(url);
  if (!res.ok) throw new HttpError(502, "Could not download the image", "FILE_DOWNLOAD_FAILED");
  return Buffer.from(await res.arrayBuffer());
}


export async function saveFile(data: Buffer, folder: string, ext: string): Promise<string> {
  const dir = path.join(UPLOADS_DIR, folder);
  await mkdir(dir, { recursive: true });

  const name = `${randomUUID()}.${ext}`;
  await writeFile(path.join(dir, name), data);

  return `${PUBLIC_PREFIX}${folder}/${name}`;
}