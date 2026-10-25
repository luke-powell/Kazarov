#version 460

// Logical 2D: x, y in the target's logical space, z the depth (1 near, 0 far).

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
layout(location = 3) in float a_fog;

layout(push_constant, std430) uniform Push {
    vec4 xform;
    vec4 uv_xform;
    uint texture_slot;
    uint palette_slot;
    uint sampler_slot;
    uint flags;
    uint alpha;
    uint fog_color;
    uint face;
    uint mesh_index;
    uint prog0_index;
    uint palette_index;
}
pc;

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec4 v_fog;
layout(location = 3) flat out vec4 v_fog_mode;

layout(location = 4) out vec3 v_air_transmission;
layout(location = 5) out vec3 v_air_light;
layout(location = 6) out vec2 v_tree_coverage;
layout(location = 7) out vec3 v_terrain_uv;
layout(location = 8) out vec3 v_terrain_normal;
layout(location = 9) flat out uint v_terrain_native;

void main() {
    v_terrain_uv=vec3(0.0);v_terrain_normal=vec3(0.0);v_terrain_native=0u;
    v_tree_coverage=vec2(0.0,1.0);
    v_air_transmission=vec3(1.0);v_air_light=vec3(0.0);
    gl_Position = vec4(a_position.xy * pc.xform.xy + pc.xform.zw, a_position.z, 1.0);
    v_color     = a_color;
    v_uv        = a_uv * pc.uv_xform.xy + pc.uv_xform.zw;
    v_fog       = vec4(a_fog, 0.0, 0.0, 0.0);
    v_fog_mode  = vec4(0.0, 0.0, -1.0, 0.0);
}
