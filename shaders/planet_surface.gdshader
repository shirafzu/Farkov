shader_type spatial;
render_mode cull_back, diffuse_lambert_wrap;

// Debug visualization mode (0=Normal, 1=Insolation R, 2=Precipitation G, 3=Thermal Inertia B, 4=Terrain Mask A)
uniform int debug_mode : hint_range(0, 4) = 0;

// Climate texture (only used for debug visualization)
uniform sampler2D climate_map : filter_linear, repeat_enable;

// Biome colors (original)
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

// Original biome blending with soft transitions
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

// Convert world position to equirectangular UV (for debug visualization)
vec2 world_to_uv(vec3 world_pos) {
	vec3 n = normalize(world_pos);
	float u = 0.5 + atan(n.z, n.x) / TAU;
	float v = 0.5 - asin(clamp(n.y, -1.0, 1.0)) / PI;
	return vec2(u, v);
}

// Terrain mask to categorical colors (for debug visualization)
vec3 terrain_mask_to_color(float mask_value) {
	if (mask_value < 0.25) {
		return vec3(0.1, 0.2, 0.5);  // Deep ocean - dark blue
	} else if (mask_value < 0.5) {
		return vec3(0.3, 0.5, 0.7);  // Shallow water - light blue
	} else if (mask_value < 0.75) {
		return vec3(0.3, 0.6, 0.3);  // Lowland - green
	} else {
		return vec3(0.6, 0.4, 0.2);  // Highland - brown
	}
}

void fragment() {
	// Decode biome data from vertex color
	float height = COLOR.r * 0.8 - 0.35;
	float temp = COLOR.g;
	float moisture = COLOR.b;
	bool is_water = COLOR.a > 0.5;

	vec3 base_color;

	if (debug_mode == 0) {
		// Normal mode: Original vertex-color based rendering
		if (is_water) {
			float depth = clamp((sea_level_shader - height) / 0.12, 0.0, 1.0);
			base_color = mix(color_shallow_ocean, color_deep_ocean, depth);
		} else {
			base_color = sample_land_biome(height, temp, moisture);
		}

		// Original soft cel shading
		vec3 light_dir = normalize(vec3(0.4, 0.8, 0.2));
		float ndotl = max(dot(NORMAL, light_dir), 0.0);
		float shaded = soft_cel(ndotl, shade_steps, shade_softness);
		base_color = base_color * (0.25 + shaded * 0.75);
	} else {
		// Debug mode: Climate texture visualization
		// Use UV from vertex data (pre-calculated during mesh generation)
		vec4 climate = texture(climate_map, UV);

		if (debug_mode == 1) {
			// Insolation (R) - black to red
			base_color = vec3(climate.r, 0.0, 0.0);
		} else if (debug_mode == 2) {
			// Precipitation (G) - black to green
			base_color = vec3(0.0, climate.g, 0.0);
		} else if (debug_mode == 3) {
			// Thermal Inertia (B) - black to blue
			base_color = vec3(0.0, 0.0, climate.b);
		} else {
			// Terrain Mask (A) - categorical colors
			base_color = terrain_mask_to_color(climate.a);
		}
	}

	// Rim lighting
	float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0) * rim_strength;

	ALBEDO = base_color + rim * 0.2;
	ROUGHNESS = is_water ? 0.3 : 0.95;
}
