// 云：由几团圆形"云朵"拼成的软边剪影，底部平直，顶部受光更亮。缓慢漂移由节点驱动。
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color_top : source_color = vec3(1.0);
uniform vec3 color_bottom : source_color = vec3(0.92, 0.88, 0.95);
instance uniform float seed = 0.0;
instance uniform float opacity = 1.0;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

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
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		p = p * 2.07 + vec2(5.3, 1.7);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = UV;
	// 由 6 团云朵组成；四边形宽高比 2:1，x 方向以宽度为单位
	float field = 0.0;
	float shade = 0.5;
	for (int i = 0; i < 6; i++) {
		float fi = float(i);
		float mid = 1.0 - abs(fi - 2.5) / 3.0;
		float r = 0.06 + hash11(seed * 7.7 + fi * 3.1) * 0.05 + mid * 0.09;
		float cx = 0.12 + fi * 0.152 + (hash11(seed * 13.1 + fi) - 0.5) * 0.07;
		float cy = 0.72 - r * 1.15;
		vec2 d = (uv - vec2(cx, cy)) * vec2(1.0, 0.5);
		float f = 1.0 - length(d) / r;
		if (f > field) {
			field = f;
			shade = clamp((cy - uv.y) / (r * 2.0) * 0.8 + 0.5, 0.0, 1.0);
		}
	}
	float n = fbm(uv * vec2(7.0, 3.5) + seed * 1.37 + vec2(TIME * 0.02, 0.0));
	field += (n - 0.5) * 0.35;
	float a = smoothstep(0.0, 0.22, field);
	a *= 1.0 - smoothstep(0.6, 0.78, uv.y);
	vec3 col = mix(color_bottom, color_top, clamp(shade * 0.75 + (0.75 - uv.y) * 0.4, 0.0, 1.0));
	ALBEDO = col;
	ALPHA = a * opacity;
}
