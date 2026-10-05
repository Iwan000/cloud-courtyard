// 箱子入位时沿印记方形外框升起的光幕：竖直渐隐（加色混合，配合 Glow）
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.95, 0.85);
instance uniform float intensity = 1.0;

void fragment() {
	// UV.y：0 顶部 → 1 底部；UV.x 沿方框周长
	float v = 1.0 - UV.y;
	float fade = pow(1.0 - v, 1.6) * smoothstep(0.0, 0.08, 1.0 - v + 0.02);
	float stripes = 0.8 + 0.2 * sin(UV.x * 6.2831 * 8.0 + TIME * 2.0 + v * 8.0);
	ALBEDO = color * fade * stripes * intensity * 0.85;
}
