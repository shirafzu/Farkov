class_name ClimateMapBaker
extends RefCounted

## Climate map texture baker
## Generates a 2048x1024 Equirectangular texture encoding climate data:
## R: Annual insolation (sun exposure)
## G: Precipitation potential (for future rivers/lakes)
## B: Thermal inertia (temperature change rate)
## A: Terrain mask (terrain type and flags)

const TEXTURE_WIDTH := 2048
const TEXTURE_HEIGHT := 1024

# Reference to world generator for accessing terrain data
var _world_gen: Node = null
var _sea_level: float = 0.02
var _axial_tilt: float = 23.44
var _rotation_direction: int = 1  # 1 = prograde, -1 = retrograde

# Cached noise for precipitation calculation
var _precipitation_noise: FastNoiseLite = null
var _circulation_noise: FastNoiseLite = null

# Precipitation calculation buffers
var _height_buffer: PackedFloat32Array
var _insolation_buffer: PackedFloat32Array
var _is_water_buffer: PackedByteArray

# Advection parameters
const ADVECTION_STEPS := 8
const DISTANCE_DECAY := 0.92
const OROGRAPHIC_COEF := 0.4
const BASE_PRECIP_RATE := 0.15
const RE_EVAP_RATE := 0.25
const PASS1_WEIGHT := 0.7
const PASS2_WEIGHT := 0.3

# Cloud and mountain height parameters (relative to sea level)
# Earth reference: rain clouds at ~2-3km, mountains affect weather at ~4km+
# Planet scale: planet radius = 60 units, 1m = 9.417e-6 units
# Cloud base: height where rain clouds typically form (2000m)
const CLOUD_BASE_HEIGHT := 0.02
# Cloud blocking height: mountains above this significantly affect precipitation (4000m)
const CLOUD_BLOCKING_HEIGHT := 0.04
# Maximum effective height: beyond this, additional height doesn't increase effect (8000m, Everest level)
const CLOUD_MAX_EFFECT_HEIGHT := 0.08

func bake(world_gen: Node) -> ImageTexture:
	_world_gen = world_gen
	var eff_sea: Variant = world_gen.get("_effective_sea_level")
	var base_sea: Variant = world_gen.get("sea_level")
	_sea_level = float(eff_sea) if eff_sea != null else (float(base_sea) if base_sea != null else 0.02)
	var tilt: Variant = world_gen.get("_axial_tilt")
	_axial_tilt = float(tilt) if tilt != null else 23.44
	var rot_dir: Variant = world_gen.get("_rotation_direction")
	_rotation_direction = int(rot_dir) if rot_dir != null else 1

	_setup_noise(world_gen)
	_prebake_buffers()

	var image := Image.create(TEXTURE_WIDTH, TEXTURE_HEIGHT, false, Image.FORMAT_RGBA8)

	# Calculate precipitation using 8-step model
	var precipitation_map := _calculate_precipitation_map()

	for y in range(TEXTURE_HEIGHT):
		for x in range(TEXTURE_WIDTH):
			var u := float(x) / float(TEXTURE_WIDTH - 1)
			var v := float(y) / float(TEXTURE_HEIGHT - 1)
			var world_pos := _uv_to_world(u, v)
			var pixel := _calculate_climate_pixel_with_precip(world_pos, precipitation_map[y * TEXTURE_WIDTH + x])
			image.set_pixel(x, y, pixel)

	return ImageTexture.create_from_image(image)

