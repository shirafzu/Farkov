# Climate System

## Overview

The climate system calculates climate data for each point on the planet based on solar insolation, implementing seasonal variations through orbital mechanics. The system is designed with extensibility for future river/lake generation and character distribution features.

## Architecture

### Hybrid Approach
- **Static Data**: Baked to 2048x1024 Equirectangular texture at world generation
- **Dynamic Calculation**: Real-time temperature updates via shader uniforms

### Files
| File | Purpose |
|------|---------|
| `scripts/ClimateMapBaker.gd` | Bakes climate data to texture |
| `shaders/planet_surface.gdshader` | Dynamic temperature & biome rendering |
| `scripts/WorldGenerator.gd` | Integration & API |

## Climate Texture Format

**Resolution**: 2048 x 1024 (Equirectangular projection)
**Format**: RGBA8 (~8MB)

| Channel | Data | Range | Description |
|---------|------|-------|-------------|
| R | Annual Insolation | 0.0 - 1.0 | Yearly sun exposure based on latitude and axial tilt |
| G | Precipitation | 0.0 - 1.0 | Rainfall potential (Hadley Cell model + orographic effects) |
| B | Thermal Inertia | 0.0 - 1.0 | Temperature change rate (ocean: 0.75-1.0, land: 0.1-0.6) |
| A | Terrain Mask | encoded | Terrain type + coastal flag |

### Terrain Mask Encoding
```
bits 0-1: Terrain type
  0 = Deep ocean (depth > 0.08)
  1 = Shallow water
  2 = Lowland (elevation < 0.15)
  3 = Highland/Mountain

bit 2: Coastal flag (within 0.04 of sea level)
bits 3-7: Reserved (rivers, lakes, special features)
```

## Precipitation Model

Based on simplified Hadley Cell atmospheric circulation:

| Latitude Zone | Description | Base Precipitation |
|---------------|-------------|-------------------|
| 0-15 deg | ITCZ (Intertropical Convergence Zone) | High (0.8-0.9) |
| 15-35 deg | Subtropical High | Low (0.2-0.8) |
| 35-60 deg | Temperate (Westerlies) | Moderate (0.2-0.7) |
| 60-90 deg | Polar | Low (0.2-0.7) |

Additional factors:
- **Orographic precipitation**: Mountains increase rainfall on windward side
- **Water proximity**: Ocean areas contribute moisture
- **Local variation**: Noise-based variation for natural patterns

## Dynamic Temperature Calculation

### Shader Uniforms (updated each frame)
```glsl
uniform vec3 sun_direction;      // Current sun direction vector
uniform float season_factor;     // -1.0 (winter) to 1.0 (summer)
uniform float axial_tilt_rad;    // Axial tilt in radians
```

### Temperature Formula
```
final_temp = base_insolation + seasonal_offset + diurnal_offset

seasonal_offset = sin(tilt) * season * hemisphere_sign * lat_factor * 0.35
diurnal_offset = (current_sun - 0.3) * (1.0 - thermal_inertia) * 0.15
```

- **Seasonal**: Northern hemisphere warms in summer (positive season_factor)
- **Diurnal**: Day/night variation, dampened by thermal inertia
- **Thermal Inertia**: Ocean temperature changes slowly; desert changes rapidly

## Biome System

Enhanced biome determination using dynamic temperature:

| Biome | Temperature | Moisture | Elevation |
|-------|-------------|----------|-----------|
| Ice | < 0.15 | any | high |
| Snow | < 0.28 | any | any |
| Tundra | 0.15-0.35 | dry | any |
| Cold Forest | 0.15-0.35 | wet | low |
| Temperate | 0.35-0.58 | moderate | any |
| Desert | > 0.58 | dry | any |
| Savanna | > 0.58 | moderate | any |
| Tropical | > 0.58 | wet | any |
| Beach | any (not cold) | any | sea level |

Ocean variations:
- Deep ocean: darker blue
- Shallow water: lighter blue-green
- Cold water: blue-green tint
- Warm water: blue-purple tint
- Polar ice: white overlay

## API Reference

### WorldGenerator Methods

```gdscript
# Get complete climate data at position
func get_climate_at(world_pos: Vector3) -> Dictionary
# Returns: {
#   insolation: float,      # Annual sun exposure (0-1)
#   precipitation: float,   # Rainfall potential (0-1)
#   thermal_inertia: float, # Temperature change rate (0-1)
#   terrain_type: int,      # 0-3 (deep ocean to highland)
#   is_coastal: bool,       # Near coastline
#   is_water: bool          # Water or land
# }

# Get precipitation for river generation
func get_precipitation_at(world_pos: Vector3) -> float

# Get spawn suitability for creature type
func get_spawn_suitability(world_pos: Vector3, creature_type: String) -> float
```

### ClimateMapBaker Static Methods

```gdscript
# Sample climate from pre-baked image
static func sample_climate(image: Image, world_pos: Vector3) -> Dictionary

# Get precipitation value
static func get_precipitation_at(image: Image, world_pos: Vector3) -> float

# Calculate spawn suitability
static func get_spawn_suitability(image: Image, world_pos: Vector3, creature_type: String) -> float
```

### Supported Creature Types
| Type | Optimal Conditions |
|------|-------------------|
| `polar_bear` | temp < 0.25, land |
| `penguin` | temp < 0.2, coastal |
| `camel`, `desert_lizard` | temp > 0.6, moisture < 0.3 |
| `monkey`, `parrot` | temp > 0.7, moisture > 0.6 |
| `deer`, `wolf` | temp 0.3-0.7, moisture > 0.3 |
| `fish`, `whale`, `dolphin` | deep ocean |
| `crab`, `seal` | coastal water |

## Future Extensions

### River & Lake Generation
```gdscript
# Use precipitation data to trace water flow
var precip = world.get_precipitation_at(position)
# High precipitation areas are river sources
# Flow downhill based on terrain height
```

### Weather System
```glsl
// Planned uniforms
uniform sampler2D weather_map;
uniform float global_cloud_cover;
```

### Vegetation Density
```gdscript
# Combine precipitation and temperature for vegetation
var climate = world.get_climate_at(position)
var vegetation = climate.precipitation * (1.0 - abs(climate.insolation - 0.5) * 2.0)
```

## Performance Notes

- Climate texture baking: ~1-2 seconds at 2048x1024
- Shader overhead: Minimal (one texture sample per fragment)
- Memory: ~8MB for climate texture
- CPU queries: O(1) texture lookup
