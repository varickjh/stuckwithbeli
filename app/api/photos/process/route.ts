import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";
import { promisify } from "node:util";

import exifr from "exifr";

import { extensionForMediaType, mediaTypeForExtension } from "../../../lib/media-type";
import { PHOTOS_DIR, ensurePhotosDir } from "../../../lib/server-store";

export const runtime = "nodejs";
export const maxDuration = 300;

const execFileAsync = promisify(execFile);
const HEIC_EXTENSIONS = new Set([".heic", ".heif"]);
const IMAGE_EXTENSIONS = new Set([
  ".avif",
  ".bmp",
  ".gif",
  ".heic",
  ".heif",
  ".jpeg",
  ".jpg",
  ".png",
  ".tif",
  ".tiff",
  ".webp",
]);

function replaceExtension(value: string, extension: string) {
  return value.replace(/\.[^.]+$/, extension);
}

function validTimestamp(value: unknown) {
  if (!value) return null;
  const timestamp = new Date(value as string | number | Date).getTime();
  return Number.isFinite(timestamp) ? timestamp : null;
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const upload = formData.get("file");
  if (!(upload instanceof File)) {
    return Response.json({ error: "Photo is required" }, { status: 400 });
  }

  const originalName = basename(upload.name);
  const extension = extname(originalName).toLowerCase();
  if (!IMAGE_EXTENSIONS.has(extension)) {
    return Response.json({ error: "Unsupported image type" }, { status: 400 });
  }

  const originalPath = formData.get("path");
  const displayPath =
    typeof originalPath === "string" && originalPath
      ? originalPath
      : originalName;
  const lastModifiedValue = formData.get("lastModified");
  const suppliedLastModified =
    typeof lastModifiedValue === "string"
      ? Number(lastModifiedValue)
      : Number.NaN;
  const fallbackTakenAt = Number.isFinite(suppliedLastModified)
    ? suppliedLastModified
    : null;
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "auto-beli-photo-"));
  const inputPath = join(temporaryDirectory, `original${extension}`);
  const isHeic = HEIC_EXTENSIONS.has(extension);
  const outputPath = isHeic
    ? join(temporaryDirectory, "converted.jpg")
    : inputPath;

  try {
    const input = Buffer.from(await upload.arrayBuffer());
    await writeFile(inputPath, input);

    if (isHeic) {
      await execFileAsync("/usr/bin/sips", [
        "-s",
        "format",
        "jpeg",
        "-s",
        "formatOptions",
        "90",
        inputPath,
        "--out",
        outputPath,
      ]);
    }

    const output = isHeic ? await readFile(outputPath) : input;

    let takenAt: number | null = null;
    let latitude: number | null = null;
    let longitude: number | null = null;

    try {
      const metadata = await exifr.parse(output, {
        pick: ["DateTimeOriginal", "CreateDate", "ModifyDate"],
      });
      takenAt = validTimestamp(
        metadata?.DateTimeOriginal ?? metadata?.CreateDate ?? metadata?.ModifyDate,
      );
    } catch {
      // The browser file timestamp remains available as a fallback.
    }

    try {
      const gps = await exifr.gps(output);
      if (Number.isFinite(gps?.latitude)) latitude = gps.latitude;
      if (Number.isFinite(gps?.longitude)) longitude = gps.longitude;
    } catch {
      // Location is optional.
    }

    const outputName = isHeic
      ? replaceExtension(originalName, ".jpg")
      : originalName;
    const outputDisplayPath = isHeic
      ? replaceExtension(displayPath, ".jpg")
      : displayPath;
    const mediaType = isHeic
      ? "image/jpeg"
      : mediaTypeForExtension(extension, upload.type);
    const effectiveTakenAt = takenAt ?? fallbackTakenAt;

    await ensurePhotosDir();
    const storedFilename = `${crypto.randomUUID()}${extensionForMediaType(mediaType)}`;
    await writeFile(join(PHOTOS_DIR, storedFilename), output);

    console.info("[photos/process]", {
      latitude,
      longitude,
      name: originalName,
      takenAt: effectiveTakenAt
        ? new Date(effectiveTakenAt).toISOString()
        : null,
      usedFileTimestamp: takenAt === null,
    });

    return Response.json({
      data: output.toString("base64"),
      latitude,
      longitude,
      mediaType,
      name: outputName,
      path: outputDisplayPath,
      size: output.byteLength,
      takenAt: effectiveTakenAt,
      url: `/api/photos/blob/${storedFilename}`,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Photo processing failed";
    return Response.json({ error: message }, { status: 500 });
  } finally {
    await rm(temporaryDirectory, { force: true, recursive: true });
  }
}
