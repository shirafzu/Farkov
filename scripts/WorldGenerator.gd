extends MeshInstance3D

@export var seed: int = 1337
@export_range(0, 7, 1) var subdivisions: int = 6
@export var radius: float = 60.0
@export var sea_level: float = 0.02
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
var _plates: Array
var rng_inst: RandomNumberGenerator

func _ready() -> void:
	# Find camera for LOD system
	_camera = get_viewport().get_camera_3d()
	generate()

func _process(_delta: float) -> void:
	if not enable_lod or _camera == null or _lod_meshes.is_empty():
		return

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

func generate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	rng_inst = rng

	# Calculate terrain drama based on seed - only ~5% worlds are extremely mountainous
	_terrain_drama = _calculate_terrain_drama(rng)

	_setup_noise(rng)
	_plates = _generate_plates(rng)

	# Create shared material
	_material = _make_material()

	if enable_lod:
		# Generate multiple LOD meshes
		_lod_meshes.clear()
		for subdiv in _lod_subdivisions:
			var lod_mesh := _generate_mesh_at_subdivision(subdiv)
			_lod_meshes.append(lod_mesh)

		# Start with highest detail (LOD 0 = closest = highest subdiv)
		_current_lod = 0
		mesh = _lod_meshes[0]
	else:
		# Single mesh mode
		mesh = _generate_mesh_at_subdivision(subdivisions)

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

func _generate_mesh_at_subdivision(subdiv: int) -> ArrayMesh:
	var ico := _build_icosphere(subdiv, radius)
	var verts_in: Array[Vector3] = ico["vertices"]
	var indices: PackedInt32Array = ico["indices"]

	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var raw_heights: PackedFloat32Array = PackedFloat32Array()

	for v in verts_in:
		var n: Vector3 = v.normalized()
		var plate_base := _plate_height(n)
		var height_sample: float = _sample_height(n, plate_base)
		var raw_height: float = clamp(height_sample, -0.35, 0.45)
		var elevated: float = max(raw_height, sea_level)
		var position: Vector3 = n * (radius * (1.0 + elevated))
		var is_water: bool = raw_height < sea_level

		var temperature: float = _temperature_from_latitude(n.y, raw_height)
		var moisture: float = _moisture_from_noise(n, raw_height)
		var biome_data: Color = _encode_biome_data(raw_height, temperature, moisture, is_water)

		vertices.append(position)
		normals.append(Vector3.ZERO)
		colors.append(biome_data)
		raw_heights.append(raw_height)

	# Feature-preserving smoothing with coastline detection
	vertices = _smooth_vertices_adaptive(vertices, indices, raw_heights, smooth_iterations, smooth_strength)
	normals = _compute_normals(vertices, indices)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
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

	# Calculate plains factor - regions where terrain is flattened
	var plains_value: float = _plains_noise.get_noise_3d(n.x, n.y, n.z)
	# Convert to 0-1 range and apply threshold based on plains_coverage
	var plains_threshold: float = 1.0 - plains_coverage * 2.0  # More coverage = lower threshold
	var plains_factor: float = smoothstep(plains_threshold - 0.2, plains_threshold + 0.2, plains_value)
	# Invert: high plains_factor = flat terrain (suppress mountains)
	var terrain_multiplier: float = (1.0 - plains_factor * 0.85) * _terrain_drama

	# Apply terrain drama to mountainous features
	var effective_ridge_gain: float = ridge_gain * terrain_multiplier
	var effective_mountain_gain: float = mountain_gain * terrain_multiplier
	var effective_detail_gain: float = detail_gain * (0.5 + terrain_multiplier * 0.5)  # Detail is less affected

	var ridge: float = (1.0 - abs(_ridge_noise.get_noise_3d(n.x, n.y, n.z))) * effective_ridge_gain
	var detail: float = _detail_noise.get_noise_3d(n.x, n.y, n.z) * effective_detail_gain
	var mountain: float = ridge * (effective_mountain_gain + 0.02 * (1.0 - abs(n.y)))

	# Mid-frequency detail (hills, valleys) - only on land, reduced in plains
	var base_elevation: float = base_height + boundary_uplift + hotspot + low_freq
	var land_mask: float = clamp((base_elevation - sea_level) / 0.1, 0.0, 1.0)
	var mid_detail: float = _mid_detail_noise.get_noise_3d(n.x, n.y, n.z) * 0.04 * land_mask * terrain_multiplier

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

	return pre_coastline_height + coastline_detail

# GDScript smoothstep implementation
func smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

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