## Also stores the image for future CPU-side access (rivers, character distribution)
func bake_with_image(world_gen: Node) -> Dictionary:
	_world_gen = world_gen
	var eff_sea: Variant = world_gen.get("_effective_sea_level")
	var base_sea: Variant = world_gen.get("sea_level")
	_sea_level = float(eff_sea) if eff_sea != null else (float(base_sea) if base_sea != null else 0.02)
	var tilt: Variant = world_gen.get("_axial_tilt")
	_axial_tilt = float(tilt) if tilt != null else 23.44
	var rot_dir: Variant = world_gen.get("_rotation_direction")
	_rotation_direction = int(rot_dir) if rot_dir != null else 1

	_setup_noise(world_gen)
	_prebake_buffers()

	var image := Image.create(TEXTURE_WIDTH, TEXTURE_HEIGHT, false, Image.FORMAT_RGBA8)

	# Calculate precipitation using 8-step model
	var precipitation_map := _calculate_precipitation_map()

	for y in range(TEXTURE_HEIGHT):
		for x in range(TEXTURE_WIDTH):
			var u := float(x) / float(TEXTURE_WIDTH - 1)
			var v := float(y) / float(TEXTURE_HEIGHT - 1)
			var world_pos := _uv_to_world(u, v)
			var pixel := _calculate_climate_pixel_with_precip(world_pos, precipitation_map[y * TEXTURE_WIDTH + x])
			image.set_pixel(x, y, pixel)

	# Debug: Sample a few pixels to verify data
	print("=== Climate Map Debug ===")
	print("Center pixel (512, 512): ", image.get_pixel(512, 512))
	print("North pole (512, 0): ", image.get_pixel(512, 0))
	print("South pole (512, 1023): ", image.get_pixel(512, 1023))
	print("Random pixel (100, 500): ", image.get_pixel(100, 500))

	var texture := ImageTexture.create_from_image(image)
	return {
		"texture": texture,
		"image": image
	}

func _setup_noise(world_gen: Node) -> void:
	var rng: RandomNumberGenerator = world_gen.get("rng_inst") as RandomNumberGenerator
	if rng == null:
		rng = RandomNumberGenerator.new()
		var seed_val: Variant = world_gen.get("seed")
		rng.seed = int(seed_val) if seed_val != null else 1337

	# Precipitation pattern noise (local variation)
	_precipitation_noise = FastNoiseLite.new()
	_precipitation_noise.seed = int(rng.randi())
	_precipitation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_precipitation_noise.frequency = 1.5
	_precipitation_noise.fractal_octaves = 3
	_precipitation_noise.fractal_lacunarity = 2.0
	_precipitation_noise.fractal_gain = 0.5

	# Large-scale circulation patterns
	_circulation_noise = FastNoiseLite.new()
	_circulation_noise.seed = int(rng.randi())
	_circulation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_circulation_noise.frequency = 0.6
	_circulation_noise.fractal_octaves = 2
	_circulation_noise.fractal_lacunarity = 2.0
	_circulation_noise.fractal_gain = 0.5

## Pre-bake height, insolation, and water mask buffers for precipitation calculation
func _prebake_buffers() -> void:
	var total_pixels := TEXTURE_WIDTH * TEXTURE_HEIGHT
	_height_buffer.resize(total_pixels)
	_insolation_buffer.resize(total_pixels)
	_is_water_buffer.resize(total_pixels)

	for y in range(TEXTURE_HEIGHT):
		for x in range(TEXTURE_WIDTH):
			var idx := y * TEXTURE_WIDTH + x
			var u := float(x) / float(TEXTURE_WIDTH - 1)
			var v := float(y) / float(TEXTURE_HEIGHT - 1)
			var world_pos := _uv_to_world(u, v)
			var n := world_pos.normalized()

			var height := _sample_height_at(n)
			var insolation := _calc_annual_insolation(n)

			_height_buffer[idx] = height
			_insolation_buffer[idx] = insolation
			_is_water_buffer[idx] = 1 if height < _sea_level else 0

## Get wind direction based on latitude (trade winds, westerlies, polar easterlies)
## Returns Vector2 where x = east-west (+ = eastward), y = north-south (+ = northward)
func _get_wind_direction(lat: float) -> Vector2:
	var abs_lat: float = absf(lat)
	var base_dir: float

	# Latitude-based wind zones
	if abs_lat < deg_to_rad(30.0):
		# Trade winds: blow from east to west (negative u direction)
		base_dir = -1.0
	elif abs_lat < deg_to_rad(60.0):
		# Westerlies: blow from west to east (positive u direction)
		base_dir = 1.0
	else:
		# Polar easterlies: blow from east to west
		base_dir = -1.0

	# Apply rotation direction (retrograde reverses wind patterns)
	base_dir *= _rotation_direction

	# Coriolis deflection: deflects right in northern hemisphere, left in southern
	# This adds a north-south component to the wind
	var coriolis_strength: float = 0.3
	var coriolis_deflection: float = coriolis_strength * signf(lat) * base_dir

	return Vector2(base_dir, coriolis_deflection).normalized()

