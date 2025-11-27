extends MeshInstance3D

@export var seed: int = 1337
@export_range(0, 8, 1) var subdivisions: int = 7  # Increased for smoother coastlines (was 6)
@export var radius: float = 60.0
@export var sea_level: float = 0.02
@export_range(0.0, 1.0, 0.05) var min_land_ratio: float = 0.4  # Minimum guaranteed land coverage
@export var ocean_bias: float = 0.08
@export var continent_gain: float = 0.48
@export var continent_power: float = 1.35
@export var mountain_gain: float = 0.08  # Base value (reduced from 0.18)
@export var detail_gain: float = 0.06    # Base value (reduced from 0.10)
@export var ridge_gain: float = 0.06     # Base value (reduced from 0.12)

# Terrain Variation - controls how dramatic/flat the terrain is
@export_range(0.0, 1.0, 0.05) var plains_coverage: float = 0.4  # How much of land is flat plains
@export_range(0.0, 1.0, 0.05) var extreme_terrain_chance: float = 0.05  # 5% chance for very mountainous worlds
@export_range(0, 8, 1) var smooth_iterations: int = 3
@export_range(0.0, 1.0, 0.05) var smooth_strength: float = 0.5
@export var plate_count: int = 12
@export_range(0.0, 1.0, 0.05) var continental_ratio: float = 0.55
@export var boundary_gain: float = 0.06  # Reduced from 0.12
@export var hotspot_gain: float = 0.03  # Reduced from 0.06
@export var warp_strength: float = 0.15
@export var warp_frequency: float = 0.8

# Coastline Detail Parameters
@export_range(0.0, 0.2, 0.01) var coastline_detail_strength: float = 0.08
@export_range(0.0, 1.0, 0.05) var coastline_erosion_strength: float = 0.4
@export_range(1.0, 10.0, 0.5) var coastline_frequency: float = 3.5
@export_range(0.0, 0.1, 0.01) var coastline_band_width: float = 0.06

# LOD System
@export var enable_lod: bool = true
@export var lod_distances: Array[float] = [50.0, 80.0, 120.0]

# Time and Rotation System
@export var day_duration_seconds: float = 3600.0  # 1 game day = 3600 seconds (1 hour real time)
@export var time_scale: float = 1.0               # Time scale multiplier (editor adjustable)
@export var enable_rotation: bool = true          # Enable planet rotation and orbital movement

# Sun Lighting
@export_range(0.5, 3.0, 0.1) var sun_energy: float = 1.5  # DirectionalLight3D energy
@export var sun_color: Color = Color(1.0, 0.98, 0.92)     # Slightly warm sun color
@export var ambient_energy: float = 0.3                    # Ambient light level

var _lod_meshes: Array[ArrayMesh] = []
var _lod_subdivisions: Array[int] = [7, 6, 5]  # LOD 0 = highest quality (~80k verts), LOD 2 = lowest (far)
var _current_lod: int = -1
var _camera: Camera3D = null
var _material: ShaderMaterial = null

var _continent_noise: FastNoiseLite
var _continent_noise_detail: FastNoiseLite
var _detail_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _moisture_noise: FastNoiseLite
var _mid_detail_noise: FastNoiseLite  # Mid-frequency detail for terrain variation
var _warp_noise_x: FastNoiseLite
var _warp_noise_y: FastNoiseLite
var _warp_noise_z: FastNoiseLite
var _coastline_noise: FastNoiseLite  # High frequency noise for coastline detail
var _coastline_erosion_noise: FastNoiseLite  # Erosion pattern for natural coastlines
var _plains_noise: FastNoiseLite  # Large-scale noise for plains regions
var _terrain_drama: float = 1.0  # Multiplier for terrain height variation (set per-seed)
var _effective_sea_level: float = 0.02  # Adjusted sea level to guarantee min_land_ratio
var _plates: Array
var rng_inst: RandomNumberGenerator

# Orbital and Rotation Parameters (generated from seed)
# Earth reference values: axial_tilt=23.44, rotation_period=24h, orbital_period=365.25d
var _axial_tilt: float = 23.44           # Axial tilt in degrees (affects seasons)
var _rotation_period: float = 24.0       # Rotation period in hours (day length)
var _rotation_direction: int = 1         # 1 = prograde, -1 = retrograde
var _orbital_period: float = 365.25      # Orbital period in Earth days (year length)
var _orbital_inclination: float = 0.0    # Orbital plane inclination in degrees
var _orbital_eccentricity: float = 0.017 # Orbital eccentricity (0 = circular)
var _orbital_direction: int = 1          # 1 = counter-clockwise, -1 = clockwise
var _sun_intensity: float = 1.0          # Relative sun intensity (affects temperature)
var _world_time: float = 0.0             # Elapsed game time in seconds

# Lighting objects
var _sun_light: DirectionalLight3D = null
var _world_environment: WorldEnvironment = null

# Climate system
var _climate_texture: ImageTexture = null
var _climate_image: Image = null  # For CPU-side queries (rivers, character distribution)

func _ready() -> void:
	# Find camera for LOD system
	_camera = get_viewport().get_camera_3d()

	# Setup sun light reference (from scene) or create one
	_setup_sun_light()

	# Create WorldEnvironment for ambient lighting
	_setup_world_environment()

	generate()

func _setup_sun_light() -> void:
	# Try to find existing Sun node in parent
	var parent := get_parent()
	if parent:
		_sun_light = parent.get_node_or_null("Sun") as DirectionalLight3D

	# If no existing sun, create one
	if _sun_light == null:
		_sun_light = DirectionalLight3D.new()
		_sun_light.name = "SunLight"
		_sun_light.shadow_enabled = true
		_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		_sun_light.directional_shadow_max_distance = 300.0
		add_child(_sun_light)

	# Apply settings
	_sun_light.light_energy = sun_energy
	_sun_light.light_color = sun_color

func _setup_world_environment() -> void:
	_world_environment = WorldEnvironment.new()
	_world_environment.name = "WorldEnvironment"

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.05)  # Dark space background
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.45, 0.6)  # Slight blue ambient
	env.ambient_light_energy = ambient_energy

	_world_environment.environment = env
	add_child(_world_environment)

