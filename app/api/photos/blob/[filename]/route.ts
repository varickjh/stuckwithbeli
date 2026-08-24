import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";

import { mediaTypeForExtension } from "../../../../lib/media-type";
import { PHOTOS_DIR } from "../../../../lib/server-store";

export const runtime = "nodejs";

const SAFE_FILENAME = /^[a-f0-9-]+\.[a-z0-9]+$/i;

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ filename: string }> },
) {
  const { filename } = await params;
  if (!SAFE_FILENAME.test(filename)) {
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  try {
    const bytes = await readFile(join(PHOTOS_DIR, filename));
    return new Response(new Uint8Array(bytes), {
      headers: {
        "Content-Type": mediaTypeForExtension(extname(filename)),
        "Cache-Control": "public, max-age=31536000, immutable",
      },
    });
  } catch {
    return Response.json({ error: "Not found" }, { status: 404 });
  }
}