## Sample moisture from upwind direction using semi-Lagrangian advection
## Returns accumulated moisture from upwind sampling
func _sample_upwind(moisture_buffer: PackedFloat32Array, x: int, y: int, steps: int) -> float:
	# Get latitude for this pixel (y=0 is north pole, y=TEXTURE_HEIGHT-1 is south pole)
	var v := float(y) / float(TEXTURE_HEIGHT - 1)
	var lat := (0.5 - v) * PI

	var wind := _get_wind_direction(lat)

	# Scale wind direction to pixel coordinates
	# Wind.x affects longitude (u), Wind.y affects latitude (v)
	# Note: positive wind.x means eastward, which decreases u in our coordinate system
	var pixels_per_step := 4.0  # How many pixels each advection step covers

	var accumulated_moisture := 0.0
	var decay_factor := 1.0
	var sample_x := float(x)
	var sample_y := float(y)

	for step in range(steps):
		# Move upwind (opposite of wind direction)
		sample_x -= wind.x * pixels_per_step
		sample_y += wind.y * pixels_per_step  # Note: +y is south in texture coords

		# Wrap x coordinate for spherical continuity
		if sample_x < 0:
			sample_x += TEXTURE_WIDTH
		elif sample_x >= TEXTURE_WIDTH:
			sample_x -= TEXTURE_WIDTH

		# Clamp y coordinate (poles)
		sample_y = clampf(sample_y, 0.0, float(TEXTURE_HEIGHT - 1))

		# Bilinear sample
		var sx0: int = int(sample_x) % TEXTURE_WIDTH
		var sx1: int = (sx0 + 1) % TEXTURE_WIDTH
		var sy0: int = int(sample_y)
		var sy1: int = mini(sy0 + 1, TEXTURE_HEIGHT - 1)
		var fx: float = sample_x - floorf(sample_x)
		var fy: float = sample_y - floorf(sample_y)

		var m00: float = moisture_buffer[sy0 * TEXTURE_WIDTH + sx0]
		var m10: float = moisture_buffer[sy0 * TEXTURE_WIDTH + sx1]
		var m01: float = moisture_buffer[sy1 * TEXTURE_WIDTH + sx0]
		var m11: float = moisture_buffer[sy1 * TEXTURE_WIDTH + sx1]

		var m0: float = m00 * (1.0 - fx) + m10 * fx
		var m1: float = m01 * (1.0 - fx) + m11 * fx
		var sampled: float = m0 * (1.0 - fy) + m1 * fy

		accumulated_moisture += sampled * decay_factor
		decay_factor *= DISTANCE_DECAY

	return accumulated_moisture