func _process(delta: float) -> void:
	# LOD System
	if enable_lod and _camera != null and not _lod_meshes.is_empty():
		# Calculate distance from camera to world center
		var cam_distance := _camera.global_transform.origin.length()

		# Determine target LOD level
		var target_lod := 0
		for i in range(lod_distances.size()):
			if cam_distance > lod_distances[i]:
				target_lod = i + 1
		target_lod = clamp(target_lod, 0, _lod_meshes.size() - 1)

		# Switch mesh if LOD changed
		if target_lod != _current_lod and target_lod < _lod_meshes.size():
			mesh = _lod_meshes[target_lod]
			_current_lod = target_lod

	# Rotation and orbital system
	if not enable_rotation:
		return

	# Update world time
	_world_time += delta * time_scale

	# Planet rotation (around local Y axis, which is tilted by axial_tilt)
	var day_length: float = day_duration_seconds * (_rotation_period / 24.0)
	var rotation_speed: float = TAU / day_length
	rotate_object_local(Vector3.UP, _rotation_direction * rotation_speed * delta * time_scale)

	# Update sun light direction (DirectionalLight3D looks in -Z direction)
	if _sun_light:
		var sun_dir := _calculate_sun_direction()
		# DirectionalLight3D points in its -Z direction, so we need to orient it
		_sun_light.look_at(Vector3.ZERO, Vector3.UP)
		_sun_light.global_position = sun_dir * 100.0  # Position doesn't matter for directional, but helps visualize
		_sun_light.look_at(Vector3.ZERO, Vector3.UP)

func generate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	rng_inst = rng

	# Calculate terrain drama based on seed - only ~5% worlds are extremely mountainous
	_terrain_drama = _calculate_terrain_drama(rng)

	# Generate orbital and rotation parameters
	_generate_orbital_parameters(rng)

	_setup_noise(rng)
	_plates = _generate_plates(rng)

	# Reset effective sea level for new generation
	_effective_sea_level = sea_level

	# Create shared material
	_material = _make_material()

	if enable_lod:
		# Generate multiple LOD meshes
		_lod_meshes.clear()
		var is_first_mesh := true
		for subdiv in _lod_subdivisions:
			var lod_mesh := _generate_mesh_at_subdivision(subdiv, is_first_mesh)
			_lod_meshes.append(lod_mesh)
			is_first_mesh = false

		# Start with highest detail (LOD 0 = closest = highest subdiv)
		_current_lod = 0
		mesh = _lod_meshes[0]
	else:
		# Single mesh mode
		mesh = _generate_mesh_at_subdivision(subdivisions, true)

	# Update shader with effective sea level
	if _material:
		_material.set_shader_parameter("sea_level_shader", _effective_sea_level)

	# Bake climate map and set texture
	_bake_climate_map()
	if _material and _climate_texture:
		_material.set_shader_parameter("climate_map", _climate_texture)

	# Reset world time and update initial sun position
	_world_time = 0.0
	if _sun_light:
		var initial_sun_dir := _calculate_sun_direction()
		_sun_light.global_position = initial_sun_dir * 100.0
		_sun_light.look_at(Vector3.ZERO, Vector3.UP)

	# Apply axial tilt to planet (tilt around X axis)
	rotation.x = deg_to_rad(_axial_tilt)

# Determines how dramatic/mountainous this world is
# Returns 0.3-0.6 for most worlds (plains-heavy), 1.5-2.5 for extreme (5%)
func _calculate_terrain_drama(rng: RandomNumberGenerator) -> float:
	var roll: float = rng.randf()

	if roll < extreme_terrain_chance:
		# Extreme mountainous world (5% chance)
		return rng.randf_range(1.8, 2.5)
	elif roll < extreme_terrain_chance + 0.15:
		# Moderately mountainous (15% chance)
		return rng.randf_range(1.0, 1.5)
	elif roll < extreme_terrain_chance + 0.15 + 0.30:
		# Normal varied terrain (30% chance)
		return rng.randf_range(0.6, 1.0)
	else:
		# Plains-dominated world (50% chance)
		return rng.randf_range(0.3, 0.6)

# Generate a value with gaussian distribution, clamped to range
# Uses Box-Muller transform for normal distribution
func _gaussian_range(rng: RandomNumberGenerator, mean: float, std_dev: float, min_val: float, max_val: float) -> float:
	# Box-Muller transform to generate normal distribution
	var u1: float = rng.randf_range(0.0001, 1.0)  # Avoid log(0)
	var u2: float = rng.randf()
	var z: float = sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2)
	var value: float = mean + z * std_dev
	return clamp(value, min_val, max_val)

# Generate orbital and rotation parameters based on seed
# All values centered around Earth's parameters with realistic variance
func _generate_orbital_parameters(rng: RandomNumberGenerator) -> void:
	# Axial tilt: Earth = 23.44 degrees
	# Range: 0-60 degrees (beyond 60 causes extreme seasons)
	# Most planets cluster around 15-35 degrees
	_axial_tilt = _gaussian_range(rng, 23.44, 12.0, 0.0, 60.0)

	# Rotation period: Earth = 24 hours
	# Range: 8-72 hours (shorter = fast day/night, longer = extreme temperature swings)
	_rotation_period = _gaussian_range(rng, 24.0, 10.0, 8.0, 72.0)

	# Rotation direction: 90% prograde (like Earth), 10% retrograde (like Venus)
	_rotation_direction = 1 if rng.randf() > 0.1 else -1

	# Orbital period: Earth = 365.25 days
	# Range: 200-600 days (affects season length)
	_orbital_period = _gaussian_range(rng, 365.25, 80.0, 200.0, 600.0)

	# Orbital inclination: Earth = ~0 degrees (reference plane)
	# Range: -15 to 15 degrees (affects sun angle variation)
	_orbital_inclination = _gaussian_range(rng, 0.0, 5.0, -15.0, 15.0)

	# Orbital eccentricity: Earth = 0.017
	# Range: 0-0.15 (higher = more elliptical, bigger seasonal temp difference)
	# Use exponential-like distribution (most orbits are nearly circular)
	var ecc_base: float = rng.randf()
	_orbital_eccentricity = ecc_base * ecc_base * 0.15  # Skewed toward 0

	# Sun intensity: relative to Earth's sun (affects overall temperature)
	# Range: 0.7-1.3 (habitable zone constraints)
	_sun_intensity = _gaussian_range(rng, 1.0, 0.12, 0.7, 1.3)

	# Orbital direction: 90% counter-clockwise (like Earth), 10% clockwise
	_orbital_direction = 1 if rng.randf() > 0.1 else -1

