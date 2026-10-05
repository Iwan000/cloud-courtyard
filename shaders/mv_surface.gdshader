// 纪念碑谷风格表面着色器（所有建筑、箱子、角色共用）
//
// 颜色不由光照计算，而是按面的朝向直接取色：
//   顶面 = color_top，屏幕左侧面 = color_left，屏幕右侧面 = color_right，斜面在三者间混合。
// 之后依次叠加：顶点色（构件色差/窗洞）、地砖图案、高度图假 AO、世界 Y 渐变、高度雾。
// 方向光只用来投射彩色阴影，背光面不叠加自阴影。
//
// UV2.x = 入场动画延迟（0~1），UV2.y = 升起幅度系数；配合 instance uniform build_t
// 让整座建筑从云雾中逐块升起。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled,
	ambient_light_disabled, fog_disabled;

uniform vec3 color_top : source_color = vec3(0.97, 0.89, 0.84);
uniform vec3 color_left : source_color = vec3(0.92, 0.71, 0.66);
uniform vec3 color_right : source_color = vec3(0.85, 0.56, 0.53);

// 0 = 无, 1 = 地砖, 2 = 墙面砖缝（横向层）, 3 = 目标地砖（同心圆，按 UV 绘制）
uniform int pattern = 0;
uniform vec3 pattern_color : source_color = vec3(1.0);
uniform float pattern_strength : hint_range(0.0, 0.3) = 0.06;
uniform float ao_amount : hint_range(0.0, 1.5) = 1.0;
uniform float deep_amount : hint_range(0.0, 1.0) = 0.65;

uniform vec3 emission_color : source_color = vec3(1.0, 0.85, 0.55);
uniform float emission_energy = 0.0;

// 每个实例独立的参数
instance uniform float build_t = 1.0;   // 入场进度 0~1
instance uniform float fade = 0.0;      // 远景大气淡化
instance uniform vec3 fade_color : source_color = vec3(1.0);  // 淡化目标色（取其背后的天空色）
instance uniform float glow = 0.0;      // 自发光强度（窗户点亮、箱子入位等）
instance uniform float build_rise = 7.0;
instance uniform float ao_mask = 1.0;   // 远景浮岛不使用主关卡的 AO 高度图

global uniform vec3 mv_fog_color;
global uniform vec3 mv_deep_color;
global uniform vec3 mv_shadow_color;
global uniform vec2 mv_grad_range;   // (开始 y, 完全 y)
global uniform vec2 mv_fog_range;
global uniform sampler2D mv_ao_map : filter_linear, repeat_disable;
global uniform vec4 mv_ao_rect;      // xz 起点与尺寸
global uniform float mv_ao_strength;

varying vec3 v_world;
varying vec3 v_wnormal;

float ease_out_back(float x) {
	const float c1 = 1.40158;
	const float c3 = c1 + 1.0;
	float t = x - 1.0;
	return 1.0 + c3 * t * t * t + c1 * t * t;
}

