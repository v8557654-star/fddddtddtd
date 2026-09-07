shader_type canvas_item;
render_mode blend_mix;

// ============================================================
//  BODYCAM POST-PROCESS  (found-footage / action-camera look)
//  Applied full-screen on top of the 3D world.
// ============================================================

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;   // no per-frame mip chain (mobile cost)
uniform sampler2D grain_tex : repeat_enable, filter_linear_mipmap;
uniform sampler2D dirt_tex : filter_linear_mipmap;
uniform sampler2D static_tex : repeat_enable, filter_linear_mipmap;

uniform float time_sec : hint_range(0.0, 3600.0) = 0.0;
uniform float frame_jitter = 0.0;        // dropped/stuttering frames
uniform float aberration = 0.0035;       // chromatic split
uniform float grain = 0.10;
uniform float scanlines = 0.16;
uniform float vignette = 1.0;
uniform float barrel = 0.14;             // lens distortion
uniform float wobble = 0.35;             // rolling-shutter shear
uniform float static_amt = 0.0;          // analog burst / tracking error
uniform float damage = 0.0;              // red hurt flash
uniform float fear = 0.0;                // 0..1 low-sanity degradation
uniform float nvg = 0.0;                 // night-vision mode
uniform float exposure = 1.0;
uniform float saturation = 0.82;
uniform float crush = 0.06;              // crushed blacks
uniform float lens_dirt = 0.5;
uniform float cheap = 0.0;               // 1 = LOW preset: skip aberration + dirt
uniform vec2 aspect = vec2(1.7778, 1.0);

// ---- helpers ---------------------------------------------------------------
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

vec2 barrel_distort(vec2 uv, float k) {
	vec2 c = uv - 0.5;
	c.x *= aspect.x / aspect.y * 0.5625;   // keep circular-ish on any aspect
	float r2 = dot(c, c);
	c *= 1.0 + k * r2 + k * k * r2 * r2 * 1.6;
	c.x /= (aspect.x / aspect.y * 0.5625);
	return c + 0.5;
}