# Get orbital parameters as a dictionary (for external access/UI)
func get_orbital_parameters() -> Dictionary:
	return {
		"axial_tilt": _axial_tilt,
		"rotation_period": _rotation_period,
		"rotation_direction": _rotation_direction,
		"orbital_period": _orbital_period,
		"orbital_inclination": _orbital_inclination,
		"orbital_eccentricity": _orbital_eccentricity,
		"orbital_direction": _orbital_direction,
		"sun_intensity": _sun_intensity,
		# Derived values for convenience
		"day_length_hours": _rotation_period,
		"year_length_days": _orbital_period,
		"seasons_intensity": _axial_tilt / 23.44,  # 1.0 = Earth-like seasons
		"is_rotation_retrograde": _rotation_direction < 0,
		"is_orbital_retrograde": _orbital_direction < 0
	}

# Calculate effective temperature modifier based on orbital parameters
# Returns a multiplier (1.0 = Earth-like)
func get_temperature_modifier() -> float:
	# Sun intensity directly affects temperature
	var temp_mod: float = _sun_intensity
	# Long days cause more extreme temperatures (slightly warmer on average)
	temp_mod *= 1.0 + (_rotation_period - 24.0) * 0.002
	return temp_mod

# Calculate seasonal intensity (how extreme seasons are)
# Returns 0-2 range (0 = no seasons, 1 = Earth-like, 2 = extreme)
func get_seasonal_intensity() -> float:
	var tilt_factor: float = _axial_tilt / 23.44
	var ecc_factor: float = 1.0 + _orbital_eccentricity * 5.0
	return tilt_factor * ecc_factor

# Calculate sun direction based on orbital position
# Returns normalized vector pointing toward the sun
func _calculate_sun_direction() -> Vector3:
	# Calculate orbital angle based on elapsed time
	var day_count: float = _world_time / day_duration_seconds
	var year_progress: float = fmod(day_count / _orbital_period, 1.0)
	var orbital_angle: float = _orbital_direction * year_progress * TAU

	# Sun direction in the orbital plane
	# X-Z plane is the orbital plane, Y is up
	var sun_dir := Vector3(
		cos(orbital_angle),
		sin(deg_to_rad(_orbital_inclination)) * sin(orbital_angle),
		sin(orbital_angle)
	).normalized()

	return sun_dir

# Calculate effective sea level to guarantee minimum land coverage
func _calculate_effective_sea_level(heights: PackedFloat32Array) -> float:
	if heights.is_empty():
		return sea_level

	# Count land vertices at current sea_level
	var land_count: int = 0
	for h in heights:
		if h >= sea_level:
			land_count += 1

	var land_ratio: float = float(land_count) / float(heights.size())

	# If already at or above minimum, use default sea_level
	if land_ratio >= min_land_ratio:
		return sea_level

	# Need to lower sea level to get more land
	# Sort heights and find the threshold for min_land_ratio
	var sorted_heights: Array = []
	for h in heights:
		sorted_heights.append(h)
	sorted_heights.sort()

	# Index for (1 - min_land_ratio) percentile = sea level that gives min_land_ratio land
	var target_index: int = int(float(heights.size()) * (1.0 - min_land_ratio))
	target_index = clamp(target_index, 0, heights.size() - 1)

	return sorted_heights[target_index]

func _generate_mesh_at_subdivision(subdiv: int, calculate_sea_level: bool = true) -> ArrayMesh:
	var ico := _build_icosphere(subdiv, radius)
	var verts_in: Array[Vector3] = ico["vertices"]
	var indices: PackedInt32Array = ico["indices"]

	# First pass: collect all raw heights
	var raw_heights: PackedFloat32Array = PackedFloat32Array()
	var normalized_dirs: Array[Vector3] = []

	for v in verts_in:
		var n: Vector3 = v.normalized()
		normalized_dirs.append(n)
		var plate_base := _plate_height(n)
		var height_sample: float = _sample_height(n, plate_base)
		var raw_height: float = clamp(height_sample, -0.35, 0.45)
		raw_heights.append(raw_height)

	# Calculate effective sea level only for first mesh to ensure consistency across LODs
	if calculate_sea_level:
		_effective_sea_level = _calculate_effective_sea_level(raw_heights)

	# Second pass: generate vertices with effective sea level
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var uvs: PackedVector2Array = PackedVector2Array()

	for i in range(verts_in.size()):
		var n: Vector3 = normalized_dirs[i]
		var raw_height: float = raw_heights[i]
		# Soft clip: gradual blend instead of hard max() to avoid cliff walls
		var elevated: float
		if raw_height >= _effective_sea_level:
			elevated = raw_height
		else:
			var depth: float = _effective_sea_level - raw_height
			var blend: float = smoothstep(0.0, 0.05, depth)
			elevated = lerp(raw_height, _effective_sea_level, blend)
		var position: Vector3 = n * (radius * (1.0 + elevated))
		var is_water: bool = raw_height < _effective_sea_level

		var temperature: float = _temperature_from_latitude(n.y, raw_height)
		var moisture: float = _moisture_from_noise(n, raw_height)
		var biome_data: Color = _encode_biome_data(raw_height, temperature, moisture, is_water)

		# Calculate UV coordinates for climate texture (equirectangular projection)
		var uv: Vector2 = _world_to_uv(n)

		vertices.append(position)
		normals.append(Vector3.ZERO)
		colors.append(biome_data)
		uvs.append(uv)

	# Feature-preserving smoothing with coastline detection
	vertices = _smooth_vertices_adaptive(vertices, indices, raw_heights, smooth_iterations, smooth_strength)
	normals = _compute_normals(vertices, indices)

	# Fix UV seam at longitude boundary (u=0 and u=1)
	var seam_result := _fix_uv_seam(vertices, normals, colors, uvs, indices)
	vertices = seam_result.vertices
	normals = seam_result.normals
	colors = seam_result.colors
	uvs = seam_result.uvs
	indices = seam_result.indices

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh_out := ArrayMesh.new()
	mesh_out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_out.surface_set_material(0, _material)
	return mesh_out

