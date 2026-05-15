// FoodDensityDatabase.swift
// Lookup table: food label → density in g/cm³.
//
// Sources:
//   - USDA FoodData Central average bulk densities
//   - Pańkowska et al. (Warsaw Method) fat/protein exchange unit references
//   - Standard culinary engineering values (Barbosa-Canovas 2005)
//
// Usage:
//   let d = FoodDensityDatabase.density(for: "гречка")  // → 0.80

public struct FoodDensityDatabase {

    // MARK: - Density table (g/cm³)

    private static let table: [String: Double] = [

        // ── Cooked grains & porridges ────────────────────────────────────
        "гречка":           0.80,   // buckwheat, cooked
        "buckwheat":        0.80,
        "рис":              0.85,   // white rice, cooked
        "rice":             0.85,
        "коричневый рис":   0.83,
        "brown rice":       0.83,
        "перловка":         0.82,   // pearl barley, cooked
        "barley":           0.82,
        "овсянка":          0.55,   // oatmeal / porridge (airy)
        "oatmeal":          0.55,
        "porridge":         0.55,
        "макароны":         0.80,   // pasta, cooked
        "pasta":            0.80,
        "спагетти":         0.80,
        "манка":            0.60,   // semolina porridge
        "semolina":         0.60,
        "лапша":            0.75,

        // ── Bread & baked goods ──────────────────────────────────────────
        "хлеб":             0.32,   // white bread (airy crumb)
        "bread":            0.32,
        "ржаной хлеб":      0.38,
        "rye bread":        0.38,
        "булка":            0.28,
        "блин":             0.55,   // pancake/crepe
        "pancake":          0.55,

        // ── Meat & poultry ───────────────────────────────────────────────
        "котлета":          1.05,   // pan-fried meat patty
        "meatball":         1.05,
        "steak":            1.05,
        "говядина":         1.05,   // beef, cooked
        "beef":             1.05,
        "свинина":          1.02,   // pork, cooked
        "pork":             1.02,
        "курица":           1.00,   // chicken breast, cooked
        "chicken":          1.00,
        "turkey":           1.00,
        "индейка":          1.00,
        "сосиска":          1.03,   // sausage / frankfurter
        "sausage":          1.03,
        "bacon":            0.95,
        "бекон":            0.95,
        "печень":           1.05,   // liver

        // ── Fish & seafood ───────────────────────────────────────────────
        "рыба":             1.00,
        "fish":             1.00,
        "salmon":           1.00,
        "лосось":           1.00,
        "тунец":            1.00,
        "tuna":             1.00,
        "сельдь":           1.02,   // herring
        "shrimp":           0.98,
        "креветки":         0.98,

        // ── Eggs & dairy ─────────────────────────────────────────────────
        "яйцо":             1.03,   // whole egg, poached/boiled
        "egg":              1.03,
        "омлет":            0.90,   // omelette (air incorporated)
        "omelette":         0.90,
        "творог":           0.80,   // cottage cheese / quark
        "cottage cheese":   0.80,
        "сыр":              1.10,   // hard cheese
        "cheese":           1.10,
        "молоко":           1.03,
        "milk":             1.03,
        "сметана":          1.00,   // sour cream
        "сливки":           1.00,
        "йогурт":           1.05,
        "yoghurt":          1.05,
        "yogurt":           1.05,

        // ── Vegetables & legumes ─────────────────────────────────────────
        "картофель":        0.90,   // boiled potato
        "potato":           0.90,
        "батат":            0.85,
        "sweet potato":     0.85,
        "морковь":          0.60,   // cooked carrot (slightly less dense due to water loss)
        "carrot":           0.60,
        "капуста":          0.50,   // shredded/cooked cabbage
        "cabbage":          0.50,
        "брокколи":         0.37,   // cooked broccoli (lots of air)
        "broccoli":         0.37,
        "чечевица":         0.95,   // lentils, cooked
        "lentils":          0.95,
        "фасоль":           0.95,   // beans, cooked
        "beans":            0.95,
        "горох":            0.85,   // peas, cooked
        "peas":             0.85,
        "нут":              0.95,
        "chickpeas":        0.95,
        "tоfu":             1.00,
        "tofu":             1.00,

        // ── Soups & liquids (bowl fullness path) ─────────────────────────
        "суп":              1.02,
        "soup":             1.02,
        "борщ":             1.02,
        "borsch":           1.02,
        "щи":               1.01,
        "бульон":           1.00,
        "broth":            1.00,
        "stew":             1.05,

        // ── Fruits ───────────────────────────────────────────────────────
        "яблоко":           0.56,   // whole apple (bulk, with core/air)
        "apple":            0.56,
        "банан":            0.94,   // peeled banana
        "banana":           0.94,
        "апельсин":         0.60,
        "orange":           0.60,
        "виноград":         0.67,
        "grapes":           0.67,

        // ── Fats & sauces ────────────────────────────────────────────────
        "масло":            0.91,   // butter/oil
        "butter":           0.91,
        "oil":              0.92,
        "авокадо":          0.80,
        "avocado":          0.80,
        "майонез":          0.91,
        "mayonnaise":       0.91,
        "кетчуп":           1.10,
        "ketchup":          1.10,

        // ── Nuts & seeds ─────────────────────────────────────────────────
        "орехи":            0.60,
        "nuts":             0.60,
        "миндаль":          0.60,
        "almond":           0.60,
        "грецкий орех":     0.55,
        "walnut":           0.55,
        "кешью":            0.60,
        "cashew":           0.60,
        "арахис":           0.60,
        "peanut":           0.60,
        "семечки":          0.55,
        "seeds":            0.55,
    ]

    // MARK: - Public API

    /// Returns the density (g/cm³) for the given food label.
    /// Performs case-insensitive substring matching for flexibility.
    /// Falls back to `defaultDensity` if no match found.
    public static func density(for label: String) -> Double {
        let lower = label.lowercased()

        // Exact match first (fast path)
        if let d = table[lower] { return d }

        // Substring match: return first entry whose key appears in the label
        for (key, density) in table where lower.contains(key) || key.contains(lower) {
            return density
        }

        return defaultDensity
    }

    /// Generic fallback density used when the food is unrecognised.
    /// 0.85 g/cm³ is close to the mean cooked-food density across vegetables,
    /// grains, and lean protein (Barbosa-Canovas 2005).
    public static let defaultDensity: Double = 0.85

    /// All recognised food labels (for UI autocomplete / debugging)
    public static var allLabels: [String] { Array(table.keys).sorted() }
}
