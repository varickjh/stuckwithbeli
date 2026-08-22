export const RANKING_STEPS = [
    { id: "open_beli", label: "Open Beli" },
    { id: "find_restaurant", label: "Find restaurant" },
    { id: "start_rating", label: "Start rating" },
    { id: "choose_category", label: "Choose category" },
    { id: "add_rating", label: "Add rating" },
    { id: "add_notes", label: "Add notes" },
    { id: "set_visit_date", label: "Set visit date" },
    { id: "add_photos", label: "Find photos" },
    { id: "add_photo_descriptions", label: "Add photo descriptions" },
    { id: "finish_in_beli", label: "Finish in Beli" },
] as const;

export type RankingStepId = (typeof RANKING_STEPS)[number]["id"];
export type RankingStepState = "pending" | "active" | "complete";

export type DuelLogEntry = {
    message: string;
};

export type RankingSessionStatus = {
    id: string;
    clusterId: string;
    state: "running" | "paused" | "cancelled" | "complete" | "error";
    celebrating: boolean;
    steps: Record<RankingStepId, RankingStepState>;
    error: string | null;
    recovery: "photos_not_found" | null;
    duelLog: DuelLogEntry[];
};