func _setup_noise(rng: RandomNumberGenerator) -> void:
	_continent_noise = FastNoiseLite.new()
	_continent_noise.seed = int(rng.randi())
	_continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_continent_noise.frequency = 0.32
	_continent_noise.fractal_octaves = 4
	_continent_noise.fractal_lacunarity = 1.9
	_continent_noise.fractal_gain = 0.55

	_continent_noise_detail = FastNoiseLite.new()
	_continent_noise_detail.seed = int(rng.randi())
	_continent_noise_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_continent_noise_detail.frequency = 0.85
	_continent_noise_detail.fractal_octaves = 3
	_continent_noise_detail.fractal_lacunarity = 2.0
	_continent_noise_detail.fractal_gain = 0.52

	_ridge_noise = FastNoiseLite.new()
	_ridge_noise.seed = int(rng.randi())
	_ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_ridge_noise.frequency = 1.2
	_ridge_noise.fractal_octaves = 3
	_ridge_noise.fractal_lacunarity = 2.0
	_ridge_noise.fractal_gain = 0.45
	_ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED

	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = int(rng.randi())
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = 4.0
	_detail_noise.fractal_octaves = 3
	_detail_noise.fractal_lacunarity = 2.0
	_detail_noise.fractal_gain = 0.4

	# Mid-frequency detail for terrain variation (hills, valleys)
	_mid_detail_noise = FastNoiseLite.new()
	_mid_detail_noise.seed = int(rng.randi())
	_mid_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_mid_detail_noise.frequency = 1.5
	_mid_detail_noise.fractal_octaves = 3
	_mid_detail_noise.fractal_lacunarity = 2.0
	_mid_detail_noise.fractal_gain = 0.5

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.seed = int(rng.randi())
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.frequency = 1.2
	_moisture_noise.fractal_octaves = 3
	_moisture_noise.fractal_gain = 0.6

	# Domain warping noise for organic continent shapes
	_warp_noise_x = FastNoiseLite.new()
	_warp_noise_x.seed = int(rng.randi())
	_warp_noise_x.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_x.frequency = warp_frequency
	_warp_noise_x.fractal_octaves = 2

	_warp_noise_y = FastNoiseLite.new()
	_warp_noise_y.seed = int(rng.randi())
	_warp_noise_y.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_y.frequency = warp_frequency
	_warp_noise_y.fractal_octaves = 2

	_warp_noise_z = FastNoiseLite.new()
	_warp_noise_z.seed = int(rng.randi())
	_warp_noise_z.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_z.frequency = warp_frequency
	_warp_noise_z.fractal_octaves = 2

	# Coastline detail noise - creates jagged shorelines, bays, and peninsulas
	_coastline_noise = FastNoiseLite.new()
	_coastline_noise.seed = int(rng.randi())
	_coastline_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	_coastline_noise.frequency = coastline_frequency
	_coastline_noise.fractal_octaves = 4
	_coastline_noise.fractal_lacunarity = 2.2
	_coastline_noise.fractal_gain = 0.55
	_coastline_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	_coastline_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_DIV

	# Erosion noise for natural-looking coastline irregularity
	_coastline_erosion_noise = FastNoiseLite.new()
	_coastline_erosion_noise.seed = int(rng.randi())
	_coastline_erosion_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_coastline_erosion_noise.frequency = coastline_frequency * 2.5
	_coastline_erosion_noise.fractal_octaves = 5
	_coastline_erosion_noise.fractal_lacunarity = 2.0
	_coastline_erosion_noise.fractal_gain = 0.6
	_coastline_erosion_noise.fractal_type = FastNoiseLite.FRACTAL_FBM

	# Plains noise - large scale regions that flatten terrain
	_plains_noise = FastNoiseLite.new()
	_plains_noise.seed = int(rng.randi())
	_plains_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_plains_noise.frequency = 0.5  # Large scale regions
	_plains_noise.fractal_octaves = 2
	_plains_noise.fractal_lacunarity = 2.0
	_plains_noise.fractal_gain = 0.5

func _warp_position(n: Vector3) -> Vector3:
	var wx := _warp_noise_x.get_noise_3d(n.x, n.y, n.z) * warp_strength
	var wy := _warp_noise_y.get_noise_3d(n.x, n.y, n.z) * warp_strength
	var wz := _warp_noise_z.get_noise_3d(n.x, n.y, n.z) * warp_strength
	return (n + Vector3(wx, wy, wz)).normalized()

