import { NextResponse } from "next/server";
import { z } from "zod";

import {
    cancelRatingsExport,
    getRatingsExportStatus,
    startRatingsExport,
} from "@/app/lib/ratings-export";

export const runtime = "nodejs";

function isLocalRequest(request: Request) {
    return ["localhost", "127.0.0.1", "[::1]"].includes(
        new URL(request.url).hostname,
    );
}

export async function POST(request: Request) {
    if (!isLocalRequest(request)) {
        return NextResponse.json(
            { error: "This action is only available locally." },
            { status: 403 },
        );
    }
    try {
        const session = await startRatingsExport();
        return NextResponse.json(session);
    } catch (error) {
        const message =
            error instanceof Error ? error.message : "Could not start the export.";
        return NextResponse.json({ error: message }, { status: 500 });
    }
}

export async function GET(request: Request) {
    if (!isLocalRequest(request)) {
        return NextResponse.json(
            { error: "This action is only available locally." },
            { status: 403 },
        );
    }
    const sessionId = new URL(request.url).searchParams.get("sessionId");
    if (!sessionId) {
        return NextResponse.json({ error: "A session is required." }, { status: 400 });
    }
    const session = getRatingsExportStatus(sessionId);
    if (!session) {
        return NextResponse.json({ error: "Export session not found." }, { status: 404 });
    }
    return NextResponse.json(session);
}

export async function DELETE(request: Request) {
    if (!isLocalRequest(request)) {
        return NextResponse.json(
            { error: "This action is only available locally." },
            { status: 403 },
        );
    }
    const input = z
        .object({ sessionId: z.string().uuid() })
        .safeParse(await request.json());
    if (!input.success) {
        return NextResponse.json({ error: "A session is required." }, { status: 400 });
    }
    const session = await cancelRatingsExport(input.data.sessionId);
    if (!session) {
        return NextResponse.json({ error: "Export session not found." }, { status: 404 });
    }
    return NextResponse.json(session);
}
