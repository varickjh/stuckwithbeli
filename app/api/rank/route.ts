import { NextResponse } from "next/server";
import { z } from "zod";

import { existingRatingsSchema } from "../../lib/stack-schema";
import {
    cancelBeliAutomation,
    continueBeliPhotos,
    getBeliAutomationStatus,
    retryBeliAutomation,
    skipBeliPhotos,
    skipBeliAutomationStep,
    startBeliAutomation,
} from "../../lib/beli-automation";
import {
    MacWindowManagerError,
    openRankingWorkspace,
} from "../../lib/mac-window-manager";

export const runtime = "nodejs";

const rankingRequestSchema = z.object({
    clusterId: z.string().min(1),
    restaurantName: z.string().min(1),
    address: z.string(),
    rating: z.enum(["liked", "fine", "disliked"]),
    category: z.string(),
    description: z.string(),
    photoDescriptions: z.preprocess((value) => {
        if (typeof value !== "string") return value;
        try {
            return JSON.parse(value) as unknown;
        } catch {
            return value;
        }
    }, z.array(z.string().min(1))),
    visitDate: z.iso.date(),
    existingRatings: z.preprocess((value) => {
        if (typeof value !== "string") return value;
        try {
            return JSON.parse(value) as unknown;
        } catch {
            return value;
        }
    }, existingRatingsSchema.default({})),
    computedScore: z.preprocess(
        (value) => (typeof value === "string" && value ? Number(value) : value),
        z.number().min(0).max(10).nullable().default(null),
    ),
});

const retryRequestSchema = z.object({
    sessionId: z.string().uuid(),
    step: z.enum([
        "open_beli",
        "find_restaurant",
        "start_rating",
        "choose_category",
        "add_rating",
        "add_notes",
        "set_visit_date",
        "add_photos",
        "add_photo_descriptions",
        "finish_in_beli",
    ]),
    action: z.enum(["retry", "skip"]).default("retry"),
});

function isLocalRequest(request: Request) {
    return ["localhost", "127.0.0.1", "[::1]"].includes(
        new URL(request.url).hostname,
    );
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
    const session = getBeliAutomationStatus(sessionId);
    if (!session) {
        return NextResponse.json({ error: "Ranking session not found." }, { status: 404 });
    }
    return NextResponse.json(session);
}

export async function POST(request: Request) {
    try {
        if (!isLocalRequest(request)) {
            return NextResponse.json(
                { error: "This action is only available locally." },
                { status: 403 },
            );
        }

        const formData = await request.formData();
        const input = rankingRequestSchema.parse({
            clusterId: formData.get("clusterId"),
            restaurantName: formData.get("restaurantName"),
            address: formData.get("address"),
            rating: formData.get("rating"),
            category: formData.get("category"),
            description: formData.get("description"),
            photoDescriptions: formData.get("photoDescriptions"),
            visitDate: formData.get("visitDate"),
            existingRatings: formData.get("existingRatings"),
            computedScore: formData.get("computedScore"),
        });
        const photos = formData
            .getAll("photos")
            .filter((value): value is File => value instanceof File);
        if (!photos.length) {
            return NextResponse.json(
                { error: "At least one photo is required." },
                { status: 400 },
            );
        }
        if (input.photoDescriptions.length !== photos.length) {
            return NextResponse.json(
                { error: "Every photo needs a description." },
                { status: 400 },
            );
        }

        await openRankingWorkspace();
        const session = await startBeliAutomation({ ...input, photos });
        return NextResponse.json(session);
    } catch (error) {
        if (error instanceof z.ZodError) {
            return NextResponse.json(
                { error: "The ranking details are incomplete." },
                { status: 400 },
            );
        }
        if (error instanceof MacWindowManagerError) {
            return NextResponse.json(
                { code: error.code, error: error.message },
                { status: error.code === "accessibility_required" ? 409 : 500 },
            );
        }
        const message =
            error instanceof Error
                ? error.message
                : "Could not start Beli automation.";
        return NextResponse.json({ error: message }, { status: 500 });
    }
}

export async function PATCH(request: Request) {
    try {
        if (!isLocalRequest(request)) {
            return NextResponse.json(
                { error: "This action is only available locally." },
                { status: 403 },
            );
        }
        const input = retryRequestSchema.parse(await request.json());
        const session =
            input.action === "skip"
                ? await skipBeliAutomationStep(input.sessionId, input.step)
                : await retryBeliAutomation(input.sessionId, input.step);
        if (!session) {
            return NextResponse.json(
                { error: "Ranking session not found." },
                { status: 404 },
            );
        }
        return NextResponse.json(session);
    } catch (error) {
        if (error instanceof z.ZodError) {
            return NextResponse.json(
                { error: "The retry checkpoint is invalid." },
                { status: 400 },
            );
        }
        const message =
            error instanceof Error ? error.message : "Could not retry this step.";
        return NextResponse.json({ error: message }, { status: 500 });
    }
}

export async function PUT(request: Request) {
    try {
        if (!isLocalRequest(request)) {
            return NextResponse.json(
                { error: "This action is only available locally." },
                { status: 403 },
            );
        }
        const input = z
            .object({
                sessionId: z.string().uuid(),
                action: z.enum(["skip", "continue"]).default("skip"),
            })
            .parse(await request.json());
        const session =
            input.action === "continue"
                ? await continueBeliPhotos(input.sessionId)
                : await skipBeliPhotos(input.sessionId);
        if (!session) {
            return NextResponse.json(
                { error: "Photo recovery is not available from this step." },
                { status: 409 },
            );
        }
        return NextResponse.json(session);
    } catch (error) {
        if (error instanceof z.ZodError) {
            return NextResponse.json(
                { error: "The ranking session is invalid." },
                { status: 400 },
            );
        }
        const message =
            error instanceof Error ? error.message : "Could not recover photos.";
        return NextResponse.json({ error: message }, { status: 500 });
    }
}

export async function DELETE(request: Request) {
    try {
        if (!isLocalRequest(request)) {
            return NextResponse.json(
                { error: "This action is only available locally." },
                { status: 403 },
            );
        }
        const input = z
            .object({ sessionId: z.string().uuid() })
            .parse(await request.json());
        const session = await cancelBeliAutomation(input.sessionId);
        if (!session) {
            return NextResponse.json(
                { error: "Ranking session not found." },
                { status: 404 },
            );
        }
        return NextResponse.json(session);
    } catch (error) {
        if (error instanceof z.ZodError) {
            return NextResponse.json(
                { error: "The ranking session is invalid." },
                { status: 400 },
            );
        }
        return NextResponse.json(
            {
                error:
                    error instanceof Error
                        ? error.message
                        : "Could not cancel ranking.",
            },
            { status: 500 },
        );
    }
}
