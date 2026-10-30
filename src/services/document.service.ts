import { HttpError } from "../utils/HttpError.js";
import { loadDeviceFileForPlayer } from "./finding.service.js";
import { getCachedOcr } from "./ocr.service.js";

// سطور صفحة (للتضوية بعارض الورقة). ما فيها أي إشارة لأي سطر هو الدليل.
export async function getPageLines(userId: bigint, evidenceId: bigint) {
  const { file } = await loadDeviceFileForPlayer(userId, evidenceId);
  if (!["image", "document"].includes(file.media_type) || !file.file_url) {
    throw new HttpError(422, "This file has no readable page", "NOT_READABLE");
  }

  const page = await getCachedOcr(file.file_url);
  return {
    evidence_id: file.evidence_id.toString(),
    lang: page.lang,
    low_confidence: page.low_confidence,
    lines: page.lines.map((l, index) => ({
      index,
      text: l.text,
      confidence: l.confidence,
      box: { x: l.box[0], y: l.box[1], w: l.box[2], h: l.box[3] },
    })),
  };
}