func _sample_height(n: Vector3, plate_base: Dictionary) -> float:
	var base_height: float = plate_base["base"]
	var boundary_uplift: float = plate_base["boundary"]
	var hotspot: float = plate_base["hotspot"]

	# Apply domain warping for organic continent shapes
	var warped_n := _warp_position(n)
	var n1: float = _continent_noise.get_noise_3d(warped_n.x, warped_n.y, warped_n.z) * 0.3
	var n2: float = _continent_noise_detail.get_noise_3d(warped_n.x, warped_n.y, warped_n.z) * 0.2
	var combined: float = n1 + n2
	var shaped: float = sign(combined) * pow(abs(combined), continent_power)
	var low_freq: float = shaped * continent_gain - ocean_bias

	# Calculate base elevation (before mountains)
	var base_elevation: float = base_height + boundary_uplift + hotspot + low_freq

	# === Coastal Flattening System ===
	# Earth-like terrain: coastal areas are flat plains, mountains form inland
	# Based on Japanese terrain analysis: extensive coastal plains like Kanto Plain
	var elevation_above_sea: float = base_elevation - sea_level

	# Coastal transition zone: 0 at coast, 1 deep inland
	# Japan reference: coastal plains extend 10-50km before terrain rises
	const COASTAL_PLAIN_WIDTH: float = 0.06  # Expanded: flat coastal zone (was 0.03)
	const INLAND_TRANSITION: float = 0.15    # Expanded: where mountains allowed (was 0.08)
	var continental_depth: float = 0.0
	if elevation_above_sea > 0.0:
		continental_depth = smoothstep(COASTAL_PLAIN_WIDTH, INLAND_TRANSITION, elevation_above_sea)

	# === Plate Boundary Mountain Concentration ===
	# Mountains should concentrate at plate boundaries (like Japan Alps)
	# Allow mountains even in lower elevation areas if near plate boundary
	var boundary_factor: float = clamp(boundary_uplift / 0.04, 0.0, 1.0)

	# Calculate plains factor - regions where terrain is flattened
	var plains_value: float = _plains_noise.get_noise_3d(n.x, n.y, n.z)
	# Convert to 0-1 range and apply threshold based on plains_coverage
	var plains_threshold: float = 1.0 - plains_coverage * 2.0  # More coverage = lower threshold
	var plains_factor: float = smoothstep(plains_threshold - 0.2, plains_threshold + 0.2, plains_value)
	# Invert: high plains_factor = flat terrain (suppress mountains)
	var terrain_multiplier: float = (1.0 - plains_factor * 0.85) * _terrain_drama

	# Apply coastal flattening to terrain multiplier
	# Mountains allowed if: deep inland OR at plate boundary
	terrain_multiplier *= max(continental_depth, boundary_factor * 0.7)

	# === Plain Detail Suppression ===
	# Plains should be truly flat - suppress even small details
	var plain_detail_suppression: float = 0.2 + continental_depth * 0.8

	# Apply terrain drama to mountainous features
	var effective_ridge_gain: float = ridge_gain * terrain_multiplier
	var effective_mountain_gain: float = mountain_gain * terrain_multiplier
	var effective_detail_gain: float = detail_gain * terrain_multiplier * plain_detail_suppression

	var ridge: float = (1.0 - abs(_ridge_noise.get_noise_3d(n.x, n.y, n.z))) * effective_ridge_gain
	var detail: float = _detail_noise.get_noise_3d(n.x, n.y, n.z) * effective_detail_gain
	var mountain: float = ridge * (effective_mountain_gain + 0.02 * (1.0 - abs(n.y)))

	# Mid-frequency detail (hills, valleys) - only on land, heavily reduced in plains
	var land_mask: float = clamp((base_elevation - sea_level) / 0.1, 0.0, 1.0)
	var mid_detail: float = _mid_detail_noise.get_noise_3d(n.x, n.y, n.z) * 0.04 * land_mask * terrain_multiplier * plain_detail_suppression

	var pre_coastline_height: float = base_elevation + mountain + detail + mid_detail

	# Coastline detail - apply extra noise near sea level for complex shorelines
	var coastline_proximity: float = _coastline_band_factor(pre_coastline_height)
	var coastline_detail: float = 0.0
	if coastline_proximity > 0.01:
		# Cellular noise for irregular coastline shapes (bays, peninsulas, islands)
		var cell_noise: float = _coastline_noise.get_noise_3d(n.x, n.y, n.z)
		# Erosion noise for fine detail
		var erosion: float = _coastline_erosion_noise.get_noise_3d(n.x, n.y, n.z)
		# Combine with asymmetric effect (more land erosion than sea fill)
		var raw_detail: float = cell_noise * 0.6 + erosion * 0.4
		# Apply asymmetric erosion - land erodes more than ocean fills
		if pre_coastline_height > sea_level:
			coastline_detail = raw_detail * coastline_detail_strength * coastline_proximity * (1.0 + coastline_erosion_strength)
		else:
			coastline_detail = raw_detail * coastline_detail_strength * coastline_proximity * (1.0 - coastline_erosion_strength * 0.5)

	var height_after_detail: float = pre_coastline_height + coastline_detail

	# === Wave Erosion System ===
	# Coastlines are typically flat due to wave erosion creating beaches
	# Cliffs are exceptions (resistant rock, tectonic uplift)
	var final_height: float = _apply_wave_erosion(height_after_detail, n)

	return _compress_elevation(final_height)

# GDScript smoothstep implementation
func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

# Apply wave erosion to create realistic coastal profiles
# Most coastlines are flat beaches due to wave erosion
# Cliffs are rare exceptions (resistant rock, recent uplift)
func _apply_wave_erosion(height: float, n: Vector3) -> float:
	# Only affects land near sea level
	if height <= sea_level:
		return height

	var elevation: float = height - sea_level

	# Wave erosion zone parameters
	# Earth reference: wave erosion primarily affects 0-100m elevation
	# Planet scale: 1m = 9.417e-6 units
	const BEACH_ZONE: float = 0.0003      # 0-30m: Strong erosion zone (beach formation)
	const EROSION_ZONE: float = 0.001     # 30-100m: Extended erosion influence
	const CLIFF_PROBABILITY: float = 0.05 # ~5% chance of cliff coastlines (reduced from 12%)

	# Beyond erosion zone, no effect
	if elevation > EROSION_ZONE:
		return height

	# Use noise to determine if this is a cliff coast or beach coast
	# Higher frequency for more varied coastlines
	var cliff_noise: float = _coastline_noise.get_noise_3d(n.x * 2.0, n.y * 2.0, n.z * 2.0)
	# Also use erosion noise for secondary variation
	var rock_resistance: float = _coastline_erosion_noise.get_noise_3d(n.x * 1.5, n.y * 1.5, n.z * 1.5)

	# Combine noises to determine cliff vs beach
	# Cliff forms when both noises indicate resistant rock
	var cliff_factor: float = (cliff_noise + 1.0) * 0.5 * (rock_resistance + 1.0) * 0.5
	var is_cliff_coast: bool = cliff_factor > (1.0 - CLIFF_PROBABILITY)

	if is_cliff_coast:
		# Cliff coastline: minimal erosion, allow steep terrain
		# Still apply slight rounding at the very edge
		if elevation < BEACH_ZONE * 0.5:
			var edge_smoothing: float = elevation / (BEACH_ZONE * 0.5)
			return sea_level + elevation * (0.7 + 0.3 * edge_smoothing)
		return height
	else:
		# Beach coastline: strong erosion creates flat coastal plain
		if elevation <= BEACH_ZONE:
			# Strong flattening in beach zone
			# Pull height toward slightly above sea level
			var beach_target: float = sea_level + 0.003  # Slight elevation for beach
			var flatten_strength: float = 1.0 - (elevation / BEACH_ZONE)
			flatten_strength = flatten_strength * flatten_strength  # Stronger near water
			return lerp(height, beach_target, flatten_strength * 0.8)
		else:
			# Gradual transition from beach to inland
			var t: float = (elevation - BEACH_ZONE) / (EROSION_ZONE - BEACH_ZONE)
			# Erosion decreases with distance from water
			var erosion_strength: float = (1.0 - t) * 0.4
			var eroded_elevation: float = elevation * (1.0 - erosion_strength)
			return sea_level + eroded_elevation