vec3 aces(vec3 x) {
	float a = 2.51;
	float b = 0.03;
	float c = 2.43;
	float d = 0.59;
	float e = 0.14;
	return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void fragment() {
	vec2 uv_raw = SCREEN_UV;
	float t = time_sec + frame_jitter;

	// ---- rolling shutter: per-scanline horizontal shear --------------------
	float row = uv_raw.y;
	float shear = sin(t * 1.7 + row * 3.1) * 0.0016
				+ sin(t * 9.3 + row * 41.0) * 0.0004;
	shear *= wobble;
	// handheld micro-shake baked into the signal
	shear += (hash11(floor(t * 24.0)) - 0.5) * 0.0009 * wobble;

	vec2 uv = vec2(uv_raw.x + shear, uv_raw.y);

	// ---- vertical hold slip / tracking band --------------------------------
	float band = step(0.995 - static_amt * 0.25, hash11(floor(t * 8.0)));
	if (band > 0.5) {
		float yy = fract(uv.y + t * 0.9);
		uv.x += sin(yy * 40.0 + t * 30.0) * 0.012 * static_amt;
	}

	// ---- lens barrel distortion --------------------------------------------
	uv = barrel_distort(uv, barrel + fear * 0.06 + nvg * 0.10);

	// out-of-lens area => black
	bool oob = uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
	vec3 col = vec3(0.0);

	if (!oob) {
	// ---- chromatic aberration (radial, stronger at edges) ------------------
	vec2 dirv = uv - 0.5;
	float edge = dot(dirv, dirv);
	float ab = aberration * (0.35 + edge * 3.2) + fear * 0.002 + static_amt * 0.004;
	if (cheap > 0.5) {
		col = texture(screen_tex, uv).rgb;          // single tap on LOW
	} else {
		col.r = texture(screen_tex, uv + dirv * ab).r;
		col.g = texture(screen_tex, uv).g;
		col.b = texture(screen_tex, uv - dirv * ab).b;
	}

	// ---- exposure / camcorder auto-gain breathing --------------------------
	float auto_gain = 1.0 + 0.05 * sin(t * 0.7) + 0.03 * sin(t * 3.3);
	col *= exposure * auto_gain;

	// ---- night vision -------------------------------------------------------
	if (nvg > 0.001) {
		float lum = dot(col, vec3(0.299, 0.587, 0.114));
		lum = pow(clamp(lum * 2.6, 0.0, 1.6), 0.82);
		vec3 phos = mix(vec3(0.10, 0.62, 0.28), vec3(0.72, 1.0, 0.78), clamp(lum, 0.0, 1.0));
		col = mix(col, phos * lum, nvg);
		col += vec3(0.02, 0.06, 0.03) * nvg;
	}

	// ---- filmic-ish response + grade ---------------------------------------
	col = aces(col * 1.05);
	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(l), col, saturation * (1.0 - fear * 0.35));
	// sickly tungsten-yellow / green cast
	col *= vec3(1.06, 1.015, 0.86);
	col = mix(col, col * vec3(0.92, 1.04, 0.96), fear * 0.6);
	// crushed blacks + milky highlights like a cheap sensor
	col = clamp((col - crush) / (1.0 - crush), 0.0, 1.0);
	col = col * 0.94 + 0.035;

	// ---- scanlines + aperture-grille hint ----------------------------------
	float sl = sin(uv.y * 1440.0 * 3.14159) * 0.5 + 0.5;
	col *= 1.0 - scanlines * 0.35 * sl;
	float grille = sin(uv.x * 1280.0 * 3.14159) * 0.5 + 0.5;
	col *= 1.0 - scanlines * 0.06 * grille;

	// ---- analog grain ------------------------------------------------------
	vec2 g_uv = uv * vec2(aspect.x, 1.0) * 2.2 + vec2(t * 13.7, t * 7.3);
	float g = texture(grain_tex, g_uv).r;
	float g2 = texture(grain_tex, g_uv * 0.37 + 4.7).r;
	float gmix = (g - 0.5) * grain + (g2 - 0.5) * grain * 0.5;
	gmix *= 1.0 + l * 0.6;                       // grain rides on highlights
	gmix += fear * 0.05 * (g - 0.5);
	col += gmix;
	if (nvg > 0.001) { col += (g - 0.5) * 0.16 * nvg; }

	// ---- lens dirt / smudges -----------------------------------------------
	if (cheap < 0.5) {
		vec4 dirt = texture(dirt_tex, uv * 0.92 + 0.04);
		col = mix(col, col * 0.55 + dirt.rgb * 0.10, dirt.a * lens_dirt);
	}

	// ---- vignette (optical) --------------------------------------------------
	vec2 vc = uv - 0.5;
	float vr = dot(vc, vc);
	float vig = smoothstep(0.92, 0.18, vr);
	vig = mix(1.0, vig, clamp(vignette, 0.0, 1.0));
	col *= vig;
	// corner colour-fringe bleed
	col.r += smoothstep(0.5, 1.0, vr) * 0.02;
	col.b += smoothstep(0.45, 1.0, vr) * 0.03;

	// ---- analog static burst -------------------------------------------------
	if (static_amt > 0.001) {
		vec3 st = texture(static_tex, uv * 3.0 + vec2(t * 11.0, -t * 17.0)).rgb;
		st = pow(st, vec3(1.4));
		float rows = step(0.5, fract(uv.y * 360.0 + t * 60.0));
		col = mix(col, st * vec3(0.9, 0.95, 0.9) * (0.6 + rows * 0.5), clamp(static_amt, 0.0, 1.0));
		// horizontal tearing
		float tear = step(0.985 - static_amt * 0.06, hash11(floor(uv.y * 90.0) + floor(t * 30.0)));
		col = mix(col, vec3(0.85), tear * static_amt * 0.7);
	}

	// ---- damage flash ---------------------------------------------------------
	if (damage > 0.001) {
		float pulse = 0.6 + 0.4 * sin(t * 22.0);
		col = mix(col, vec3(0.42, 0.02, 0.02), clamp(damage * pulse, 0.0, 0.85) * (0.35 + vr * 1.4));
	}

	// ---- fear degradation: geometry shimmer + dropout --------------------------
	if (fear > 0.001) {
		float d = hash11(floor(t * 12.0) + floor(uv.y * 24.0));
		col = mix(col, vec3(dot(col, vec3(0.33))) * vec3(0.9, 1.05, 0.95), step(1.0 - fear * 0.12, d) * 0.5);
	}
	}

	COLOR = vec4(mix(col, vec3(0.0), oob ? 1.0 : 0.0), 1.0);
}
