// 2D 背景天空：渐变 + 太阳/月亮 + 柔和云带 + 星星（夜景）
// 由 Environment 的 Canvas 背景模式绘制在 3D 场景之后（正交相机下 3D 天空球会退化为单色）。
shader_type canvas_item;

uniform vec3 sky_top : source_color = vec3(0.62, 0.84, 0.9);
uniform vec3 sky_bottom : source_color = vec3(0.96, 0.9, 0.89);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.92);
uniform vec2 sun_pos = vec2(0.8, 0.2);
uniform float sun_size = 0.06;
uniform float sun_strength = 0.85;
uniform float cloud_amount = 0.6;
uniform float stars = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x),
		mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise(p);
		p = p * 2.03 + vec2(13.1, 7.7);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 uv = UV;
	vec3 col = mix(sky_top, sky_bottom, smoothstep(0.0, 1.0, pow(uv.y, 0.85)));

	// 太阳 / 月亮
	vec2 d = (uv - sun_pos) * vec2(aspect, 1.0);
	float r = length(d);
	col += sun_color * (exp(-r * 4.0) * 0.22 + exp(-r * 14.0) * 0.18) * sun_strength;
	float disc = 1.0 - smoothstep(sun_size * 0.97, sun_size, r);
	col = mix(col, mix(col, sun_color, 0.9), disc * sun_strength);

	// 星星
	if (stars > 0.0) {
		vec2 sp = uv * vec2(aspect, 1.0) * 140.0;
		vec2 cell = floor(sp);
		float h = hash12(cell);
		vec2 c = fract(sp) - 0.5 - (vec2(hash12(cell + 3.1), hash12(cell + 7.7)) - 0.5) * 0.6;
		float tw = 0.6 + 0.4 * sin(TIME * (1.0 + h * 3.0) + h * 40.0);
		float star = step(0.965, h) * smoothstep(0.12, 0.0, length(c)) * tw;
		col += vec3(star) * stars * (1.0 - uv.y * 0.6);
	}

	// 低空云带（缓慢漂移）
	vec2 cp = vec2(uv.x * aspect * 2.2 + TIME * 0.004, uv.y * 5.0);
	float cl = fbm(cp);
	float band = smoothstep(0.45, 1.0, uv.y);
	float cloud = smoothstep(0.42, 0.75, cl) * band * cloud_amount;
	vec3 cloud_col = mix(sky_bottom, vec3(1.0), 0.35);
	col = mix(col, cloud_col, cloud * 0.55);

	COLOR = vec4(col, 1.0);
}