## Calculate terrain gradient along wind direction for orographic precipitation
## Returns positive value if terrain is rising in wind direction (windward slope)
## Now considers cloud height - only terrain above cloud base affects precipitation
func _calc_terrain_gradient(x: int, y: int, wind: Vector2) -> float:
	var idx: int = y * TEXTURE_WIDTH + x
	var center_height: float = _height_buffer[idx]

	# Sample height in wind direction
	var dx: int = int(round(wind.x * 2.0))
	var dy: int = int(round(-wind.y * 2.0))  # Negative because texture y is inverted

	var nx: int = (x + dx + TEXTURE_WIDTH) % TEXTURE_WIDTH
	var ny: int = clampi(y + dy, 0, TEXTURE_HEIGHT - 1)

	var downwind_height: float = _height_buffer[ny * TEXTURE_WIDTH + nx]

	# Calculate elevation above sea level
	var center_elevation: float = center_height - _sea_level
	var downwind_elevation: float = downwind_height - _sea_level

	# Calculate cloud-effective height (only terrain above cloud base affects weather)
	# Terrain below cloud base doesn't block rain clouds
	var center_cloud_height: float = maxf(0.0, center_elevation - CLOUD_BASE_HEIGHT)
	var downwind_cloud_height: float = maxf(0.0, downwind_elevation - CLOUD_BASE_HEIGHT)

	# Raw gradient in the cloud-affecting portion of terrain
	var raw_gradient: float = downwind_cloud_height - center_cloud_height

	# Calculate cloud blocking factor based on maximum terrain height involved
	# This determines how effectively the terrain blocks clouds
	var max_elevation: float = maxf(center_elevation, downwind_elevation)
	var blocking_factor: float = 0.0

	if max_elevation > CLOUD_BASE_HEIGHT:
		# Smoothly scale from 0 (at cloud base) to 1 (at blocking height)
		var height_above_base: float = max_elevation - CLOUD_BASE_HEIGHT
		var blocking_range: float = CLOUD_BLOCKING_HEIGHT - CLOUD_BASE_HEIGHT
		blocking_factor = clampf(height_above_base / blocking_range, 0.0, 1.0)

		# Additional boost for very high mountains (up to max effect height)
		if max_elevation > CLOUD_BLOCKING_HEIGHT:
			var extra_height: float = max_elevation - CLOUD_BLOCKING_HEIGHT
			var extra_range: float = CLOUD_MAX_EFFECT_HEIGHT - CLOUD_BLOCKING_HEIGHT
			var extra_factor: float = clampf(extra_height / extra_range, 0.0, 1.0)
			blocking_factor = 1.0 + extra_factor * 0.5  # Up to 1.5x effect for very high mountains

	# Return gradient scaled by blocking factor
	# Scale factor 8.0 (reduced from 10.0 to account for more realistic mountain effects)
	return raw_gradient * blocking_factor * 8.0

