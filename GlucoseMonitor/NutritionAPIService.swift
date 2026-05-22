import Foundation

// MARK: - NutrientData (defined here so this file is self-contained)
//
// Kept in this file so the SourceKit background indexer can resolve it without
// needing ARKit or UIKit context from other files in the module.

public struct NutrientData {
    public let calories:      Double   // kcal
    public let proteinG:      Double
    public let fatG:          Double
    public let carbsG:        Double
    public let glycemicIndex: Double?  // nil for foods without a meaningful GI

    /// GL = (GI × available carbs g) / 100
    public var glycemicLoad: Double? {
        guard let gi = glycemicIndex else { return nil }
        return (gi * carbsG) / 100.0
    }

    public init(calories: Double, proteinG: Double, fatG: Double,
                carbsG: Double, glycemicIndex: Double?) {
        self.calories = calories;  self.proteinG = proteinG
        self.fatG = fatG;          self.carbsG = carbsG
        self.glycemicIndex = glycemicIndex
    }
}

// MARK: - Local Nutrition Service

/// Returns nutrition estimates for a detected food component using a built-in
/// USDA-sourced lookup table (values per 100 g, scaled by detected mass).
///
/// Covers all 154 FoodSeg154 classes.  No network call, no API key, no latency.
public final class NutritionAPIService {

    public init() {}

    // (kcal/100g, carbs g, protein g, fat g, GI or nil for non-carb foods)
    private typealias Entry = (kcal: Double, carbs: Double, protein: Double, fat: Double, gi: Double?)