void vertex() {
	float delay = UV2.x;
	float lt = clamp((build_t - delay * 0.6) / 0.4, 0.0, 1.0);
	VERTEX.y -= (1.0 - ease_out_back(lt)) * build_rise * UV2.y;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec3 n = normalize(v_wnormal);
	vec3 cam_right = normalize(INV_VIEW_MATRIX[0].xyz);

	// ---- 三面定色 ----
	float up = n.y;
	vec2 hz = n.xz;
	float hl = length(hz);
	float s = hl > 1e-4 ? dot(vec3(hz.x, 0.0, hz.y) / hl, cam_right) : 0.0;
	vec3 side = mix(color_left, color_right, smoothstep(-0.35, 0.35, s));
	float wt = clamp(up, 0.0, 1.0);
	float wb = clamp(-up, 0.0, 1.0);
	vec3 bottom = color_right * 0.8;
	vec3 base = side * (1.0 - wt - wb) + color_top * wt + bottom * wb;

	// ---- 顶点色（构件色差、窗洞等） ----
	base *= COLOR.rgb;

	// ---- 图案 ----
	if (pattern == 1 && up > 0.9) {
		vec2 g = v_world.xz + 0.5;
		vec2 f = abs(fract(g) - 0.5);
		float e = max(f.x, f.y);
		float w = fwidth(e) * 1.2;
		float line = smoothstep(0.485 - w, 0.485 + w, e);
		float tile = hash12(floor(g) + 17.0);
		base *= 1.0 + (tile - 0.5) * pattern_strength;
		base *= 1.0 - line * 0.07;
	} else if (pattern == 2 && abs(up) < 0.2) {
		float yy = v_world.y * 4.0;
		float e = abs(fract(yy) - 0.5);
		float w = fwidth(yy) * 1.2;
		float line = 1.0 - smoothstep(0.47 - w, 0.47 + w, 0.5 - e);
		base *= 1.0 - line * pattern_strength;
	}

	float pattern_glow = 0.0;
	if (pattern == 3) {
		vec2 q = UV * 2.0 - 1.0;
		float r = length(q);
		float sq = max(abs(q.x), abs(q.y));
		float aa = fwidth(r) * 1.2;
		float frame = smoothstep(0.80 - aa, 0.80 + aa, sq) * (1.0 - smoothstep(0.92 - aa, 0.92 + aa, sq));
		float ring = smoothstep(0.50 - aa, 0.50 + aa, r) * (1.0 - smoothstep(0.62 - aa, 0.62 + aa, r));
		float dot_c = 1.0 - smoothstep(0.17 - aa, 0.17 + aa, r);
		float mask = max(frame, max(ring, dot_c));
		float outside = smoothstep(0.92 - aa, 0.92 + aa, sq);
		base = mix(base, pattern_color * COLOR.rgb, mask);
		base = mix(base, base * 0.92, outside);
		pattern_glow = max(ring, dot_c) + frame * 0.6;
	}

	// ---- 高度图假 AO ----
	vec2 ao_uv = (v_world.xz - mv_ao_rect.xy) / mv_ao_rect.zw;
	float hmap = texture(mv_ao_map, ao_uv).r;
	float occ = clamp((hmap - v_world.y) * 0.8, 0.0, 1.0);
	occ *= smoothstep(-0.3, 0.02, v_world.y);
	base *= 1.0 - occ * mv_ao_strength * ao_amount * ao_mask;

	// ---- 世界 Y 渐变（越往下越偏深色） ----
	float g = smoothstep(mv_grad_range.x, mv_grad_range.y, v_world.y);
	base = mix(base, mv_deep_color * mix(vec3(1.0), base, 0.35), g * deep_amount);

	// ---- 高度雾 + 远景淡化 ----
	// 结果 = mix(mix(base, 雾色, fog), fade_color, fade)，用 ALBEDO/EMISSION 拆分以便阴影只作用于 base
	float fog = smoothstep(mv_fog_range.x, mv_fog_range.y, v_world.y);
	float keep = (1.0 - fog) * (1.0 - fade);
	ALBEDO = base * keep;
	float em_mask = pattern == 3 ? pattern_glow * (0.85 + 0.15 * sin(TIME * 2.6)) : 1.0;
	EMISSION = mv_fog_color * fog * (1.0 - fade) + fade_color * fade
		+ emission_color * emission_energy * glow * em_mask * keep;
}

void light() {
	// 只接收投射阴影：背光面（相对灯光）不再变暗，避免与三面定色重复
	float facing = smoothstep(0.0, 0.3, dot(NORMAL, LIGHT));
	float sh = mix(1.0, ATTENUATION, facing);
	vec3 tint = mix(mv_shadow_color, vec3(1.0), sh);
	DIFFUSE_LIGHT += tint * LIGHT_COLOR / PI;
}