## Calculate precipitation map using 8-step physical model
func _calculate_precipitation_map() -> PackedFloat32Array:
	var total_pixels := TEXTURE_WIDTH * TEXTURE_HEIGHT
	var evaporation := PackedFloat32Array()
	var precip_pass1 := PackedFloat32Array()
	var re_evaporation := PackedFloat32Array()
	var precip_pass2 := PackedFloat32Array()
	var final_precip := PackedFloat32Array()

	evaporation.resize(total_pixels)
	precip_pass1.resize(total_pixels)
	re_evaporation.resize(total_pixels)
	precip_pass2.resize(total_pixels)
	final_precip.resize(total_pixels)

	# === Pass 1: Ocean evaporation ===
	# Water source + Insolation -> cloud formation
	for idx in range(total_pixels):
		if _is_water_buffer[idx] == 1:
			# Ocean evaporation: proportional to insolation (warmer = more evaporation)
			evaporation[idx] = _insolation_buffer[idx] * 0.8
		else:
			evaporation[idx] = 0.0

	# === Pass 2: Advection + Orographic precipitation (First pass) ===
	for y in range(TEXTURE_HEIGHT):
		var v := float(y) / float(TEXTURE_HEIGHT - 1)
		var lat := (0.5 - v) * PI
		var wind := _get_wind_direction(lat)

		for x in range(TEXTURE_WIDTH):
			var idx := y * TEXTURE_WIDTH + x

			# Sample moisture from upwind
			var moisture := _sample_upwind(evaporation, x, y, ADVECTION_STEPS)

			# Calculate terrain gradient for orographic effect
			var gradient := _calc_terrain_gradient(x, y, wind)
			var is_land := _is_water_buffer[idx] == 0

			if is_land and gradient > 0.0:
				# Windward slope: increased precipitation
				var orog_precip: float = moisture * OROGRAPHIC_COEF * clampf(gradient, 0.0, 1.0)
				precip_pass1[idx] = moisture * BASE_PRECIP_RATE + orog_precip
			else:
				# Flat terrain or leeward: base precipitation rate
				var lee_penalty: float = 0.0
				if is_land and gradient < -0.3:
					# Rain shadow on leeward slopes
					lee_penalty = absf(gradient) * 0.3
				precip_pass1[idx] = maxf(0.0, moisture * BASE_PRECIP_RATE - lee_penalty)

	# === Pass 3: Land re-evaporation ===
	# Land moisture + Insolation -> secondary cloud formation
	for idx in range(total_pixels):
		if _is_water_buffer[idx] == 0:
			# Land re-evaporation based on first-pass precipitation and insolation
			var land_moisture := precip_pass1[idx]
			re_evaporation[idx] = land_moisture * _insolation_buffer[idx] * RE_EVAP_RATE
		else:
			re_evaporation[idx] = 0.0

	# === Pass 4: Advection + Orographic precipitation (Second pass) ===
	for y in range(TEXTURE_HEIGHT):
		var v := float(y) / float(TEXTURE_HEIGHT - 1)
		var lat := (0.5 - v) * PI
		var wind := _get_wind_direction(lat)

		for x in range(TEXTURE_WIDTH):
			var idx := y * TEXTURE_WIDTH + x

			# Sample re-evaporated moisture from upwind
			var moisture := _sample_upwind(re_evaporation, x, y, ADVECTION_STEPS)

			# Calculate terrain gradient
			var gradient := _calc_terrain_gradient(x, y, wind)
			var is_land := _is_water_buffer[idx] == 0

			if is_land and gradient > 0.0:
				# Windward slope
				var orog_precip: float = moisture * OROGRAPHIC_COEF * clampf(gradient, 0.0, 1.0)
				precip_pass2[idx] = moisture * BASE_PRECIP_RATE + orog_precip
			else:
				var lee_penalty: float = 0.0
				if is_land and gradient < -0.3:
					lee_penalty = absf(gradient) * 0.3
				precip_pass2[idx] = maxf(0.0, moisture * BASE_PRECIP_RATE - lee_penalty)

	# === Final: Combine both passes ===
	for idx in range(total_pixels):
		var combined: float = precip_pass1[idx] * PASS1_WEIGHT + precip_pass2[idx] * PASS2_WEIGHT

		# Add local variation using noise
		var py: int = idx / TEXTURE_WIDTH
		var px: int = idx % TEXTURE_WIDTH
		var u: float = float(px) / float(TEXTURE_WIDTH - 1)
		var v: float = float(py) / float(TEXTURE_HEIGHT - 1)
		var world_pos: Vector3 = _uv_to_world(u, v)
		var n: Vector3 = world_pos.normalized()

		var local_var: float = (_precipitation_noise.get_noise_3d(n.x, n.y, n.z) + 1.0) * 0.5 * 0.15
		combined += local_var

		# Apply Hadley Cell baseline (ITCZ high, subtropics low)
		var lat: float = (0.5 - v) * PI
		var abs_lat: float = absf(lat)
		var hadley_mod: float = 1.0
		if abs_lat < deg_to_rad(15.0):
			# ITCZ boost
			hadley_mod = 1.2
		elif abs_lat < deg_to_rad(35.0):
			# Subtropical dry zone
			var t: float = (abs_lat - deg_to_rad(15.0)) / deg_to_rad(20.0)
			hadley_mod = 1.2 - t * 0.5  # Gradual decrease

		final_precip[idx] = clampf(combined * hadley_mod, 0.0, 1.0)

	return final_precip

## Calculate climate pixel with pre-calculated precipitation
func _calculate_climate_pixel_with_precip(world_pos: Vector3, precipitation: float) -> Color:
	var n: Vector3 = world_pos.normalized()

	# Get terrain height at this position
	var height: float = _sample_height_at(n)
	var is_water: bool = height < _sea_level

	# Calculate climate data
	var insolation: float = _calc_annual_insolation(n)
	var thermal_inertia: float = _calc_thermal_inertia_simple(n, height, is_water, precipitation)
	var terrain_mask: float = _calc_terrain_mask(height, is_water, n)

	return Color(insolation, precipitation, thermal_inertia, terrain_mask)

