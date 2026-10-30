import { prisma } from "../lib/prisma.js";
import { HttpError } from "../utils/HttpError.js";
import {
  containerKind,
  findRegionAt,
  getPlayerProgress,
  loadSceneForPlayer,
  matchRegion,
  splitDetails,
  unlockByClue,
} from "./scene.service.js";
import { cropImage, ocrImage, padBox, type Box } from "./ai.service.js";
import { getCachedOcr } from "./ocr.service.js";
import { readStoredFile, saveFile, toPublicUrl } from "./storage.service.js";
import type { SaveFindingInput } from "../validators/finding.validator.js";


type NewFinding = {
  progressId: bigint;
  caseId: bigint;
  title: string;
  description: string | null;
  mediaType: string;
  fileUrl: string | null;
  thumbnailUrl: string | null;
  createdVia: "manual" | "scene_selection" | "enhance" | "ocr";
  srcEvidenceId?: bigint;
  srcSceneId?: bigint;
  sel?: Box;
  cropKey?: string;
  matchedRegionId?: bigint;
  clueId?: bigint;
  ocrText?: string;
};


export async function createFinding(f: NewFinding) {
  return prisma.$transaction(async (tx) => {
    const progress = await tx.case_progress.update({
      where: { progress_id: f.progressId },
      data: { finding_seq: { increment: 1 }, last_activity_at: new Date() },
      select: { finding_seq: true, points_remaining: true },
    });
    const displayCode = `F-${String(progress.finding_seq).padStart(3, "0")}`;

    const evidence = await tx.evidence_items.create({
      data: {
        case_id: f.caseId,
        origin_type: "investigator",
        progress_id: f.progressId,
        media_type: f.mediaType,
        title: f.title,
        description: f.description,
        source: "Investigator",
        file_url: f.fileUrl,
        thumbnail_url: f.thumbnailUrl,
      },
    });

    await tx.findings.create({
      data: {
        evidence_id: evidence.evidence_id,
        progress_id: f.progressId,
        display_code: displayCode,
        created_via: f.createdVia,
        src_evidence_id: f.srcEvidenceId,
        src_scene_id: f.srcSceneId,
        sel_x: f.sel?.x,
        sel_y: f.sel?.y,
        sel_w: f.sel?.w,
        sel_h: f.sel?.h,
        crop_url: f.cropKey,
        ocr_text: f.ocrText,
        matched_region_id: f.matchedRegionId,
        clue_id: f.clueId,
      },
    });

    await tx.progress_activity.create({
      data: {
        progress_id: f.progressId,
        action_type: "save_finding",
        points_delta: 0,
        points_after: progress.points_remaining,
        ref_evidence_id: evidence.evidence_id,
        description: `Saved ${displayCode}`,
      },
    });

    return { evidenceId: evidence.evidence_id, displayCode };
  });
}


// ملف من جهاز (DEV-) أو صفحة من ورقة/كتاب (DOC- / BOOK-)، بشرط اللاعب يقدر يشوفه
export async function loadDeviceFileForPlayer(userId: bigint, evidenceId: bigint) {
  const file = await prisma.evidence_items.findUnique({ where: { evidence_id: evidenceId } });
  if (!file || file.origin_type !== "police" || !containerKind(file.collected_location)) {
    throw new HttpError(404, "File not found", "FILE_NOT_FOUND");
  }

  const progress = await getPlayerProgress(userId, file.case_id);

  if (file.is_hidden_initially) {
    const unlocked = await prisma.progress_unlocks.findFirst({
      where: {
        progress_id: progress.progress_id,
        unlock_rules: { unlock_evidence_id: file.evidence_id },
      },
    });
    if (!unlocked) throw new HttpError(404, "File not found", "FILE_NOT_FOUND");
  }

  return { file, progress };
}

const round5 = (v: number) => Math.round(v * 1e5) / 1e5;

export function cleanSelection(s: Box): Box {
  if (s.x + s.w > 1 + 1e-6 || s.y + s.h > 1 + 1e-6) {
    throw new HttpError(422, "Selection is outside the image", "SELECTION_OUT_OF_BOUNDS");
  }
  const x = round5(s.x);
  const y = round5(s.y);
  const w = Math.min(round5(s.w), round5(1 - x));
  const h = Math.min(round5(s.h), round5(1 - y));
  if (w <= 0 || h <= 0 || x >= 1 || y >= 1) {
    throw new HttpError(422, "Selection is too small", "SELECTION_TOO_SMALL");
  }
  return { x, y, w, h };
}

// بيقص وبيحفظ، وبيرجع مفتاح الملف (مش رابط)
async function cropAndStore(stored: string, box: Box) {
  const image = await readStoredFile(stored);
  const crop = await cropImage(image, box);
  return saveFile(crop.png, "findings", "png");
}