func _make_material() -> ShaderMaterial:
	var shader_code := """
shader_type spatial;
render_mode cull_back, diffuse_lambert_wrap;

// Biome colors
uniform vec3 color_deep_ocean : source_color = vec3(0.03, 0.12, 0.26);
uniform vec3 color_shallow_ocean : source_color = vec3(0.1, 0.32, 0.46);
uniform vec3 color_beach : source_color = vec3(0.73, 0.67, 0.48);
uniform vec3 color_snow : source_color = vec3(0.88, 0.91, 0.96);
uniform vec3 color_cold_forest : source_color = vec3(0.38, 0.55, 0.46);
uniform vec3 color_tundra : source_color = vec3(0.52, 0.58, 0.43);
uniform vec3 color_desert : source_color = vec3(0.78, 0.65, 0.4);
uniform vec3 color_tropical : source_color = vec3(0.21, 0.55, 0.32);
uniform vec3 color_temperate : source_color = vec3(0.28, 0.63, 0.29);

uniform float sea_level_shader : hint_range(-0.1, 0.2) = 0.02;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.35;
uniform float shade_steps : hint_range(2.0, 16.0) = 8.0;
uniform float shade_softness : hint_range(0.0, 1.0) = 0.35;

// Smooth biome blending with soft transitions
vec3 sample_land_biome(float height, float temp, float moisture) {
	float cold = 1.0 - smoothstep(0.28, 0.42, temp);
	float hot = smoothstep(0.55, 0.72, temp);
	float dry = 1.0 - smoothstep(0.28, 0.42, moisture);
	float wet = smoothstep(0.48, 0.65, moisture);
	float high = smoothstep(0.12, 0.25, height);

	float beach_f = 1.0 - smoothstep(sea_level_shader, sea_level_shader + 0.03, height);
	float snow_f = cold * high;
	float cold_forest_f = cold * wet * (1.0 - high) * 0.8;
	float tundra_f = cold * dry * (1.0 - snow_f) * 0.6;
	float desert_f = hot * dry;
	float tropical_f = hot * wet;
	float temperate_f = max(0.2, (1.0 - cold - hot) * (1.0 - dry * 0.5 - wet * 0.5));

	float total = beach_f + snow_f + cold_forest_f + tundra_f +
				  desert_f + tropical_f + temperate_f + 0.001;

	return (color_beach * beach_f + color_snow * snow_f +
			color_cold_forest * cold_forest_f + color_tundra * tundra_f +
			color_desert * desert_f + color_tropical * tropical_f +
			color_temperate * temperate_f) / total;
}

// Soft cel shading with smooth band transitions
float soft_cel(float ndotl, float steps, float soft) {
	float stepped = floor(ndotl * steps) / steps;
	float next_step = ceil(ndotl * steps) / steps;
	float t = smoothstep(0.5 - soft * 0.5, 0.5 + soft * 0.5, (ndotl - stepped) * steps);
	return mix(stepped, next_step, t);
}

void fragment() {
	// Decode biome data from vertex color
	float height = COLOR.r * 0.8 - 0.35;
	float temp = COLOR.g;
	float moisture = COLOR.b;
	bool is_water = COLOR.a > 0.5;

	vec3 base;
	if (is_water) {
		float depth = clamp((sea_level_shader - height) / 0.12, 0.0, 1.0);
		base = mix(color_shallow_ocean, color_deep_ocean, depth);
	} else {
		base = sample_land_biome(height, temp, moisture);
	}

	// Lighting
	vec3 light_dir = normalize(vec3(0.4, 0.8, 0.2));
	float ndotl = max(dot(NORMAL, light_dir), 0.0);
	float shaded = soft_cel(ndotl, shade_steps, shade_softness);

	// Rim lighting
	float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0) * rim_strength;

	ALBEDO = base * (0.25 + shaded * 0.75) + rim * 0.2;
	ROUGHNESS = is_water ? 0.3 : 0.95;
}
"""
	var shader := Shader.new()
	shader.code = shader_code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat

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
		var is_land := h >= sea_level
		var has_different := false

		for n_i in neighbors[i]:
			if (heights[n_i] >= sea_level) != is_land:
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
		elif heights[i] < sea_level:
			# Gradual smoothing in ocean - less near shore
			var depth: float = sea_level - heights[i]
			weights[i] = clamp(0.3 + depth * 4.0, 0.3, 0.9)
		elif heights[i] > 0.25:
			weights[i] = 0.2  # Preserve mountain peaks
		elif heights[i] < sea_level + 0.05:
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