## Simplified thermal inertia calculation (no redundant precipitation calc)
func _calc_thermal_inertia_simple(n: Vector3, height: float, is_water: bool, moisture: float) -> float:
	if is_water:
		# Ocean has high thermal inertia
		var depth: float = clampf((_sea_level - height) / 0.3, 0.0, 1.0)
		# Deep ocean: 0.85-1.0, shallow: 0.75-0.85
		return 0.75 + depth * 0.25
	else:
		# Land thermal inertia depends on moisture and elevation
		var elevation: float = clampf((height - _sea_level) / 0.3, 0.0, 1.0)

		# Dry high elevation: low inertia (rapid temp swings)
		# Wet lowlands: higher inertia
		var base_inertia: float = 0.2
		var moisture_bonus: float = moisture * 0.3
		var elevation_penalty: float = elevation * 0.15

		return clampf(base_inertia + moisture_bonus - elevation_penalty, 0.1, 0.6)

## Convert UV coordinates (Equirectangular) to normalized world position
func _uv_to_world(u: float, v: float) -> Vector3:
	# u: 0-1 maps to longitude -PI to PI
	# v: 0-1 maps to latitude PI/2 to -PI/2 (top = north pole)
	var longitude: float = (u - 0.5) * TAU  # -PI to PI
	var latitude: float = (0.5 - v) * PI     # PI/2 to -PI/2

	# Spherical to Cartesian (Y-up coordinate system)
	var cos_lat: float = cos(latitude)
	return Vector3(
		cos_lat * cos(longitude),
		sin(latitude),
		cos_lat * sin(longitude)
	)

## Sample terrain height using WorldGenerator's noise functions
func _sample_height_at(n: Vector3) -> float:
	if _world_gen == null:
		return 0.0

	# Access the noise functions from WorldGenerator
	var continent_noise: FastNoiseLite = _world_gen.get("_continent_noise") as FastNoiseLite
	var continent_noise_detail: FastNoiseLite = _world_gen.get("_continent_noise_detail") as FastNoiseLite

	if continent_noise == null:
		return 0.0

	# Simplified height sampling (matches WorldGenerator logic)
	var ocean_bias_v: Variant = _world_gen.get("ocean_bias")
	var continent_gain_v: Variant = _world_gen.get("continent_gain")
	var continent_power_v: Variant = _world_gen.get("continent_power")
	var ocean_bias: float = float(ocean_bias_v) if ocean_bias_v != null else 0.08
	var continent_gain: float = float(continent_gain_v) if continent_gain_v != null else 0.48
	var continent_power: float = float(continent_power_v) if continent_power_v != null else 1.35

	# Apply domain warping if available
	var warped_n: Vector3 = n
	if _world_gen.has_method("_warp_position"):
		warped_n = _world_gen.call("_warp_position", n) as Vector3

	var n1: float = continent_noise.get_noise_3d(warped_n.x, warped_n.y, warped_n.z) * 0.3
	var n2: float = 0.0
	if continent_noise_detail != null:
		n2 = continent_noise_detail.get_noise_3d(warped_n.x, warped_n.y, warped_n.z) * 0.2

	var combined: float = n1 + n2
	var shaped: float = signf(combined) * pow(absf(combined), continent_power)
	var height: float = shaped * continent_gain - ocean_bias

	# Add plate tectonics base height
	if _world_gen.has_method("_plate_height"):
		var plate_data: Dictionary = _world_gen.call("_plate_height", n) as Dictionary
		height += float(plate_data.get("base", 0.0)) + float(plate_data.get("boundary", 0.0))

	return clampf(height, -0.35, 0.45)