async function saveDeviceFile(userId: bigint, evidenceId: bigint) {
  const { file, progress } = await loadDeviceFileForPlayer(userId, evidenceId);

  const existing = await prisma.findings.findFirst({
    where: {
      progress_id: progress.progress_id,
      src_evidence_id: file.evidence_id,
      created_via: "manual",
      sel_x: null,
    },
    select: { evidence_id: true, display_code: true },
  });
  if (existing) {
    return {
      finding_id: existing.evidence_id.toString(),
      display_code: existing.display_code,
      title: file.title,
      image_url: toPublicUrl(file.file_url),
      already_saved: true,
      notifications: [] as string[],
    };
  }

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: file.case_id,
    title: file.title,
    description: file.description,
    mediaType: file.media_type,
    fileUrl: file.file_url,
    thumbnailUrl: file.thumbnail_url,
    createdVia: "manual",
    srcEvidenceId: file.evidence_id,
  });

  return {
    finding_id: created.evidenceId.toString(),
    display_code: created.displayCode,
    title: file.title,
    image_url: toPublicUrl(file.file_url),
    already_saved: false,
    notifications: [] as string[],
  };
}


async function saveSceneObject(
  userId: bigint,
  input: { scene_id: bigint; x: number; y: number; tolerance: number },
) {
  const { scene, progress } = await loadSceneForPlayer(userId, input.scene_id);

  const region = await findRegionAt(scene.scene_id, input.x, input.y, input.tolerance);
  if (!region) throw new HttpError(404, "Nothing to save at this spot", "NOTHING_HERE");

  const { title, details } = splitDetails(region.observed_details);
  const name = title ?? "Scene object";

  const existing = await prisma.findings.findFirst({
    where: {
      progress_id: progress.progress_id,
      src_scene_id: scene.scene_id,
      matched_region_id: region.region_id,
      sel_x: null,
    },
    select: { evidence_id: true, display_code: true, crop_url: true },
  });
  if (existing) {
    return {
      finding_id: existing.evidence_id.toString(),
      display_code: existing.display_code,
      title: name,
      image_url: toPublicUrl(existing.crop_url),
      already_saved: true,
      notifications: [] as string[],
    };
  }

  const cropKey = await cropAndStore(
    scene.image_url,
    padBox({ x: region.x.toNumber(), y: region.y.toNumber(), w: region.w.toNumber(), h: region.h.toNumber() }),
  );

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: scene.case_id,
    title: name,
    description: details,
    mediaType: "object",
    fileUrl: cropKey,
    thumbnailUrl: cropKey,
    createdVia: "scene_selection",
    srcSceneId: scene.scene_id,
    cropKey,
    matchedRegionId: region.region_id,
    clueId: region.clue_id ?? undefined,
  });

  const notifications = region.clue_id
    ? await unlockByClue(progress.progress_id, scene.case_id, region.clue_id)
    : [];

  return {
    finding_id: created.evidenceId.toString(),
    display_code: created.displayCode,
    title: name,
    image_url: toPublicUrl(cropKey),
    already_saved: false,
    notifications,
  };
}

async function saveSceneArea(userId: bigint, input: { scene_id: bigint } & Box) {
  const sel = cleanSelection(input);
  const { scene, progress } = await loadSceneForPlayer(userId, input.scene_id);

  const match = await matchRegion({ scene_id: scene.scene_id }, sel);

  const cropKey = await cropAndStore(scene.image_url, sel);

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: scene.case_id,
    title: "Scene selection", 
    description: null,
    mediaType: "image",
    fileUrl: cropKey,
    thumbnailUrl: cropKey,
    createdVia: "scene_selection",
    srcSceneId: scene.scene_id,
    sel,
    cropKey,
    matchedRegionId: match?.region_id,
    clueId: match?.clue_id ?? undefined,
  });

  const notifications = match?.clue_id
    ? await unlockByClue(progress.progress_id, scene.case_id, match.clue_id)
    : [];

  return {
    finding_id: created.evidenceId.toString(),
    display_code: created.displayCode,
    title: "Scene selection",
    image_url: toPublicUrl(cropKey),
    already_saved: false,
    notifications,
  };
}

async function saveFileArea(userId: bigint, input: { evidence_id: bigint } & Box) {
  const sel = cleanSelection(input);
  const { file, progress } = await loadDeviceFileForPlayer(userId, input.evidence_id);

  if (!["image", "document"].includes(file.media_type) || !file.file_url) {
    throw new HttpError(422, "You can only select an area inside an image or a document", "NOT_SELECTABLE");
  }


  const match = await matchRegion({ evidence_id: file.evidence_id }, sel);

  const cropKey = await cropAndStore(file.file_url, sel);
  const title = `Selection · ${file.title}`;

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: file.case_id,
    title,
    description: null,
    mediaType: "image",
    fileUrl: cropKey,
    thumbnailUrl: cropKey,
    createdVia: "manual",
    srcEvidenceId: file.evidence_id,
    sel,
    cropKey,
    matchedRegionId: match?.region_id,
    clueId: match?.clue_id ?? undefined,
  });

  const notifications = match?.clue_id
    ? await unlockByClue(progress.progress_id, file.case_id, match.clue_id)
    : [];

  return {
    finding_id: created.evidenceId.toString(),
    display_code: created.displayCode,
    title,
    image_url: toPublicUrl(cropKey),
    already_saved: false,
    notifications,
  };
}

