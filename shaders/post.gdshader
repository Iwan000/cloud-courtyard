// 全屏后处理：暗角 + 纸张颗粒（同时消除渐变色带）
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float vignette : hint_range(0.0, 1.0) = 0.3;
uniform vec3 vignette_color : source_color = vec3(0.55, 0.45, 0.7);
uniform float grain : hint_range(0.0, 0.2) = 0.03;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 q = (SCREEN_UV - 0.5) * vec2(aspect, 1.0);
	float v = smoothstep(0.45, 1.25, length(q) * 1.15);
	c = mix(c, c * vignette_color, v * vignette);
	// 颗粒：低频静态纸纹 + 高频动态噪点
	vec2 px = SCREEN_UV / SCREEN_PIXEL_SIZE;
	float paper = hash12(floor(px * 0.5)) - 0.5;
	float dyn = hash12(px + fract(TIME * 7.13) * 400.0) - 0.5;
	c += (paper * 0.6 + dyn * 0.4) * grain;
	COLOR = vec4(c, 1.0);
}