    // swiftlint:disable opening_brace
    private static let table: [String: Entry] = [

        // ── Sweets & desserts ──────────────────────────────────────────────────
        "candy":               (400, 90.0,  0.0,  0.5, 70),
        "egg tart":            (280, 30.0,  7.0, 14.0, 55),
        "chocolate":           (546, 60.0,  5.0, 31.0, 40),
        "biscuit":             (450, 60.0,  7.0, 20.0, 70),
        "biscuits":            (450, 60.0,  7.0, 20.0, 70),
        "popcorn":             (375, 74.0, 11.0,  4.0, 72),
        "pudding":             (130, 23.0,  3.0,  3.0, 55),
        "ice cream":           (207, 24.0,  3.5, 11.0, 62),
        "cheese butter":       (717,  0.0,  0.9, 81.0, nil),
        "cake":                (347, 53.0,  5.0, 13.0, 55),
        "pie":                 (260, 33.0,  4.0, 12.0, 55),
        "tarts":               (280, 30.0,  7.0, 14.0, 55),
        "pineapple cake":      (320, 55.0,  4.0,  9.0, 65),

        // ── Beverages ─────────────────────────────────────────────────────────
        "wine":                ( 83,  2.6,  0.1,  0.0, nil),
        "milkshake":           (112, 18.0,  3.8,  3.0, 50),
        "coffee":              (  1,  0.0,  0.1,  0.0, nil),
        "juice":               ( 45, 11.0,  0.7,  0.2, 50),
        "milk":                ( 61,  4.8,  3.2,  3.3, 31),
        "tea":                 (  1,  0.0,  0.0,  0.0, nil),

        // ── Nuts & seeds ──────────────────────────────────────────────────────
        "almond":              (579, 22.0, 21.0, 50.0, 15),
        "red beans":           (127, 23.0,  8.0,  0.5, 24),
        "cashew":              (553, 33.0, 18.0, 44.0, 27),
        "dried cranberries":   (308, 82.0,  0.2,  1.1, 64),
        "soy":                 (173,  9.0, 17.0,  9.0, 14),
        "walnut":              (654, 14.0, 15.0, 65.0, 15),
        "peanut":              (567, 16.0, 26.0, 49.0, 14),
        "chestnut":            (245, 53.0,  3.2,  1.3, 54),

        // ── Eggs & dairy ──────────────────────────────────────────────────────
        "egg":                 (155,  1.1, 13.0, 11.0, nil),
        "cheese":              (402,  1.3, 25.0, 33.0, nil),
        "yogurt":              ( 59,  3.6,  3.5,  3.3, 36),

        // ── Fruits ────────────────────────────────────────────────────────────
        "apple":               ( 52, 14.0,  0.3,  0.2, 38),
        "date":                (277, 75.0,  1.8,  0.2, 42),
        "apricot":             ( 48, 11.0,  1.4,  0.4, 34),
        "avocado":             (160,  9.0,  2.0, 15.0, 15),
        "banana":              ( 89, 23.0,  1.1,  0.3, 51),
        "strawberry":          ( 32,  7.7,  0.7,  0.3, 40),
        "cherry":              ( 50, 12.0,  1.0,  0.3, 22),
        "blueberry":           ( 57, 14.0,  0.7,  0.3, 53),
        "raspberry":           ( 52, 12.0,  1.2,  0.7, 32),
        "mango":               ( 60, 15.0,  0.8,  0.4, 51),
        "olives":              (145,  3.8,  1.0, 15.0, 15),
        "peach":               ( 39,  9.5,  0.9,  0.3, 42),
        "lemon":               ( 29,  9.3,  1.1,  0.3, 20),
        "pear":                ( 57, 15.0,  0.4,  0.1, 38),
        "fig":                 ( 74, 19.0,  0.8,  0.3, 35),
        "pineapple":           ( 50, 13.0,  0.5,  0.1, 59),
        "grape":               ( 69, 18.0,  0.7,  0.2, 59),
        "kiwi":                ( 61, 15.0,  1.1,  0.5, 52),
        "melon":               ( 34,  8.2,  0.8,  0.2, 65),
        "orange":              ( 47, 12.0,  0.9,  0.1, 40),
        "watermelon":          ( 30,  7.6,  0.6,  0.2, 72),

        // ── Meats & seafood ───────────────────────────────────────────────────
        "steak":               (271,  0.0, 26.0, 18.0, nil),
        "pork":                (242,  0.0, 27.0, 14.0, nil),
        "chicken duck":        (200,  0.0, 25.0, 10.0, nil),
        "chicken":             (165,  0.0, 31.0,  3.6, nil),
        "sausage":             (301,  2.4, 12.0, 27.0, nil),
        "fried meat":          (280,  8.0, 22.0, 18.0, nil),
        "lamb":                (258,  0.0, 25.0, 17.0, nil),
        "crab":                ( 97,  0.0, 19.0,  1.5, nil),
        "fish":                (130,  0.0, 26.0,  2.0, nil),
        "shellfish":           ( 86,  5.0, 12.0,  1.4, nil),
        "shrimp":              ( 99,  0.2, 24.0,  0.3, nil),
        "salmon":              (208,  0.0, 20.0, 13.0, nil),
        "beef":                (250,  0.0, 26.0, 15.0, nil),

        // ── Condiments & sauces ───────────────────────────────────────────────
        "sauce":               ( 80, 10.0,  1.0,  4.0, nil),

        // ── Soups & stews ─────────────────────────────────────────────────────
        "soup":                ( 50,  6.0,  3.0,  1.5, 30),
        "stew":                (140, 10.0, 11.0,  5.0, 45),
        "curry":               (150, 12.0,  8.0,  8.0, 55),
        "porridge":            ( 71, 12.0,  2.5,  1.4, 55),

        // ── Grains, breads & baked goods ──────────────────────────────────────
        "bread":               (265, 49.0,  9.0,  3.2, 75),
        "white bread":         (265, 49.0,  9.0,  3.2, 75),
        "wheat bread":         (247, 43.0, 11.0,  3.4, 69),
        "toast":               (265, 49.0,  9.0,  3.2, 73),
        "croissant":           (406, 46.0,  8.2, 21.0, 67),
        "roll":                (271, 50.0,  8.0,  3.6, 73),
        "sandwich":            (253, 33.0, 11.0,  8.0, 62),
        "rice":                (130, 28.2,  2.7,  0.3, 72),
        "white rice":          (130, 28.2,  2.7,  0.3, 72),
        "brown rice":          (112, 23.5,  2.6,  0.9, 66),
        "pasta":               (131, 25.0,  5.0,  1.1, 49),
        "noodles pasta":       (138, 25.7,  4.5,  2.1, 52),
        "oatmeal":             ( 68, 12.0,  2.5,  1.5, 55),
        "corn":                ( 86, 19.0,  3.2,  1.2, 52),
        "pizza":               (266, 33.0, 11.0, 10.0, 60),
        "hamburg":             (295, 24.0, 17.0, 14.0, 60),
        "burger":              (295, 24.0, 17.0, 14.0, 60),
        "hanamaki baozi":      (220, 42.0,  7.0,  2.5, 65),
        "wonton dumplings":    (185, 25.0,  9.0,  5.5, 55),
        "tow":                 ( 76,  1.9,  8.0,  4.2, nil),  // tofu variant
        "spring roll":         (240, 28.0,  8.0, 10.0, 55),
        "pancake":             (227, 38.0,  6.0,  7.0, 67),
        "sushi":               (143, 28.0,  5.4,  0.7, 60),
        "french fries":        (312, 41.0,  3.4, 15.0, 63),
        "potato chips":        (536, 53.0,  7.0, 35.0, 56),

        // ── Potato & root vegetables ──────────────────────────────────────────
        "potato":              ( 77, 17.0,  2.0,  0.1, 78),
        "mashed potato":       ( 87, 18.0,  2.0,  1.0, 85),
        "sweet potato":        ( 86, 20.0,  1.6,  0.1, 61),
        "purple sweet potato": ( 86, 20.0,  1.6,  0.1, 61),
        "yam":                 (118, 28.0,  1.5,  0.2, 51),
        "taro":                (112, 26.0,  1.5,  0.2, 55),
        "carrot":              ( 41, 10.0,  0.9,  0.2, 47),
        "lotus root":          ( 74, 18.0,  1.6,  0.1, 45),
        "white radish":        ( 18,  4.0,  0.6,  0.1, 15),
        "beet":                ( 43, 10.0,  1.6,  0.2, 64),
        "chinese turnip":      ( 37,  8.6,  0.9,  0.1, 20),
        "pumpkin":             ( 26,  6.5,  1.0,  0.1, 65),
        "onion":               ( 40,  9.3,  1.1,  0.1, 10),
        "garlic":              (149, 33.0,  6.4,  0.5, 30),
        "ginger":              ( 80, 18.0,  1.8,  0.8, 15),

        // ── Other vegetables ──────────────────────────────────────────────────
        "salad":               ( 20,  3.5,  1.5,  0.2, 15),
        "eggplant":            ( 25,  5.9,  1.0,  0.2, 15),
        "tomato":              ( 18,  3.9,  0.9,  0.2, 15),
        "asparagus":           ( 20,  3.9,  2.2,  0.1, 15),
        "broccoli":            ( 34,  6.6,  2.8,  0.4, 10),
        "celery stick":        ( 14,  3.0,  0.7,  0.2, 15),
        "cilantro mint":       ( 23,  3.7,  2.1,  0.5, nil),
        "snow peas":           ( 42,  7.5,  2.8,  0.2, 22),
        "cabbage":             ( 25,  5.8,  1.3,  0.1, 10),
        "hot pepper":          ( 40,  8.8,  1.9,  0.4, 15),
        "parsley":             ( 36,  6.3,  3.0,  0.8, nil),
        "mushroom":            ( 22,  3.3,  3.1,  0.3, 15),
        "spring onion":        ( 32,  7.3,  1.8,  0.2, 15),
        "birth pea":           ( 81, 14.0,  5.0,  0.4, 22),
        "green vegetables":    ( 30,  5.0,  2.0,  0.3, 15),
        "okra":                ( 33,  7.5,  1.9,  0.2, 20),
        "bamboo shoots":       ( 27,  5.2,  2.6,  0.3, 20),
        "wild violet":         ( 30,  5.0,  2.0,  0.5, nil),
        "winter melon":        ( 13,  3.0,  0.4,  0.2, 15),
        "cucumber":            ( 15,  3.6,  0.7,  0.1, 15),
        "gourd":               ( 14,  3.4,  0.6,  0.0, 15),
        "luffa":               ( 20,  4.3,  1.2,  0.2, 15),
        "zucchini":            ( 17,  3.1,  1.2,  0.3, 15),
        "leek":                ( 61, 14.0,  1.5,  0.3, 15),
        "coriander":           ( 23,  3.7,  2.1,  0.5, nil),

        // ── Herbs (fresh-weight values) ───────────────────────────────────────
        "basil":               ( 23,  2.7,  3.2,  0.6, nil),
        "dill":                ( 43,  7.0,  3.5,  1.1, nil),
        "thyme":               (101, 24.0,  5.6,  1.7, nil),
        "rosemary":            (131, 21.0,  3.3,  5.9, nil),
        "marjoram":            ( 33,  6.9,  3.5,  0.7, nil),
        "bay leaf":            (313, 75.0,  7.6,  8.4, nil),
        "sage":                ( 58, 11.0,  2.0,  1.6, nil),
        "oregano":             ( 36,  9.0,  3.0,  0.6, nil),
        "fennel":              ( 31,  7.3,  1.2,  0.2, nil),
        "tarragon":            ( 49,  7.4,  3.7,  1.2, nil),
        "chives":              ( 30,  4.4,  3.3,  0.7, nil),
        "mint":                ( 70, 15.0,  3.8,  0.9, nil),
        "lemon grass":         ( 99, 25.0,  1.8,  0.5, nil),

        // ── Mushrooms ─────────────────────────────────────────────────────────
        "wood ear mushroom":    ( 25,  6.1,  0.5,  0.2, 15),
        "king oyster mushroom": ( 35,  6.3,  2.3,  0.4, 15),
        "shiitake":             ( 34,  6.8,  2.2,  0.5, 15),
        "enoki mushroom":       ( 37,  7.8,  2.7,  0.3, 15),
        "straw mushroom":       ( 27,  4.2,  2.8,  0.4, 15),
        "oyster mushroom":      ( 33,  6.1,  3.3,  0.4, 15),
        "button mushroom":      ( 22,  3.3,  3.1,  0.3, 15),
        "truffle":              ( 52, 13.3,  3.3,  0.5, nil),

        // ── Legumes & plant proteins ──────────────────────────────────────────
        "bean sprout":         ( 31,  5.9,  3.1,  0.2, 25),
        "mung bean":           (105, 19.0,  7.0,  0.4, 25),
        "lentil":              (116, 20.0,  9.0,  0.4, 29),
        "kidney bean":         (127, 23.0,  8.7,  0.5, 24),
        "chickpea":            (164, 27.0,  8.9,  2.6, 28),
        "fava bean":           ( 88, 15.5,  7.9,  0.5, 40),
        "tofu":                ( 76,  1.9,  8.0,  4.2, nil),
        "natto":               (211, 14.0, 17.7, 11.0, nil),
        "tempeh":              (193,  9.4, 19.0, 11.0, nil),
        "seitan":              (370, 14.0, 75.0,  2.0, nil),
        "meat analogue":       (170, 10.0, 20.0,  5.0, nil),

        // ── Generic fallback ──────────────────────────────────────────────────
        "food":                (150, 20.0,  8.0,  5.0, 50),
    ]
    // swiftlint:enable opening_brace