## Calculate annual insolation based on latitude, axial tilt, and orbital parameters
## Returns 0.0 (poles/minimal) to 1.0 (equator/maximum)
## Earth-like distribution with clear gradient from equator to poles
func _calc_annual_insolation(n: Vector3) -> float:
	var lat: float = asin(clampf(n.y, -1.0, 1.0))
	var abs_lat: float = absf(lat)
	var tilt_rad: float = deg_to_rad(_axial_tilt)

	# Get orbital parameters from WorldGenerator
	var eccentricity: float = 0.017  # Earth default
	var sun_intensity: float = 1.0
	if _world_gen != null:
		var ecc: Variant = _world_gen.get("_orbital_eccentricity")
		if ecc != null:
			eccentricity = float(ecc)
		var sun_int: Variant = _world_gen.get("_sun_intensity")
		if sun_int != null:
			sun_intensity = float(sun_int)

	# Normalized latitude (0 at equator, 1 at poles)
	var lat_norm: float = abs_lat / (PI / 2.0)
	var tilt_norm: float = tilt_rad / deg_to_rad(90.0)  # 0-1 range

	# === Annual insolation using power-based falloff ===
	# This creates a smooth gradient from equator (1.0) to poles (low)
	# More physically accurate: insolation ~ cos(lat)^power
	# Power > 1 creates steeper dropoff at high latitudes

	# Base power depends on axial tilt
	# Higher tilt = less extreme annual variation (summer compensates winter)
	# Lower tilt = more extreme dropoff toward poles
	var base_power: float = 1.0 + (1.0 - tilt_norm) * 0.5  # 1.0-1.5 range

	# Primary insolation based on latitude
	# Using smoothstep-like curve for natural falloff
	var cos_lat: float = cos(lat)
	var insolation: float = pow(cos_lat, base_power)

	# === Latitude zone adjustments ===
	# Tropics (0-23.5°): Highest, direct overhead sun at some point in year
	# Subtropics (23.5-35°): Very high, strong sun year-round
	# Temperate (35-60°): Moderate, significant seasonal variation
	# Polar (60-90°): Low, extreme oblique angles

	var tropic_lat: float = tilt_rad  # Tropic of Cancer/Capricorn
	var tropic_norm: float = tropic_lat / (PI / 2.0)

	# Boost within tropics (direct overhead sun possible)
	if abs_lat < tropic_lat:
		var tropic_factor: float = 1.0 - abs_lat / tropic_lat
		insolation += tropic_factor * 0.08 * tilt_norm
	else:
		# Outside tropics: additional falloff
		var outside_factor: float = (lat_norm - tropic_norm) / (1.0 - tropic_norm)
		insolation -= outside_factor * outside_factor * 0.15

	# === Polar region adjustment ===
	# Extreme latitudes get additional penalty due to:
	# - Very oblique sun angles even in summer
	# - Long polar night in winter
	var polar_threshold: float = 0.67  # ~60 degrees
	if lat_norm > polar_threshold:
		var polar_factor: float = (lat_norm - polar_threshold) / (1.0 - polar_threshold)
		insolation -= polar_factor * polar_factor * 0.25

	# === Orbital eccentricity effects ===
	# High eccentricity creates asymmetric seasons
	# Slight reduction at extreme latitudes
	insolation -= eccentricity * lat_norm * lat_norm * 0.5

	# Apply sun intensity (distance from star)
	insolation *= sun_intensity

	# Target distribution (Earth-like with 23.44° tilt):
	# Equator (0°):  ~1.0
	# 15°:          ~0.95
	# 30°:          ~0.82
	# 45°:          ~0.65
	# 60°:          ~0.45
	# 75°:          ~0.28
	# Poles (90°):  ~0.15-0.20

	return clampf(insolation, 0.0, 1.0)

## Calculate terrain mask (encoded terrain type and flags)
## Encodes multiple bits of information in 0-1 range
func _calc_terrain_mask(height: float, is_water: bool, n: Vector3) -> float:
	# Terrain types (bits 0-1):
	# 0 = Deep ocean (< sea_level - 0.08)
	# 1 = Shallow ocean/coastal water
	# 2 = Lowland (sea_level to sea_level + 0.15)
	# 3 = Highland/Mountain (> sea_level + 0.15)
