const EXTENSION_TO_MEDIA_TYPE: Record<string, string> = {
  ".avif": "image/avif",
  ".bmp": "image/bmp",
  ".gif": "image/gif",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".webp": "image/webp",
};

export function mediaTypeForExtension(extension: string, fallback = "") {
  return (
    EXTENSION_TO_MEDIA_TYPE[extension.toLowerCase()] ||
    fallback ||
    "application/octet-stream"
  );
}

export function extensionForMediaType(mediaType: string) {
  const match = Object.entries(EXTENSION_TO_MEDIA_TYPE).find(
    ([, value]) => value === mediaType,
  );
  return match?.[0] ?? ".jpg";
}
