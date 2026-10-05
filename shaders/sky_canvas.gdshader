// 2D 背景天空：干净的竖向渐变（夜景加少量星星）。
// 由 Environment 的 Canvas 背景模式绘制在 3D 场景之后（正交相机下 3D 天空球会退化为单色）。
shader_type canvas_item;

uniform vec3 sky_top : source_color = vec3(0.62, 0.84, 0.9);
uniform vec3 sky_bottom : source_color = vec3(0.96, 0.9, 0.89);
uniform float stars = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 uv = UV;
	vec3 col = mix(sky_top, sky_bottom, smoothstep(0.0, 1.0, pow(uv.y, 0.85)));

	// 星星（仅夜景）
	if (stars > 0.0) {
		vec2 sp = uv * vec2(aspect, 1.0) * 140.0;
		vec2 cell = floor(sp);
		float h = hash12(cell);
		vec2 c = fract(sp) - 0.5 - (vec2(hash12(cell + 3.1), hash12(cell + 7.7)) - 0.5) * 0.6;
		float tw = 0.6 + 0.4 * sin(TIME * (1.0 + h * 3.0) + h * 40.0);
		float star = step(0.97, h) * smoothstep(0.1, 0.0, length(c)) * tw;
		col += vec3(star) * stars * 0.8 * (1.0 - uv.y * 0.7);
	}
	COLOR = vec4(col, 1.0);
}
