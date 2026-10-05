// 软边圆形粒子精灵（尘土、光点、花瓣），始终朝向相机。
// mode 0 = 普通混合（尘土），mode 1 = 发光（光点，配合 Glow）
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform int shape = 0;            // 0 = 圆，1 = 花瓣，2 = 四角星
instance uniform vec4 tint : source_color = vec4(1.0);
instance uniform float energy = 1.0;

void vertex() {
	// 公告板：保留模型的缩放，朝向相机
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sy, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float a;
	if (shape == 1) {
		vec2 p = vec2(q.x * 1.6, q.y);
		a = 1.0 - smoothstep(0.55, 0.75, length(p) + abs(q.y) * 0.25);
	} else if (shape == 2) {
		float d = min(abs(q.x) * 4.0 + abs(q.y), abs(q.y) * 4.0 + abs(q.x));
		a = 1.0 - smoothstep(0.6, 1.0, d);
		a = max(a, 1.0 - smoothstep(0.0, 0.35, length(q)));
	} else {
		a = 1.0 - smoothstep(0.35, 1.0, length(q));
	}
	ALBEDO = tint.rgb * energy;
	ALPHA = a * tint.a;
}
