import { existingRatingsSchema } from "../../lib/stack-schema";
import { readStore, writeStore } from "../../lib/server-store";

export const runtime = "nodejs";

function isLocalRequest(request: Request) {
  return ["localhost", "127.0.0.1", "[::1]"].includes(
    new URL(request.url).hostname,
  );
}

export async function GET(request: Request) {
  if (!isLocalRequest(request)) {
    return Response.json({ error: "This action is only available locally." }, { status: 403 });
  }
  const store = await readStore();
  return Response.json({ ratingsDictionary: store.ratingsDictionary });
}

export async function PUT(request: Request) {
  if (!isLocalRequest(request)) {
    return Response.json({ error: "This action is only available locally." }, { status: 403 });
  }
  const body = (await request.json()) as {
    ratingsDictionary?: { entries?: unknown; syncedAt?: unknown };
  };
  const entriesResult = existingRatingsSchema.safeParse(
    body.ratingsDictionary?.entries,
  );
  const syncedAt = body.ratingsDictionary?.syncedAt;
  if (!entriesResult.success || typeof syncedAt !== "string") {
    return Response.json({ error: "Invalid ratings dictionary" }, { status: 400 });
  }
  await writeStore({
    ratingsDictionary: { entries: entriesResult.data, syncedAt },
  });
  return Response.json({ ok: true });
}

export async function DELETE(request: Request) {
  if (!isLocalRequest(request)) {
    return Response.json({ error: "This action is only available locally." }, { status: 403 });
  }
  await writeStore({ ratingsDictionary: null });
  return Response.json({ ok: true });
}
