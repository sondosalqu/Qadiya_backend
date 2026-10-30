import { prisma } from "../lib/prisma.js";
import { HttpError } from "../utils/HttpError.js";
import { toPublicUrl } from "./storage.service.js";
import type { InspectInput } from "../validators/scene.validator.js";


const MAX_TOLERANCE = 0.03;

// أشياء بالمسرح بتفتح نافذة، حسب أول الكود تبع الـclue:
//   DEV-  جهاز (فلاشة، لابتوب...)  ← ملفات
//   DOC-  ورقة                     ← صفحات
//   BOOK- كتاب                     ← صفحات (صفحتين جنب بعض)
// المحتوى = evidence_items الـcollected_location تبعها = نفس الكود
export type ContainerKind = "device" | "document" | "book";

export function containerKind(code: string | null | undefined): ContainerKind | null {
  if (!code) return null;
  if (code.startsWith("DEV-")) return "device";
  if (code.startsWith("DOC-")) return "document";
  if (code.startsWith("BOOK-")) return "book";
  return null;
}

export type Box = { x: number; y: number; w: number; h: number };



export async function getPlayerProgress(userId: bigint, caseId: bigint) {
  const progress = await prisma.case_progress.findUnique({
    where: { case_id_user_id: { case_id: caseId, user_id: userId } },
  });
  if (!progress) {
    throw new HttpError(403, "Start this case before opening its scenes", "CASE_NOT_STARTED");
  }
  return progress;
}


export async function loadSceneForPlayer(userId: bigint, sceneId: bigint) {
  const scene = await prisma.crime_scenes.findUnique({ where: { scene_id: sceneId } });
  if (!scene) throw new HttpError(404, "Scene not found", "SCENE_NOT_FOUND");

  const progress = await getPlayerProgress(userId, scene.case_id);

  if (scene.is_hidden_initially) {
    const unlocked = await prisma.progress_unlocks.findFirst({
      where: {
        progress_id: progress.progress_id,
        unlock_rules: { unlock_scene_id: scene.scene_id },
      },
    });
    if (!unlocked) throw new HttpError(404, "Scene not found", "SCENE_NOT_FOUND");
  }

  return { scene, progress };
}


export function splitDetails(text: string | null) {
  if (!text) return { title: null, details: null };
  const i = text.indexOf(". ");
  if (i === -1) return { title: null, details: text };
  return { title: text.slice(0, i), details: text.slice(i + 2) };
}

export async function findRegionAt(sceneId: bigint, x: number, y: number, tolerance: number) {
  const pad = Math.min(tolerance, MAX_TOLERANCE);

  const regions = await prisma.image_regions.findMany({
    where: { scene_id: sceneId, region_type: { in: ["area", "object"] } },
    include: { clues: true },
  });

  const hits = regions
    .map((r) => ({ r, x: r.x.toNumber(), y: r.y.toNumber(), w: r.w.toNumber(), h: r.h.toNumber() }))
    .filter((b) => {
      const p = b.r.region_type === "object" ? pad : 0; // الهامش بس للمخفي
      return x >= b.x - p && x <= b.x + b.w + p && y >= b.y - p && y <= b.y + b.h + p;
    })
    .sort((a, b) => a.w * a.h - b.w * b.h);

  return hits[0]?.r ?? null;
}


export function iou(a: Box, b: Box) {
  const left = Math.max(a.x, b.x);
  const top = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.w, b.x + b.w);
  const bottom = Math.min(a.y + a.h, b.y + b.h);
  if (right <= left || bottom <= top) return 0;
  const inter = (right - left) * (bottom - top);
  return inter / (a.w * a.h + b.w * b.h - inter);
}

export async function matchRegion(where: { scene_id: bigint } | { evidence_id: bigint }, sel: Box) {
  const regions = await prisma.image_regions.findMany({ where });

  let best: (typeof regions)[number] | null = null;
  let bestScore = 0;
  for (const r of regions) {
    const score = iou(sel, { x: r.x.toNumber(), y: r.y.toNumber(), w: r.w.toNumber(), h: r.h.toNumber() });
    if (score >= r.min_overlap.toNumber() && score > bestScore) {
      best = r;
      bestScore = score;
    }
  }
  return best;
}