#
	var terrain_type: int = 0
	if is_water:
		var depth: float = _sea_level - height
		if depth > 0.08:
			terrain_type = 0  # Deep ocean
		else:
			terrain_type = 1  # Shallow water
	else:
		var elevation: float = height - _sea_level
		if elevation < 0.15:
			terrain_type = 2  # Lowland
		else:
			terrain_type = 3  # Highland

	# Coastal flag (bit 2): Set if near coastline
	var is_coastal: int = 0
	var coastal_distance: float = absf(height - _sea_level)
	if coastal_distance < 0.04:
		is_coastal = 1

	# Reserved bits 3-7 for future use (rivers, lakes, special features)
	# Currently unused, set to 0

	# Encode as normalized float
	# bits 0-1: terrain_type (0-3) -> 0.0, 0.25, 0.5, 0.75
	# bit 2: coastal (0-1) -> add 0.125 if set
	var encoded: float = float(terrain_type) / 4.0
	if is_coastal == 1:
		encoded += 0.125

	return clampf(encoded, 0.0, 1.0)

# --- API for external access (rivers, character distribution) ---

## Get climate data at world position (for CPU-side queries)
## Returns Dictionary with insolation, precipitation, thermal_inertia, terrain_type
static func sample_climate(image: Image, world_pos: Vector3) -> Dictionary:
	var n: Vector3 = world_pos.normalized()
	var uv: Vector2 = _world_to_uv_static(n)

	var x: int = int(uv.x * float(image.get_width() - 1))
	var y: int = int(uv.y * float(image.get_height() - 1))
	x = clampi(x, 0, image.get_width() - 1)
	y = clampi(y, 0, image.get_height() - 1)

	var pixel: Color = image.get_pixel(x, y)

	# Decode terrain mask
	var terrain_encoded: float = pixel.a
	var terrain_type: int = int(terrain_encoded * 4.0) % 4
	var is_coastal: bool = terrain_encoded - float(terrain_type) / 4.0 > 0.1

	return {
		"insolation": pixel.r,
		"precipitation": pixel.g,
		"thermal_inertia": pixel.b,
		"terrain_type": terrain_type,
		"is_coastal": is_coastal,
		"is_water": terrain_type < 2
	}

## Get precipitation at world position (shortcut for river generation)
static func get_precipitation_at(image: Image, world_pos: Vector3) -> float:
	var climate: Dictionary = sample_climate(image, world_pos)
	return float(climate.precipitation)

## Get spawn suitability for creature type based on climate
static func get_spawn_suitability(image: Image, world_pos: Vector3, creature_type: String) -> float:
	var climate: Dictionary = sample_climate(image, world_pos)

	if climate.is_water:
		# Water creatures
		match creature_type:
			"fish", "whale", "dolphin":
				return 1.0 if climate.terrain_type == 0 else 0.7  # Deep ocean preferred
			"crab", "seal":
				return 1.0 if climate.is_coastal else 0.2
			_:
				return 0.0  # Land creatures can't spawn in water
	else:
		# Land creatures
		var temp: float = climate.insolation
		var moisture: float = climate.precipitation

		match creature_type:
			"polar_bear":
				return 1.0 if temp < 0.25 else 0.0
			"penguin":
				return 1.0 if temp < 0.2 and climate.is_coastal else 0.0
			"camel", "desert_lizard":
				return 1.0 if temp > 0.6 and moisture < 0.3 else 0.0
			"monkey", "parrot":
				return 1.0 if temp > 0.7 and moisture > 0.6 else 0.0
			"deer", "wolf":
				return 1.0 if temp > 0.3 and temp < 0.7 and moisture > 0.3 else 0.5
			_:
				return 0.5  # Default moderate suitability

static func _world_to_uv_static(n: Vector3) -> Vector2:
	# Inverse of _uv_to_world
	var longitude: float = atan2(n.z, n.x)  # -PI to PI
	var latitude: float = asin(clampf(n.y, -1.0, 1.0))  # -PI/2 to PI/2

	var u: float = longitude / TAU + 0.5  # 0 to 1
	var v: float = 0.5 - latitude / PI     # 0 to 1

	return Vector2(u, v)