# Compress elevation to match Earth's hypsometric curve
# Earth data (planet radius 60 units, 1m = 9.417e-6 units):
#   Lowland (0-500m = 0-0.005): 51% of land - coastal plains, valleys
#   Midland (500-2000m = 0.005-0.02): 37% of land - hills, plateaus
#   Highland (2000-5000m = 0.02-0.05): 11% of land - low mountains
#   Mountain (5000-8000m = 0.05-0.08): 1% of land - high mountains
#   Extreme (8000m+ = 0.08+): 0.01% of land - Himalayan peaks (14 on Earth)
func _compress_elevation(raw_height: float) -> float:
	# Keep underwater terrain as-is
	if raw_height < sea_level:
		return raw_height

	# Elevation above sea level
	var elevation: float = raw_height - sea_level

	# Earth-accurate elevation thresholds (relative to sea level)
	# Based on actual hypsometric curve of Earth's landmass
	const LOWLAND_MAX: float = 0.005     # 0-500m (51% of land) - plains, valleys
	const MIDLAND_MAX: float = 0.02      # 500-2000m (37% of land) - hills, plateaus
	const HIGHLAND_MAX: float = 0.05     # 2000-5000m (11% of land) - low mountains
	const MOUNTAIN_MAX: float = 0.08     # 5000-8000m (1% of land) - high mountains
	# Above 0.08 (8000m+): Extreme peaks like Himalayas (0.01% of land)

	var compressed: float

	if elevation <= LOWLAND_MAX:
		# 0-500m: No compression (51% of land should be here)
		compressed = elevation
	elif elevation <= MIDLAND_MAX:
		# 500-2000m: Light compression (37% of land)
		var t: float = (elevation - LOWLAND_MAX) / (MIDLAND_MAX - LOWLAND_MAX)
		var curved_t: float = sqrt(t)  # Favor lower elevations
		compressed = LOWLAND_MAX + curved_t * (MIDLAND_MAX - LOWLAND_MAX)
	elif elevation <= HIGHLAND_MAX:
		# 2000-5000m: Moderate compression (11% of land)
		var t: float = (elevation - MIDLAND_MAX) / (HIGHLAND_MAX - MIDLAND_MAX)
		var curved_t: float = t * t  # Square curve, make high elevations rarer
		compressed = MIDLAND_MAX + curved_t * (HIGHLAND_MAX - MIDLAND_MAX)
	elif elevation <= MOUNTAIN_MAX:
		# 5000-8000m: Strong compression (1% of land)
		var t: float = (elevation - HIGHLAND_MAX) / (MOUNTAIN_MAX - HIGHLAND_MAX)
		var curved_t: float = t * t * t  # Cubic curve, very rare
		compressed = HIGHLAND_MAX + curved_t * (MOUNTAIN_MAX - HIGHLAND_MAX)
	else:
		# 8000m+: Extreme logarithmic compression (0.01% of land)
		var excess: float = elevation - MOUNTAIN_MAX
		compressed = MOUNTAIN_MAX + log(1.0 + excess * 5.0) / 15.0

	return sea_level + compressed

# Calculate how close a height is to the coastline (sea_level)
func _coastline_band_factor(height: float) -> float:
	var distance_from_sea: float = abs(height - sea_level)
	if distance_from_sea > coastline_band_width:
		return 0.0
	# Smooth falloff from coastline
	return 1.0 - (distance_from_sea / coastline_band_width)

func _temperature_from_latitude(lat: float, height: float) -> float:
	var base: float = 1.0 - abs(lat) # equator warm, poles cold
	base -= max(height - 0.05, 0.0) * 1.6
	return clamp(base, 0.0, 1.0)

func _moisture_from_noise(n: Vector3, height: float) -> float:
	var sea_bias: float = -0.05
	if height < sea_level:
		sea_bias = 0.15
	var m: float = (_moisture_noise.get_noise_3d(n.x, n.y, n.z) * 0.5) + 0.5 + sea_bias
	return clamp(m, 0.0, 1.0)

func _encode_biome_data(raw_height: float, temperature: float, moisture: float, is_water: bool) -> Color:
	# Encode biome parameters into vertex color for shader-based blending
	# R: height (normalized from [-0.35, 0.45] to [0, 1])
	# G: temperature (0-1)
	# B: moisture (0-1)
	# A: is_water flag (1.0 = water, 0.0 = land)
	var encoded_height: float = clamp((raw_height + 0.35) / 0.8, 0.0, 1.0)
	return Color(encoded_height, temperature, moisture, 1.0 if is_water else 0.0)

## Convert normalized direction to UV coordinates (equirectangular projection)
func _world_to_uv(n: Vector3) -> Vector2:
	var longitude: float = atan2(n.z, n.x)  # -PI to PI
	var latitude: float = asin(clamp(n.y, -1.0, 1.0))  # -PI/2 to PI/2
	var u: float = longitude / TAU + 0.5  # 0 to 1
	var v: float = 0.5 - latitude / PI  # 0 to 1
	return Vector2(u, v)

