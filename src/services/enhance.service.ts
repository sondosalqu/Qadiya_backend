import { createHash } from "node:crypto";
import { prisma } from "../lib/prisma.js";
import { HttpError } from "../utils/HttpError.js";
import { loadSceneForPlayer, matchRegion, unlockByClue } from "./scene.service.js";
import { cleanSelection, createFinding, loadDeviceFileForPlayer } from "./finding.service.js";
import { cropImage, enhanceImage, type Box, type EnhanceOps } from "./ai.service.js";
import { readStoredFile, saveFile, toPublicUrl } from "./storage.service.js";
import type { EnhanceInput } from "../validators/enhance.validator.js";

const DEFAULT_OPS: EnhanceOps = {
  brightness: 0,
  contrast: 1,
  grayscale: false,
  sharpen: 0,
  denoise: 0,
  clahe: false,
  upscale: 1,
};

// العمليات المتقدمة بتكلف نقاط (cases.cost_advanced_enhance)
function isAdvanced(ops: EnhanceOps) {
  return ops.sharpen > 0 || ops.denoise > 0 || ops.clahe || ops.upscale > 1;
}

function hasAnyChange(ops: EnhanceOps) {
  return isAdvanced(ops) || ops.brightness !== 0 || ops.contrast !== 1 || ops.grayscale;
}

// وصف قصير للي انعمل، بينحفظ بوصف الـFinding
function describeOps(ops: EnhanceOps) {
  const parts: string[] = [];
  if (ops.brightness !== 0) parts.push(`Brightness ${ops.brightness > 0 ? "+" : ""}${ops.brightness}`);
  if (ops.contrast !== 1) parts.push(`Contrast ×${ops.contrast}`);
  if (ops.denoise > 0) parts.push(`Denoise ${ops.denoise}`);
  if (ops.clahe) parts.push("Local contrast");
  if (ops.sharpen > 0) parts.push(`Sharpen ${ops.sharpen}`);
  if (ops.upscale > 1) parts.push(`Upscale ×${ops.upscale}`);
  if (ops.grayscale) parts.push("Grayscale");
  return `Enhanced: ${parts.join(" · ")}`;
}

// الصورة الأصلية: يا صورة المشهد، يا ملف من جهاز (صورة أو مستند بس)
async function loadSource(userId: bigint, input: EnhanceInput) {
  if (input.source === "scene") {
    const { scene, progress } = await loadSceneForPlayer(userId, input.id);
    return {
      progress,
      caseId: scene.case_id,
      imageKey: scene.image_url,
      regionsWhere: { scene_id: scene.scene_id } as const,
      title: "scene",
      srcSceneId: scene.scene_id,
      srcEvidenceId: undefined,
    };
  }

  const { file, progress } = await loadDeviceFileForPlayer(userId, input.id);
  if (!["image", "document"].includes(file.media_type) || !file.file_url) {
    throw new HttpError(422, "You can only enhance an image or a document", "NOT_ENHANCEABLE");
  }
  return {
    progress,
    caseId: file.case_id,
    imageKey: file.file_url,
    regionsWhere: { evidence_id: file.evidence_id } as const,
    title: file.title,
    srcSceneId: undefined,
    srcEvidenceId: file.evidence_id,
  };
}

// مفتاح الدفع = بصمة الطلب نفسه (المصدر + المربع + الإعدادات).
// نفس التحسين بالضبط بيندفع مرة وحدة: الـPreview والـSave ودبل كليك كلهم بنفس السعر.
function paymentKey(input: EnhanceInput, box: Box | null) {
  const fingerprint = JSON.stringify([input.source, input.id.toString(), box, input.ops]);
  return `enh:${createHash("sha256").update(fingerprint).digest("hex")}`;
}

async function spendAdvancedEnhance(progressId: bigint, key: string) {
  try {
    const rows = await prisma.$queryRaw<{ points_after: number }[]>`
      SELECT qd_spend_points(${progressId}, 'advanced_enhance', ${key}, 'Advanced enhance')::int AS points_after`;
    return rows[0].points_after;
  } catch (err) {
    const message = err instanceof Error ? err.message : "";
    if (message.includes("not enough points")) {
      throw new HttpError(402, "You don't have enough points for advanced enhance", "NOT_ENOUGH_POINTS");
    }
    throw err;
  }
}

