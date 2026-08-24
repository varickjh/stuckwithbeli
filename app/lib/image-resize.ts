import { getPhotoBlob } from "./photo-processing";
import type { Photo } from "./photo-types";
import type { LabelPhotoInput } from "./photo-types";

const LONG_SIDE = 854;
const SHORT_SIDE = 480;
const JPEG_QUALITY = 0.72;

function canvasToBlob(canvas: HTMLCanvasElement) {
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error("Image resize failed"))),
      "image/jpeg",
      JPEG_QUALITY,
    );
  });
}

function blobToBase64(blob: Blob) {
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result;
      if (typeof result !== "string") {
        reject(new Error("Image encoding failed"));
        return;
      }
      resolve(result.slice(result.indexOf(",") + 1));
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

async function resizePhoto(photo: Photo): Promise<LabelPhotoInput> {
  const blob = await getPhotoBlob(photo);
  const bitmap = await createImageBitmap(blob, {
    imageOrientation: "from-image",
  });

  try {
    const landscape = bitmap.width >= bitmap.height;
    const maxWidth = landscape ? LONG_SIDE : SHORT_SIDE;
    const maxHeight = landscape ? SHORT_SIDE : LONG_SIDE;
    const scale = Math.min(
      1,
      maxWidth / bitmap.width,
      maxHeight / bitmap.height,
    );
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Image resize is unavailable");
    context.drawImage(bitmap, 0, 0, width, height);
    const resized = await canvasToBlob(canvas);

    return {
      id: photo.id,
      name: photo.name,
      takenAt: photo.takenAt,
      mediaType: "image/jpeg",
      data: await blobToBase64(resized),
    };
  } finally {
    bitmap.close();
  }
}

export async function resizePhotosForLabeling(photos: Photo[]) {
  const results = await Promise.allSettled(photos.map(resizePhoto));
  return results.flatMap((result) =>
    result.status === "fulfilled" ? [result.value] : [],
  );
}
