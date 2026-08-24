import type { PhotoCluster } from "../../lib/photo-types";
import { readStore, writeStore } from "../../lib/server-store";

export const runtime = "nodejs";

function isLocalRequest(request: Request) {
  return ["localhost", "127.0.0.1", "[::1]"].includes(
    new URL(request.url).hostname,
  );
}

function isPhotoClusterArray(value: unknown): value is PhotoCluster[] {
  return (
    Array.isArray(value) &&
    value.every(
      (item) =>
        item &&
        typeof item === "object" &&
        typeof (item as { id?: unknown }).id === "string" &&
        Array.isArray((item as { photos?: unknown }).photos),
    )
  );
}

export async function GET(request: Request) {
  if (!isLocalRequest(request)) {
    return Response.json({ error: "This action is only available locally." }, { status: 403 });
  }
  const store = await readStore();
  return Response.json({ clusters: store.clusters });
}

export async function PUT(request: Request) {
  if (!isLocalRequest(request)) {
    return Response.json({ error: "This action is only available locally." }, { status: 403 });
  }
  const body = (await request.json()) as { clusters?: unknown };
  if (!isPhotoClusterArray(body.clusters)) {
    return Response.json({ error: "clusters must be an array" }, { status: 400 });
  }
  await writeStore({ clusters: body.clusters });
  return Response.json({ ok: true });
}
