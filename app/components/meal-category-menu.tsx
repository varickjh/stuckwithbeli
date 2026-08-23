"use client";

import type { IconType } from "react-icons";
import {
    FaBreadSlice,
    FaIceCream,
    FaMartiniGlass,
    FaMugHot,
    FaUtensils,
} from "react-icons/fa6";

import {
    MEAL_CATEGORIES,
    type MealCategory,
} from "../lib/stack-schema";

const CATEGORY_ICONS: Record<MealCategory, IconType> = {
    Restaurant: FaUtensils,
    Bar: FaMartiniGlass,
    "Coffee/Tea": FaMugHot,
    Bakery: FaBreadSlice,
    "Dessert/Ice Cream": FaIceCream,
};

type MealCategoryMenuProps = {
    value: MealCategory;
    onChange: (category: MealCategory) => void;
};

export function MealCategoryMenu({
    value,
    onChange,
}: MealCategoryMenuProps) {
    const CategoryIcon = CATEGORY_ICONS[value];

    return (
        <div className="flex w-fit min-w-0 items-center gap-1.5 rounded-full bg-white px-3 py-1.5 text-ink justify-center">
            <CategoryIcon className="size-3.5 shrink-0 text-accent" aria-hidden="true" />
            <select
                className="min-w-0 field-sizing-content w-fit appearance-none inline-block bg-transparent font-sans text-xs font-semibold text-ink outline-none focus:outline-none"
                aria-label="Location type"
                value={value}
                onChange={(event) => onChange(event.target.value as MealCategory)}
            >
                {MEAL_CATEGORIES.map((category) => (
                    <option key={category} value={category}>
                        {category}
                    </option>
                ))}
            </select>
        </div>
    );
}