// القلب: بيجهز الصورة، بيحسنها، وبيخصم النقاط إذا لازم
async function render(userId: bigint, input: EnhanceInput) {
  const ops = input.ops;
  if (!hasAnyChange(ops)) {
    throw new HttpError(422, "Choose at least one adjustment", "NO_ADJUSTMENT");
  }

  const src = await loadSource(userId, input);
  const box = input.box ? cleanSelection(input.box) : null;
  const advanced = isAdvanced(ops);

  // هل المربع فوق منطقة جهزها الأدمن؟ (نفس قاعدة IoU تبع Save selection)
  const match = box ? await matchRegion(src.regionsWhere, box) : null;

  let image: Buffer;
  let opsToRun = ops;

  if (advanced && match?.enhanced_image_url) {
    // الأدمن رافع "النتيجة الصح" لهاي المنطقة: بنرجعها هي،
    // وبنطبق عليها الإضاءة/التباين/الرمادي بس عشان الأزرار تضل تشتغل
    image = await readStoredFile(match.enhanced_image_url);
    opsToRun = { ...DEFAULT_OPS, brightness: ops.brightness, contrast: ops.contrast, grayscale: ops.grayscale };
  } else {
    const original = await readStoredFile(src.imageKey);
    image = box ? (await cropImage(original, box)).png : original;
  }

  const result = hasAnyChange(opsToRun) ? await enhanceImage(image, opsToRun) : { png: image, width: 0, height: 0 };

  // الخصم بعد ما نجح التحسين: إذا الـPython وقع، اللاعب ما بيخسر نقاط
  let pointsRemaining = src.progress.points_remaining;
  let charged = false;
  if (advanced) {
    const after = await spendAdvancedEnhance(src.progress.progress_id, paymentKey(input, box));
    charged = after < pointsRemaining;
    pointsRemaining = after;
  }

  return { src, box, match, result, advanced, charged, pointsRemaining };
}

// معاينة: بترجع الصورة base64 بدون ما تحفظ إشي
export async function previewEnhance(userId: bigint, input: EnhanceInput) {
  const r = await render(userId, input);
  return {
    image: `data:image/png;base64,${r.result.png.toString("base64")}`,
    width: r.result.width || null,
    height: r.result.height || null,
    advanced: r.advanced,
    charged: r.charged,
    points_remaining: r.pointsRemaining,
  };
}

// حفظ: نفس المعاينة (وما بتندفع مرة تانية) + بتنحفظ كـFinding
export async function saveEnhance(userId: bigint, input: EnhanceInput) {
  const r = await render(userId, input);
  const imageKey = await saveFile(r.result.png, "findings", "png");

  // العنوان عام دايماً: ما بيكشف إذا المربع لقى إشي ولا لا
  const title =
    input.source === "scene"
      ? r.box ? "Enhanced scene selection" : "Enhanced scene"
      : `Enhanced · ${r.src.title}`;

  const created = await createFinding({
    progressId: r.src.progress.progress_id,
    caseId: r.src.caseId,
    title,
    description: describeOps(input.ops),
    mediaType: "image",
    fileUrl: imageKey,
    thumbnailUrl: imageKey,
    createdVia: "enhance",
    srcSceneId: r.src.srcSceneId,
    srcEvidenceId: r.src.srcEvidenceId,
    sel: r.box ?? undefined,
    cropKey: imageKey,
    matchedRegionId: r.match?.region_id,
    clueId: r.match?.clue_id ?? undefined,
  });

  const notifications = r.match?.clue_id
    ? await unlockByClue(r.src.progress.progress_id, r.src.caseId, r.match.clue_id)
    : [];

  return {
    finding_id: created.evidenceId.toString(),
    display_code: created.displayCode,
    title,
    image_url: toPublicUrl(imageKey),
    already_saved: false,
    notifications,
    charged: r.charged,
    points_remaining: r.pointsRemaining,
  };
}