export async function unlockByClue(progressId: bigint, caseId: bigint, clueId: bigint) {
  const rules = await prisma.unlock_rules.findMany({
    where: { case_id: caseId, trigger_type: "clue_found", trigger_clue_id: clueId },
    select: { rule_id: true, notify_message: true },
  });
  if (rules.length === 0) return [];

  const already = await prisma.progress_unlocks.findMany({
    where: { progress_id: progressId, rule_id: { in: rules.map((r) => r.rule_id) } },
    select: { rule_id: true },
  });
  const done = new Set(already.map((a) => a.rule_id.toString()));
  const fresh = rules.filter((r) => !done.has(r.rule_id.toString()));
  if (fresh.length === 0) return [];

  await prisma.progress_unlocks.createMany({
    data: fresh.map((rule) => ({ progress_id: progressId, rule_id: rule.rule_id })),
    skipDuplicates: true,
  });

  return fresh.map((r) => r.notify_message).filter((m): m is string => !!m);
}



export async function getScene(userId: bigint, sceneId: bigint) {
  const { scene } = await loadSceneForPlayer(userId, sceneId);

  const regions = await prisma.image_regions.findMany({
    where: { scene_id: scene.scene_id, region_type: "area" },
    select: { region_id: true, x: true, y: true, w: true, h: true },
    orderBy: { region_id: "asc" },
  });

  return {
    scene: {
      scene_id: scene.scene_id.toString(),
      title: scene.title,
      description: scene.description,
      image_url: toPublicUrl(scene.image_url),
      image_width: scene.image_width,
      image_height: scene.image_height,
    },
    objects: regions.map((r) => ({
      region_id: r.region_id.toString(),
      x: r.x.toNumber(),
      y: r.y.toNumber(),
      w: r.w.toNumber(),
      h: r.h.toNumber(),
    })),
  };
}

export async function inspectPoint(userId: bigint, sceneId: bigint, input: InspectInput) {
  const { scene, progress } = await loadSceneForPlayer(userId, sceneId);

  const hit = await findRegionAt(scene.scene_id, input.x, input.y, input.tolerance);
  if (!hit) return { type: "nothing" as const };

  const { title, details } = splitDetails(hit.observed_details);
  const base = { region_id: hit.region_id.toString(), title, details };

  const clue = hit.clues;
  const kind = containerKind(clue?.code);
  if (!clue || !kind) {
    return { type: "object" as const, ...base };
  }

  // فتحه = لقاه: بيكشف أي إشي مربوط فيه
  const notifications = await unlockByClue(progress.progress_id, scene.case_id, clue.clue_id);
  const files = await getContainerFiles(progress.progress_id, scene.case_id, clue.code);

  if (kind !== "device") {
    return {
      type: "document" as const,
      ...base,
      document: {
        document_id: clue.clue_id.toString(),
        kind: kind === "book" ? ("book" as const) : ("note" as const),
        title: clue.title,
        pages: files
          .filter((f) => f.file_url && ["image", "document"].includes(f.type))
          .map((f, i) => ({ evidence_id: f.evidence_id, page: i + 1, name: f.name, image_url: f.file_url })),
      },
      notifications,
    };
  }

  return {
    type: "device" as const,
    ...base,
    device: {
      device_id: clue.clue_id.toString(),
      kind: clue.code.split("-")[1],
      label: clue.description ?? clue.title,
      files,
    },
    notifications,
  };
}


// ملفات جهاز أو صفحات ورقة/كتاب: الظاهرة من الأول + اللي انكشفت لهاللاعب
async function getContainerFiles(progressId: bigint, caseId: bigint, containerCode: string) {
  const files = await prisma.evidence_items.findMany({
    where: {
      case_id: caseId,
      origin_type: "police",
      collected_location: containerCode,
      OR: [
        { is_hidden_initially: false },
        { unlock_rules: { some: { progress_unlocks: { some: { progress_id: progressId } } } } },
      ],
    },
    select: {
      evidence_id: true, title: true, media_type: true,
      file_url: true, thumbnail_url: true, collected_at: true,
    },
    orderBy: [{ display_order: "asc" }, { title: "asc" }],
  });

  return files.map((f) => ({
    evidence_id: f.evidence_id.toString(),
    name: f.title,
    type: f.media_type,
    file_url: toPublicUrl(f.file_url),
    thumbnail_url: toPublicUrl(f.thumbnail_url),
    modified_at: f.collected_at?.toISOString() ?? null,
  }));
}