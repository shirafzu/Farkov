# Farkov - Procedural Planet Generator

Godot 4 GDScript project for procedural planet generation with realistic terrain, climate, and orbital mechanics.

## Project Structure

```
scripts/
  WorldGenerator.gd      # Main planet mesh generation
  ClimateMapBaker.gd     # Climate texture baking
  OrbitCamera.gd         # Camera controls
  SeedUI.gd              # Seed input UI
  TimeScaleUI.gd         # Time scale control UI
shaders/
  planet_surface.gdshader # Planet surface rendering with dynamic climate
scenes/
  WorldView.tscn         # Main scene
docs/
  climate-system.md      # Detailed climate system documentation
```

## Core Systems

### Terrain Generation
- Icosphere-based procedural mesh
- Plate tectonics simulation
- Multi-octave noise for continent shapes
- Coastline detail with erosion patterns
- LOD system for performance

### Orbital Mechanics
- Procedural orbital parameters (axial tilt, rotation period, orbital period)
- Day/night cycle with DirectionalLight3D
- Seasonal progression based on orbital position

### Climate System
Solar insolation-based climate with seasonal and diurnal temperature variations.

**Key Features:**
- 2048x1024 Equirectangular climate texture
- Hadley Cell precipitation model
- Thermal inertia (ocean vs land temperature response)
- Dynamic temperature calculation in shader

**API:**
```gdscript
# Get climate data at world position
var climate = world.get_climate_at(position)
# Returns: {insolation, precipitation, thermal_inertia, terrain_type, is_coastal, is_water}

# For river/lake generation
var rainfall = world.get_precipitation_at(position)

# For creature spawning
var suitability = world.get_spawn_suitability(position, "polar_bear")
```

**Details:** [docs/climate-system.md](docs/climate-system.md)

## Key Parameters

### WorldGenerator Exports
| Parameter | Default | Description |
|-----------|---------|-------------|
| `seed` | 1337 | World generation seed |
| `subdivisions` | 6 | Mesh detail level (0-7) |
| `radius` | 60.0 | Planet radius |
| `sea_level` | 0.02 | Ocean surface height |
| `min_land_ratio` | 0.4 | Minimum guaranteed land coverage |
| `day_duration_seconds` | 3600.0 | Real seconds per game day |
| `time_scale` | 1.0 | Time multiplier |

### Generated Orbital Parameters
- `_axial_tilt`: 0-60 degrees (Earth-like ~23.44)
- `_rotation_period`: 8-72 hours
- `_orbital_period`: 200-600 days

## Development Notes

### Adding New Biomes
1. Add color uniform in `planet_surface.gdshader`
2. Update `sample_land_biome()` function with new weights
3. Define temperature/moisture conditions

### Adding New Creature Types
Update `ClimateMapBaker.get_spawn_suitability()` with climate conditions.

### Future Work
- River and lake generation using precipitation data
- Weather system (clouds, rain visualization)
- Vegetation density based on climate
