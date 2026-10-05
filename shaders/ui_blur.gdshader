// 弹出界面的背景：读取屏幕做模糊并蒙一层淡色
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur : hint_range(0.0, 5.0) = 2.5;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.25);
uniform float amount : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec3 c = textureLod(screen_tex, SCREEN_UV, blur * amount).rgb;
	c = mix(c, tint.rgb, tint.a * amount);
	COLOR = vec4(c, 1.0);
}
