"use client";

import type {
    PlaceCandidate,
    RestaurantSelection,
} from "../lib/stack-schema";

const CUSTOM_LOCATION_VALUE = "__custom_location__";
const CURRENT_CUSTOM_LOCATION_VALUE = "__current_custom_location__";

type PlaceComboboxProps = {
    candidates: PlaceCandidate[];
    selection: RestaurantSelection | null;
    onSelect: (selection: RestaurantSelection) => void;
};

export function PlaceCombobox({
    candidates,
    selection,
    onSelect,
}: PlaceComboboxProps) {
    if (!selection && !candidates.length) return null;

    const selectedCandidate = candidates.find(
        (candidate) => candidate.placeId === selection?.placeId,
    );
    const selectedValue = selectedCandidate?.placeId ??
        (selection ? CURRENT_CUSTOM_LOCATION_VALUE : "");

    const chooseLocation = (value: string) => {
        if (value === CUSTOM_LOCATION_VALUE) {
            const name = window.prompt("Location name", selection?.name ?? "")?.trim();
            if (name) onSelect({ placeId: null, name, source: "user" });
            return;
        }

        const candidate = candidates.find((item) => item.placeId === value);
        if (!candidate) return;

        onSelect({
            placeId: candidate.placeId,
            name: candidate.name,
            source: "model",
        });
    };

    return (
        <select
            className="w-full min-w-0 appearance-none bg-transparent font-serif text-[clamp(20px,1.6vw,26px)] font-bold leading-tight text-accent-dark outline-none focus:outline-none"
            aria-label="Location"
            value={selectedValue}
            onChange={(event) => chooseLocation(event.target.value)}
        >
            {!selection ? <option value="">Choose location</option> : null}
            {selection && !selectedCandidate ? (
                <option value={CURRENT_CUSTOM_LOCATION_VALUE}>{selection.name}</option>
            ) : null}
            {candidates.map((candidate) => (
                <option key={candidate.placeId} value={candidate.placeId}>
                    {candidate.name}
                </option>
            ))}
            <option value={CUSTOM_LOCATION_VALUE}>Other location…</option>
        </select>
    );
}