## Fix UV seam at longitude boundary (u=0 and u=1)
## Duplicates vertices for triangles that cross the seam
func _fix_uv_seam(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	cols: PackedColorArray,
	uvs_in: PackedVector2Array,
	idx: PackedInt32Array
) -> Dictionary:
	var new_verts := PackedVector3Array()
	var new_norms := PackedVector3Array()
	var new_cols := PackedColorArray()
	var new_uvs := PackedVector2Array()
	var new_idx := PackedInt32Array()

	# Copy original data
	new_verts.append_array(verts)
	new_norms.append_array(norms)
	new_cols.append_array(cols)
	new_uvs.append_array(uvs_in)

	# Cache for duplicated vertices: original_index -> new_index (with u+1)
	var dup_cache: Dictionary = {}

	# Process each triangle
	for i in range(0, idx.size(), 3):
		var i0: int = idx[i]
		var i1: int = idx[i + 1]
		var i2: int = idx[i + 2]

		var u0: float = uvs_in[i0].x
		var u1: float = uvs_in[i1].x
		var u2: float = uvs_in[i2].x

		# Check if triangle crosses the seam (large u difference)
		var max_u: float = maxf(maxf(u0, u1), u2)
		var min_u: float = minf(minf(u0, u1), u2)

		if max_u - min_u > 0.5:
			# Triangle crosses seam - duplicate vertices with small u and add 1
			var threshold: float = 0.5
			var ni0: int = i0
			var ni1: int = i1
			var ni2: int = i2

			if u0 < threshold:
				ni0 = _get_or_create_seam_vertex(i0, new_verts, new_norms, new_cols, new_uvs, dup_cache)
			if u1 < threshold:
				ni1 = _get_or_create_seam_vertex(i1, new_verts, new_norms, new_cols, new_uvs, dup_cache)
			if u2 < threshold:
				ni2 = _get_or_create_seam_vertex(i2, new_verts, new_norms, new_cols, new_uvs, dup_cache)

			new_idx.append(ni0)
			new_idx.append(ni1)
			new_idx.append(ni2)
		else:
			# Normal triangle - keep original indices
			new_idx.append(i0)
			new_idx.append(i1)
			new_idx.append(i2)

	return {
		"vertices": new_verts,
		"normals": new_norms,
		"colors": new_cols,
		"uvs": new_uvs,
		"indices": new_idx
	}

## Helper: Get or create a duplicated vertex for seam fix
func _get_or_create_seam_vertex(
	orig_idx: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	cols: PackedColorArray,
	uvs: PackedVector2Array,
	cache: Dictionary
) -> int:
	if cache.has(orig_idx):
		return cache[orig_idx]

	# Duplicate vertex with u + 1.0
	var new_idx: int = verts.size()
	verts.append(verts[orig_idx])
	norms.append(norms[orig_idx])
	cols.append(cols[orig_idx])
	uvs.append(Vector2(uvs[orig_idx].x + 1.0, uvs[orig_idx].y))

	cache[orig_idx] = new_idx
	return new_idx

func _make_material() -> ShaderMaterial:
	# Load external shader file
	var shader := load("res://shaders/planet_surface.gdshader") as Shader
	if shader == null:
		push_error("Failed to load planet_surface.gdshader")
		return null

	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat

## Bake climate map texture
func _bake_climate_map() -> void:
	var baker := ClimateMapBaker.new()
	var result := baker.bake_with_image(self)
	_climate_texture = result.texture
	_climate_image = result.image
	print("Climate texture created: ", _climate_texture != null)
	print("Climate image size: ", _climate_image.get_size() if _climate_image else "null")
	print("Material exists: ", _material != null)

## Get climate data at world position (API for external systems)
func get_climate_at(world_pos: Vector3) -> Dictionary:
	if _climate_image == null:
		return {}
	return ClimateMapBaker.sample_climate(_climate_image, world_pos)

## Get precipitation at world position (for river generation)
func get_precipitation_at(world_pos: Vector3) -> float:
	if _climate_image == null:
		return 0.0
	return ClimateMapBaker.get_precipitation_at(_climate_image, world_pos)

## Get spawn suitability for creature type
func get_spawn_suitability(world_pos: Vector3, creature_type: String) -> float:
	if _climate_image == null:
		return 0.5
	return ClimateMapBaker.get_spawn_suitability(_climate_image, world_pos, creature_type)

func _build_icosphere(subdivisions: int, target_radius: float) -> Dictionary:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)
	]
	for i in range(verts.size()):
		verts[i] = verts[i].normalized() * target_radius

	var faces: Array = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
	]

	var midpoint_cache: Dictionary = {}

	for _i in range(subdivisions):
		var new_faces: Array = []
		for f in faces:
			var a := _midpoint(f[0], f[1], verts, midpoint_cache, target_radius)
			var b := _midpoint(f[1], f[2], verts, midpoint_cache, target_radius)
			var c := _midpoint(f[2], f[0], verts, midpoint_cache, target_radius)
			new_faces.append([f[0], a, c])
			new_faces.append([f[1], b, a])
			new_faces.append([f[2], c, b])
			new_faces.append([a, b, c])
		faces = new_faces
		midpoint_cache.clear()

	var idx := PackedInt32Array()
	for f in faces:
		# Flip winding so outward faces are front-facing.
		idx.append(f[0])
		idx.append(f[2])
		idx.append(f[1])

	return {
		"vertices": verts,
		"indices": idx
	}

func _build_neighbor_list(indices: PackedInt32Array, vertex_count: int) -> Array:
	var neighbors: Array = []
	neighbors.resize(vertex_count)
	for i in range(vertex_count):
		neighbors[i] = []
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]
		if b not in neighbors[a]: neighbors[a].append(b)
		if c not in neighbors[a]: neighbors[a].append(c)
		if a not in neighbors[b]: neighbors[b].append(a)
		if c not in neighbors[b]: neighbors[b].append(c)
		if a not in neighbors[c]: neighbors[c].append(a)
		if b not in neighbors[c]: neighbors[c].append(b)
	return neighbors

func _detect_coastlines(heights: PackedFloat32Array, neighbors: Array) -> PackedByteArray:
	var is_coastline := PackedByteArray()
	is_coastline.resize(heights.size())

	for i in range(heights.size()):
		var h := heights[i]
		var is_land := h >= _effective_sea_level
		var has_different := false

		for n_i in neighbors[i]:
			if (heights[n_i] >= _effective_sea_level) != is_land:
				has_different = true
				break

		is_coastline[i] = 1 if has_different else 0

	return is_coastline

