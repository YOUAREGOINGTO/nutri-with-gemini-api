enum NutritionMetricType {
  calories,
  carbs,
  sugars,
  fats,
  saturatedFats,
  protein,
  fiber,
  sodium,
  caffeine,
  water,
  polyunsaturatedFat,
  calcium,
  phosphorus,
  magnesium,
  potassium,
  iron,
  zinc,
  copper,
  vitaminA,
}

const defaultHomeMetricTypes = <NutritionMetricType>[
  NutritionMetricType.carbs,
  NutritionMetricType.fats,
  NutritionMetricType.protein,
  NutritionMetricType.fiber,
  NutritionMetricType.sodium,
  NutritionMetricType.caffeine,
  NutritionMetricType.water,
];

const homeMetricSlotCount = 7;

const macroMetricTypes = <NutritionMetricType>[
  NutritionMetricType.carbs,
  NutritionMetricType.fats,
  NutritionMetricType.protein,
  NutritionMetricType.sugars,
  NutritionMetricType.saturatedFats,
  NutritionMetricType.fiber,
];

const fluidAndStimulantMetricTypes = <NutritionMetricType>[
  NutritionMetricType.water,
  NutritionMetricType.caffeine,
  NutritionMetricType.sodium,
];

const micronutrientMetricTypes = <NutritionMetricType>[
  NutritionMetricType.polyunsaturatedFat,
  NutritionMetricType.calcium,
  NutritionMetricType.phosphorus,
  NutritionMetricType.magnesium,
  NutritionMetricType.potassium,
  NutritionMetricType.iron,
  NutritionMetricType.zinc,
  NutritionMetricType.copper,
  NutritionMetricType.vitaminA,
];

List<NutritionMetricType> normalizeHomeMetricTypes(
  Iterable<NutritionMetricType> values, {
  int slotCount = homeMetricSlotCount,
}) {
  final normalized = <NutritionMetricType>[];
  for (final value in values) {
    if (value == NutritionMetricType.calories || normalized.contains(value)) {
      continue;
    }
    normalized.add(value);
  }

  for (final fallback in defaultHomeMetricTypes) {
    if (!normalized.contains(fallback)) {
      normalized.add(fallback);
    }
  }

  return normalized.take(slotCount).toList(growable: false);
}

List<NutritionMetricType> parseHomeMetricTypes(
  String raw, {
  int slotCount = homeMetricSlotCount,
}) {
  return normalizeHomeMetricTypes(
    raw
        .split(',')
        .map((part) => NutritionMetricTypeX.fromKey(part.trim()))
        .whereType<NutritionMetricType>(),
    slotCount: slotCount,
  );
}

String serializeHomeMetricTypes(
  Iterable<NutritionMetricType> values, {
  int slotCount = homeMetricSlotCount,
}) {
  return normalizeHomeMetricTypes(
    values,
    slotCount: slotCount,
  ).map((metric) => metric.key).join(',');
}

extension NutritionMetricTypeX on NutritionMetricType {
  String get key {
    switch (this) {
      case NutritionMetricType.calories:
        return 'calories';
      case NutritionMetricType.carbs:
        return 'carbs';
      case NutritionMetricType.sugars:
        return 'sugars';
      case NutritionMetricType.fats:
        return 'fats';
      case NutritionMetricType.saturatedFats:
        return 'saturated_fats';
      case NutritionMetricType.protein:
        return 'protein';
      case NutritionMetricType.fiber:
        return 'fiber';
      case NutritionMetricType.sodium:
        return 'sodium';
      case NutritionMetricType.caffeine:
        return 'caffeine';
      case NutritionMetricType.water:
        return 'water';
      case NutritionMetricType.polyunsaturatedFat:
        return 'polyunsaturated_fat';
      case NutritionMetricType.calcium:
        return 'calcium';
      case NutritionMetricType.phosphorus:
        return 'phosphorus';
      case NutritionMetricType.magnesium:
        return 'magnesium';
      case NutritionMetricType.potassium:
        return 'potassium';
      case NutritionMetricType.iron:
        return 'iron';
      case NutritionMetricType.zinc:
        return 'zinc';
      case NutritionMetricType.copper:
        return 'copper';
      case NutritionMetricType.vitaminA:
        return 'vitamin_a';
    }
  }