    // MARK: - Public API

    /// Returns nutrition data for one food component.
    ///
    /// Looks up the label in the built-in USDA table, then scales macros by mass.
    /// When no exact match is found, falls back to the longest matching substring
    /// key in the table, then to a generic 150 kcal / 100 g profile.
    ///
    /// - Parameters:
    ///   - label: Food label returned by the ML model (e.g. `"white rice"`).
    ///   - massG: Estimated cooked mass in grams (from LiDAR volume × density).
    /// - Returns: Populated `NutrientData` — never nil.
    public func fetchNutrition(label: String, massG: Double) -> NutrientData {
        let key = label.lowercased()
        let entry: Entry = Self.table[key]
            ?? Self.table
                .filter { key.contains($0.key) || $0.key.contains(key) }
                .max(by: { $0.key.count < $1.key.count })?.value
            ?? (kcal: 150, carbs: 20.0, protein: 8.0, fat: 5.0, gi: 50)
        let scale = massG / 100.0
        return NutrientData(
            calories:      entry.kcal    * scale,
            proteinG:      entry.protein * scale,
            fatG:          entry.fat     * scale,
            carbsG:        entry.carbs   * scale,
            glycemicIndex: entry.gi
        )
    }
}

// Spec alias — preserves backward compatibility with any code referencing NutritionService.
public typealias NutritionService = NutritionAPIService