func _compute_smoothing_weights(heights: PackedFloat32Array, is_coastline: PackedByteArray, neighbors: Array) -> PackedFloat32Array:
	var weights := PackedFloat32Array()
	weights.resize(heights.size())

	# First pass: mark vertices near coastlines (within 2 hops)
	var near_coastline := PackedByteArray()
	near_coastline.resize(heights.size())
	for i in range(heights.size()):
		if is_coastline[i] == 1:
			near_coastline[i] = 2  # Direct coastline
		else:
			# Check if neighbor is coastline
			for n_i in neighbors[i]:
				if is_coastline[n_i] == 1:
					near_coastline[i] = 1  # One hop from coastline
					break

	for i in range(heights.size()):
		if is_coastline[i] == 1:
			weights[i] = 0.0  # Completely preserve direct coastline vertices
		elif near_coastline[i] == 1:
			weights[i] = 0.15  # Very light smoothing near coastlines
		elif heights[i] < _effective_sea_level:
			# Gradual smoothing in ocean - less near shore
			var depth: float = _effective_sea_level - heights[i]
			weights[i] = clamp(0.3 + depth * 4.0, 0.3, 0.9)
		elif heights[i] > 0.25:
			weights[i] = 0.2  # Preserve mountain peaks
		elif heights[i] < _effective_sea_level + 0.05:
			weights[i] = 0.25  # Light smoothing on beaches/low coastal land
		else:
			weights[i] = 0.5  # Moderate smoothing for inland

	return weights

func _apply_laplacian_step(verts: PackedVector3Array, neighbors: Array, factor: float, weights: PackedFloat32Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(verts.size())

	for i in range(verts.size()):
		var v := verts[i]
		var neighbor_list: Array = neighbors[i]

		if neighbor_list.is_empty():
			result[i] = v
			continue

		var avg := Vector3.ZERO
		for n_i in neighbor_list:
			avg += verts[n_i]
		avg /= float(neighbor_list.size())

		var laplacian := avg - v
		var weight := weights[i]
		var new_pos := v + laplacian * factor * weight

		# Project back to sphere (preserve radial distance)
		result[i] = new_pos.normalized() * v.length()

	return result

func _smooth_vertices_adaptive(verts: PackedVector3Array, indices: PackedInt32Array, heights: PackedFloat32Array, iterations: int, strength: float) -> PackedVector3Array:
	if iterations <= 0 or strength <= 0.0:
		return verts

	# Build neighbor list
	var neighbors := _build_neighbor_list(indices, verts.size())

	# Detect coastlines
	var is_coastline := _detect_coastlines(heights, neighbors)

	# Compute adaptive smoothing weights (pass neighbors for near-coastline detection)
	var weights := _compute_smoothing_weights(heights, is_coastline, neighbors)

	# Taubin smoothing (shrink-free)
	var lambda_val := strength
	var mu_val := -strength - 0.03  # Slight over-compensation

	var current := verts
	for _iter in range(iterations):
		# Forward pass (smoothing)
		current = _apply_laplacian_step(current, neighbors, lambda_val, weights)
		# Backward pass (un-shrinking)
		current = _apply_laplacian_step(current, neighbors, mu_val, weights)

	return current

func _compute_normals(verts: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	for i in range(0, indices.size(), 3):
		var i0 := indices[i]
		var i1 := indices[i + 1]
		var i2 := indices[i + 2]
		var v0 := verts[i0]
		var v1 := verts[i1]
		var v2 := verts[i2]
		var n := (v1 - v0).cross(v2 - v0)
		normals[i0] += n
		normals[i1] += n
		normals[i2] += n
	for j in range(normals.size()):
		var n2 := normals[j]
		if n2.length() > 0.0001:
			normals[j] = n2.normalized()
		else:
			normals[j] = verts[j].normalized()
	return normals

func _generate_plates(rng: RandomNumberGenerator) -> Array:
	var plates: Array = []
	for i in range(plate_count):
		var dir := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)
		).normalized()
		var tangent := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)
		)
		tangent -= dir * tangent.dot(dir)
		if tangent.length() < 0.001:
			tangent = dir.cross(Vector3.UP)
		tangent = tangent.normalized() * rng.randf_range(0.15, 0.5)

		var is_cont := rng.randf() < continental_ratio
		var base_height := rng.randf_range(0.08, 0.16) if is_cont else rng.randf_range(-0.18, -0.06)

		plates.append({
			"pos": dir,
			"vel": tangent,
			"is_cont": is_cont,
			"base": base_height
		})
	return plates

func _plate_height(n: Vector3) -> Dictionary:
	if _plates.is_empty():
		return {"base": 0.0, "boundary": 0.0, "hotspot": 0.0}
	var nearest: int = -1
	var second: int = -1
	var d1: float = 10.0
	var d2: float = 10.0
	for i in range(_plates.size()):
		var p = _plates[i]
		var dist: float = 1.0 - n.dot(p["pos"])
		if dist < d1:
			d2 = d1; second = nearest
			d1 = dist; nearest = i
		elif dist < d2:
			d2 = dist; second = i
	if nearest == -1:
		return {"base": 0.0, "boundary": 0.0, "hotspot": 0.0}

	var p0 = _plates[nearest]
	if second == -1:
		return {"base": p0["base"], "boundary": 0.0, "hotspot": _hotspot_strength(n) * hotspot_gain}
	var p1 = _plates[second]
	var t: float = d1 / max(d1 + d2, 0.0001)
	var base: float = lerp(p0["base"], p1["base"], t)

	var rel_vel: Vector3 = p0["vel"] - p1["vel"]
	var boundary_dir: Vector3 = (p0["pos"] - p1["pos"]).normalized()
	var approach: float = -rel_vel.dot(boundary_dir)
	var converge: float = max(approach, 0.0) * boundary_gain

	var boundary_height: float = 0.0
	if p0["is_cont"] and p1["is_cont"]:
		boundary_height += converge * 0.7
	elif p0["is_cont"] != p1["is_cont"]:
		boundary_height += converge * 0.5
	else:
		boundary_height += converge * 0.2

	var hotspot := 0.0
	if rng_inst == null:
		hotspot = 0.0
	else:
		var hot := _hotspot_strength(n)
		hotspot = hot * hotspot_gain

	return {
		"base": base,
		"boundary": boundary_height,
		"hotspot": hotspot
	}

func _hotspot_strength(n: Vector3) -> float:
	if rng_inst == null:
		return 0.0
	var value := _detail_noise.get_noise_3d(n.x * 0.4, n.y * 0.4, n.z * 0.4)
	return max(value, 0.0)
func _midpoint(a: int, b: int, verts: Array, cache: Dictionary, target_radius: float) -> int:
	var key := str(min(a, b), ":", max(a, b))
	if cache.has(key):
		return cache[key]
	var m: Vector3 = (verts[a] + verts[b]).normalized() * target_radius
	verts.append(m)
	var idx: int = verts.size() - 1
	cache[key] = idx
	return idx