  String get label {
    switch (this) {
      case NutritionMetricType.calories:
        return 'Calories';
      case NutritionMetricType.carbs:
        return 'Carbs';
      case NutritionMetricType.sugars:
        return 'Sugars';
      case NutritionMetricType.fats:
        return 'Fats';
      case NutritionMetricType.saturatedFats:
        return 'Saturated Fats';
      case NutritionMetricType.protein:
        return 'Protein';
      case NutritionMetricType.fiber:
        return 'Fiber';
      case NutritionMetricType.sodium:
        return 'Sodium';
      case NutritionMetricType.caffeine:
        return 'Caffeine';
      case NutritionMetricType.water:
        return 'Water';
      case NutritionMetricType.polyunsaturatedFat:
        return 'PUFA';
      case NutritionMetricType.calcium:
        return 'Calcium';
      case NutritionMetricType.phosphorus:
        return 'Phosphorus';
      case NutritionMetricType.magnesium:
        return 'Magnesium';
      case NutritionMetricType.potassium:
        return 'Potassium';
      case NutritionMetricType.iron:
        return 'Iron';
      case NutritionMetricType.zinc:
        return 'Zinc';
      case NutritionMetricType.copper:
        return 'Copper';
      case NutritionMetricType.vitaminA:
        return 'Vitamin A';
    }
  }

  String get unit {
    switch (this) {
      case NutritionMetricType.calories:
        return 'kcal';
      case NutritionMetricType.sodium:
      case NutritionMetricType.caffeine:
      case NutritionMetricType.calcium:
      case NutritionMetricType.phosphorus:
      case NutritionMetricType.magnesium:
      case NutritionMetricType.potassium:
      case NutritionMetricType.iron:
      case NutritionMetricType.zinc:
      case NutritionMetricType.copper:
        return 'mg';
      case NutritionMetricType.water:
        return 'ml';
      case NutritionMetricType.vitaminA:
        return 'mcg RAE';
      default:
        return 'g';
    }
  }

  bool get blankWhenMissing {
    switch (this) {
      case NutritionMetricType.polyunsaturatedFat:
      case NutritionMetricType.calcium:
      case NutritionMetricType.phosphorus:
      case NutritionMetricType.magnesium:
      case NutritionMetricType.potassium:
      case NutritionMetricType.iron:
      case NutritionMetricType.zinc:
      case NutritionMetricType.copper:
      case NutritionMetricType.vitaminA:
        return true;
      case NutritionMetricType.calories:
      case NutritionMetricType.carbs:
      case NutritionMetricType.sugars:
      case NutritionMetricType.fats:
      case NutritionMetricType.saturatedFats:
      case NutritionMetricType.protein:
      case NutritionMetricType.fiber:
      case NutritionMetricType.sodium:
      case NutritionMetricType.caffeine:
      case NutritionMetricType.water:
        return false;
    }
  }

  static NutritionMetricType? fromKey(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    switch (normalized) {
      case 'calories':
      case 'kcal':
        return NutritionMetricType.calories;
      case 'carbs':
      case 'carb':
        return NutritionMetricType.carbs;
      case 'sugars':
      case 'sugar':
        return NutritionMetricType.sugars;
      case 'fats':
      case 'fat':
        return NutritionMetricType.fats;
      case 'saturated_fats':
      case 'saturatedfat':
      case 'saturated_fat':
      case 'saturatedfats':
        return NutritionMetricType.saturatedFats;
      case 'protein':
        return NutritionMetricType.protein;
      case 'fiber':
      case 'fibre':
        return NutritionMetricType.fiber;
      case 'sodium':
        return NutritionMetricType.sodium;
      case 'caffeine':
        return NutritionMetricType.caffeine;
      case 'water':
        return NutritionMetricType.water;
      case 'polyunsaturated_fat':
      case 'polyunsaturated_fat_g':
      case 'pufa':
      case 'pufa_g':
        return NutritionMetricType.polyunsaturatedFat;
      case 'calcium':
      case 'calcium_mg':
        return NutritionMetricType.calcium;
      case 'phosphorus':
      case 'phosphorous':
      case 'phosphorus_mg':
      case 'phosphorous_mg':
        return NutritionMetricType.phosphorus;
      case 'magnesium':
      case 'magnesium_mg':
        return NutritionMetricType.magnesium;
      case 'potassium':
      case 'potassium_mg':
        return NutritionMetricType.potassium;
      case 'iron':
      case 'iron_mg':
        return NutritionMetricType.iron;
      case 'zinc':
      case 'zinc_mg':
        return NutritionMetricType.zinc;
      case 'copper':
      case 'copper_mg':
        return NutritionMetricType.copper;
      case 'vitamin_a':
      case 'vitamina':
      case 'vitamin_a_mcg_rae':
        return NutritionMetricType.vitaminA;
      default:
        return null;
    }
  }
}