// ─────────────────────────────────────────────
// اختيار سطر/فقرة من ورقة (عارض الورقة)
// ─────────────────────────────────────────────
const center = (b: Box) => ({ x: b.x + b.w / 2, y: b.y + b.h / 2 });
const contains = (b: Box, p: { x: number; y: number }) =>
  p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h;
const area = (b: Box) => b.w * b.h;

function intersection(a: Box, b: Box) {
  const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

// منطقة الأدمن (text) بتنحسب إذا اللاعب غطى معظمها (60%+)،
// بس من غير ما يختار نص الصفحة "احتياط" (المختار مش أكبر من 4 أضعافها).
async function matchTextRegion(evidenceId: bigint, sel: Box) {
  const regions = await prisma.image_regions.findMany({
    where: { evidence_id: evidenceId, region_type: "text" },
  });
  let best: (typeof regions)[number] | null = null;
  let bestCoverage = 0;
  for (const r of regions) {
    const box = { x: r.x.toNumber(), y: r.y.toNumber(), w: r.w.toNumber(), h: r.h.toNumber() };
    const coverage = intersection(sel, box) / area(box);
    if (coverage >= 0.6 && area(sel) <= area(box) * 4 && coverage > bestCoverage) {
      best = r;
      bestCoverage = coverage;
    }
  }
  return best;
}

async function saveTextSelection(userId: bigint, input: { evidence_id: bigint } & Box) {
  const sel = cleanSelection(input);
  const { file, progress } = await loadDeviceFileForPlayer(userId, input.evidence_id);
  if (!["image", "document"].includes(file.media_type) || !file.file_url) {
    throw new HttpError(422, "You can only read text from an image or a document", "NOT_READABLE");
  }

  // 1) السطور اللي جوا المربع (من قراءة الصفحة المحفوظة)
  const page = await getCachedOcr(file.file_url);
  const picked = page.lines
    .map((l) => ({ text: l.text, box: { x: l.box[0], y: l.box[1], w: l.box[2], h: l.box[3] } }))
    .filter((l) => contains(sel, center(l.box)));
  let lines = picked.map((l) => l.text);

  // 2) إذا المربع على سطر الأدمن: النص الصح هو revealed_text (حتى لو القراءة غلطت بحرف)
  const match = await matchTextRegion(file.evidence_id, sel);
  if (match?.revealed_text) {
    const regionBox = { x: match.x.toNumber(), y: match.y.toNumber(), w: match.w.toNumber(), h: match.h.toNumber() };
    const i = picked.findIndex((l) => contains(regionBox, center(l.box)));
    if (i >= 0) lines[i] = match.revealed_text;
    else lines = [...lines, match.revealed_text];
  }

  // 3) ولا سطر؟ بنقرأ المربع نفسه (ممكن كلمة صغيرة فاتت قراءة الصفحة)
  if (lines.length === 0) {
    const direct = await ocrImage(await readStoredFile(file.file_url), { box: sel });
    lines = direct.lines.map((l) => l.text);
  }
  if (lines.length === 0) {
    throw new HttpError(422, "No readable text in this selection", "NO_TEXT_FOUND");
  }

  const text = lines.join("\n");
  const cropKey = await cropAndStore(file.file_url, sel);
  const title = `Text · ${file.title}`; // عام: ما بيكشف إذا لقى دليل

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: file.case_id,
    title,
    description: text,
    mediaType: "document",
    fileUrl: cropKey,
    thumbnailUrl: cropKey,
    createdVia: "ocr",
    srcEvidenceId: file.evidence_id,
    sel,
    cropKey,
    matchedRegionId: match?.region_id,
    clueId: match?.clue_id ?? undefined,
    ocrText: text,
  });

  const notifications = match?.clue_id
    ? await unlockByClue(progress.progress_id, file.case_id, match.clue_id)
    : [];

  return {
    finding_id: created.evidenceId.toString(),
    display_code: created.displayCode,
    title,
    image_url: toPublicUrl(cropKey),
    already_saved: false,
    notifications,
    text,
  };
}

export async function saveFinding(userId: bigint, input: SaveFindingInput) {
  switch (input.kind) {
    case "device_file":
      return saveDeviceFile(userId, input.evidence_id);
    case "object":
      return saveSceneObject(userId, input);
    case "scene_area":
      return saveSceneArea(userId, input);
    case "file_area":
      return saveFileArea(userId, input);
    case "text_selection":
      return saveTextSelection(userId, input);
  }
}