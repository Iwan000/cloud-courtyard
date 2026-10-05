// 水面与瀑布。mode 0 = 水渠水面（沿 UV.y 流动），mode 1 = 瀑布（UV.y 为下落距离，单位：米）
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled, shadows_disabled;

uniform vec3 water_color : source_color = vec3(0.56, 0.85, 0.89);
uniform vec3 foam_color : source_color = vec3(1.0);
uniform int mode = 0;
uniform float speed = 1.0;
instance uniform float flow = 1.0;   // 0~1：水量（通关时涌水）

global uniform vec3 mv_fog_color;
global uniform vec2 mv_fog_range;
global uniform vec3 mv_deep_color;
global uniform vec2 mv_grad_range;

varying vec3 v_world;

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

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * speed;
	vec3 col = water_color;
	float alpha = 1.0;
	if (mode == 1) {
		// 竖向条纹快速下落，越往下越快、越散
		float fall = UV.y;
		float stretch = 1.0 / (1.0 + fall * 0.15);
		float n1 = noise(vec2(UV.x * 7.0, fall * 0.9 * stretch - t * 2.6));
		float n2 = noise(vec2(UV.x * 15.0 + 3.0, fall * 1.6 * stretch - t * 3.4));
		float streak = n1 * 0.6 + n2 * 0.4;
		col = mix(water_color * 0.9, mix(water_color, foam_color, 0.6), smoothstep(0.55, 0.85, streak));
		// 两侧边缘更亮，顶部翻越处的高光
		float edge = smoothstep(0.38, 0.5, abs(UV.x - 0.5));
		col = mix(col, mix(water_color, foam_color, 0.45), edge * 0.7);
		col = mix(col, foam_color, (1.0 - smoothstep(0.0, 0.12, fall)) * 0.5);
		// 水量：从顶部开始往下填充
		alpha = step(fall, flow * 40.0);
		if (alpha < 0.5) discard;
	} else {
		float n = noise(vec2(UV.x * 6.0, UV.y * 4.0 - t * 1.4));
		float lines = smoothstep(0.62, 0.8, n);
		col = mix(water_color, mix(water_color, foam_color, 0.55), lines);
		float rim = smoothstep(0.36, 0.5, abs(UV.x - 0.5));
		col = mix(col, mix(water_color, foam_color, 0.35), rim * 0.6);
	}
	// 与建筑一致的高度渐变与雾
	float g = smoothstep(mv_grad_range.x, mv_grad_range.y, v_world.y);
	col = mix(col, mv_deep_color * mix(vec3(1.0), col, 0.35), g * 0.45);
	float fog = smoothstep(mv_fog_range.x, mv_fog_range.y, v_world.y);
	ALBEDO = mix(col, mv_fog_color, fog);
}
