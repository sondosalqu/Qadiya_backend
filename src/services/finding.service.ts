import { prisma } from "../lib/prisma.js";
import { HttpError } from "../utils/HttpError.js";
import {
  findRegionAt,
  getPlayerProgress,
  loadSceneForPlayer,
  matchRegion,
  splitDetails,
  unlockByClue,
} from "./scene.service.js";
import { cropImage, padBox, type Box } from "./ai.service.js";
import { readFileFromUrl, saveFile } from "./storage.service.js";
import type { SaveFindingInput } from "../validators/finding.validator.js";


type NewFinding = {
  progressId: bigint;
  caseId: bigint;
  title: string;
  description: string | null;
  mediaType: string;
  fileUrl: string | null;
  thumbnailUrl: string | null;
  createdVia: "manual" | "scene_selection";
  srcEvidenceId?: bigint;
  srcSceneId?: bigint;
  sel?: Box;
  cropUrl?: string;
  matchedRegionId?: bigint;
  clueId?: bigint;
};


async function createFinding(f: NewFinding) {
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
        crop_url: f.cropUrl,
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


async function loadDeviceFileForPlayer(userId: bigint, evidenceId: bigint) {
  const file = await prisma.evidence_items.findUnique({ where: { evidence_id: evidenceId } });
  if (!file || file.origin_type !== "police" || !file.collected_location?.startsWith("DEV-")) {
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

function cleanSelection(s: Box): Box {
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

async function cropAndStore(imageUrl: string, box: Box) {
  const image = await readFileFromUrl(imageUrl);
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
      image_url: file.file_url,
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
    image_url: file.file_url,
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
      image_url: existing.crop_url,
      already_saved: true,
      notifications: [] as string[],
    };
  }

  const cropUrl = await cropAndStore(
    scene.image_url,
    padBox({ x: region.x.toNumber(), y: region.y.toNumber(), w: region.w.toNumber(), h: region.h.toNumber() }),
  );

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: scene.case_id,
    title: name,
    description: details,
    mediaType: "object",
    fileUrl: cropUrl,
    thumbnailUrl: cropUrl,
    createdVia: "scene_selection",
    srcSceneId: scene.scene_id,
    cropUrl,
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
    image_url: cropUrl,
    already_saved: false,
    notifications,
  };
}

async function saveSceneArea(userId: bigint, input: { scene_id: bigint } & Box) {
  const sel = cleanSelection(input);
  const { scene, progress } = await loadSceneForPlayer(userId, input.scene_id);

  const match = await matchRegion({ scene_id: scene.scene_id }, sel);

  const cropUrl = await cropAndStore(scene.image_url, sel);

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: scene.case_id,
    title: "Scene selection", 
    description: null,
    mediaType: "image",
    fileUrl: cropUrl,
    thumbnailUrl: cropUrl,
    createdVia: "scene_selection",
    srcSceneId: scene.scene_id,
    sel,
    cropUrl,
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
    image_url: cropUrl,
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

  const cropUrl = await cropAndStore(file.file_url, sel);
  const title = `Selection · ${file.title}`;

  const created = await createFinding({
    progressId: progress.progress_id,
    caseId: file.case_id,
    title,
    description: null,
    mediaType: "image",
    fileUrl: cropUrl,
    thumbnailUrl: cropUrl,
    createdVia: "manual",
    srcEvidenceId: file.evidence_id,
    sel,
    cropUrl,
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
    image_url: cropUrl,
    already_saved: false,
    notifications,
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
  }
}