// 结算界面底部的柔和渐变底色
shader_type canvas_item;

uniform vec3 tint : source_color = vec3(1.0);
uniform float strength = 0.62;

void fragment() {
	float a = smoothstep(0.5, 1.0, UV.y) * strength;
	COLOR = vec4(tint, a);
}
