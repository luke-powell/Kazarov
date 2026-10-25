#version 460

layout(location = 0) in vec3 vertex_position;
layout(location = 1) in vec3 vertex_normal;
layout(location = 2) in vec2 a_uv;
layout(location = 3) in vec4 vertex_color;
layout(location = 4) in vec3 instance_root;
layout(location = 5) in vec3 instance_rotation;
layout(location = 6) in vec4 instance_color;
vec3 a_position,a_normal;
vec4 a_color;
vec2 tree_atlas_uv;

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

// gfx::MeshConstants. Colours are modulations with 1.0 as GS 0x80. Each chunk's records form one array;
// the draw's record is at pc.mesh_index.
struct MeshConstantsData {
    mat4 mvp;
    mat3 normal_matrix;
    vec4 light_direction[4];
    vec4 light_color[4];
    vec4 ambient;
    vec4 diffuse;
    vec4 ambient_material;
    vec4 specular;
    vec4 fog;
    vec4 clip_plane[2];
    vec4 world_uv[2];
    uint flags;
    uint light_count;
};

layout(set = 1, binding = 0, std430) readonly buffer MeshConstantsArray {
    MeshConstantsData meshes[];
};

#define mc meshes[pc.mesh_index]

const uint kLit         = 1u;
const uint kVertexColor = 2u;
const uint kFog         = 4u;
const uint kShadow      = 8u;
const uint kClip0       = 16u;
const uint kClip1       = 32u;
const uint kScreenUv    = 64u;
const uint kWorldUv     = 128u;
const uint kAtmosphere = 512u;

// A byte colour (0..255 as 0..1) read as a modulation with 0x80 as 1.0.
const float kModulate = 255.0 / 128.0;

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
out float gl_ClipDistance[2];

// Integrate a plane-parallel atmosphere with exponential Rayleigh (8 km) and
// aerosol (1.2 km) density profiles. Beer-Lambert extinction and single solar
// scattering; no artistic distance thresholds, fixed fog colour, or fog cutoff.
void atmosphere() {
    v_air_transmission=vec3(1.0);v_air_light=vec3(0.0);
    if((mc.flags & kAtmosphere)==0u)return;
    vec3 camera=mc.clip_plane[0].xyz;
    float metres=mc.clip_plane[0].w;
    vec3 ray=(a_position-camera)*metres;
    float distance=length(ray);
    if(distance<0.001)return;
    vec3 direction=ray/distance;
    vec3 sun=normalize(mc.clip_plane[1].xyz);
    // Standard sea-level Rayleigh coefficients for red, green, blue wavelengths.
    vec3 betaR=vec3(5.8e-6,13.5e-6,33.1e-6);
    vec3 betaM=vec3(max(mc.clip_plane[1].w,0.0));
    float mu=dot(direction,sun), g=0.76;
    float phaseR=3.0/(16.0*3.14159265)*(1.0+mu*mu);
    float phaseM=(1.0-g*g)/(4.0*3.14159265*pow(1.0+g*g-2.0*g*mu,1.5));
    // Density changes with altitude, not horizontal distance. Four midpoint
    // samples suffice for nearby foliage; retain finer integration for rays
    // crossing multiple aerosol scale heights. This changes numerical work,
    // not the physical extinction or the visible horizon.
    int samples=int(clamp(ceil(abs(ray.y)/1200.0*4.0),4.0,16.0));
    float ds=distance/float(samples);
    // Solar irradiance in the renderer's scene exposure, driven by the game's light.
    vec3 solar=mc.light_color[0].rgb*10.0;
    for(int i=0;i<samples;i++) {
        float altitude=max(0.0,camera.y*metres+direction.y*ds*(float(i)+0.5));
        vec3 r=betaR*exp(-altitude/8000.0);
        vec3 m=betaM*exp(-altitude/1200.0);
        vec3 extinction=r+m*1.11; // 0.9 aerosol single-scattering albedo.
        vec3 stepTransmission=exp(-extinction*ds);
        vec3 towardSun=exp(-(r*8000.0+m*1.11*1200.0)/max(sun.y,0.03));
        if(sun.y<=0.0)towardSun=vec3(0.0);
        vec3 source=(r*phaseR+m*phaseM)/max(extinction,vec3(1e-20));
        v_air_light+=v_air_transmission*(vec3(1.0)-stepTransmission)*source*towardSun*solar;
        v_air_transmission*=stepTransmission;
    }
}

void main() {
    // Reject a whole tree using its conservative prototype sphere BEFORE the
    // atmospheric integration. The test is identical for every vertex of an
    // instance, so partially visible triangles never get torn apart. Trees
    // below the existing zero-coverage threshold are already represented by
    // canopy; this removes invisible work without shortening the LOD range.
    if((mc.flags & (32768u|1024u))==(32768u|1024u) && mc.world_uv[1].z>0.0) {
        float radius=mc.world_uv[1].z*instance_rotation.z;
        vec4 centre=mc.mvp*vec4(instance_root,1.0);
        mat4 rows=transpose(mc.mvp);
        float rw=radius*length(rows[3].xyz);
        bool outside=centre.w+rw<=0.0;
        for(int axis=0;axis<2;axis++) {
            outside=outside || centre[axis]+1.2*centre.w < -radius*length(rows[axis].xyz+1.2*rows[3].xyz);
            outside=outside || 1.2*centre.w-centre[axis] < -radius*length(1.2*rows[3].xyz-rows[axis].xyz);
        }
        float height=round(instance_color.r*255.0)+256.0*round(instance_color.g*255.0);
        if((mc.flags&262144u)==0u)outside=outside || height*mc.world_uv[0].z/max(centre.w-rw,1.0)<=0.15;
        if((mc.flags&131072u)!=0u)outside=outside || height*mc.world_uv[0].z/max(centre.w-rw,1.0)<=2.0;
        if((mc.flags&65536u)!=0u && (mc.flags&262144u)==0u)outside=outside || (centre.w>rw && height*mc.world_uv[0].z/(centre.w+rw)>=4.0);
        if(outside) {
            gl_Position=vec4(2.0,2.0,2.0,1.0);
            gl_ClipDistance[0]=1.0;gl_ClipDistance[1]=1.0;
            return;
        }
    }
    a_position=vertex_position;a_normal=vertex_normal;a_color=vertex_color;
    if((mc.flags & 32768u)!=0u){
        float cs=instance_rotation.x,sn=instance_rotation.y,scale=instance_rotation.z;
        a_position=instance_root+vec3(cs*vertex_position.x+sn*vertex_position.z,scale*vertex_position.y,-sn*vertex_position.x+cs*vertex_position.z);
        a_normal=vec3((cs*vertex_normal.x+sn*vertex_normal.z)/scale,vertex_normal.y,(-sn*vertex_normal.x+cs*vertex_normal.z)/scale);
        a_color=instance_color;
        if((mc.flags&65536u)!=0u){
            // Procedural corners keep the impostor independent of the source
            // model's vertex attributes; the indexed quad is always 0..3.
            vec2 corner=vec2((gl_VertexIndex&1)==0?-1.0:1.0,(gl_VertexIndex&2)==0?-1.0:1.0);
            vec3 centre=instance_root+vec3(0.0,mc.world_uv[1].x*scale,0.0);
            vec3 view=normalize(mc.clip_plane[0].xyz-centre);
            vec3 right=normalize(vec3(view.z+0.000001,0.0,-view.x));
            vec3 up=cross(view,right);
            a_position=centre+mc.world_uv[1].y*scale*(right*corner.x+up*corner.y);
            a_normal=vec3(0.0,1.0,0.0);
            float yaw=atan(view.x,view.z)-atan(sn,cs);
            float angle=mod(floor(yaw*(8.0/6.28318530718)+0.5),8.0);
            float elevation=clamp(floor(asin(clamp(view.y,-1.0,1.0))*(2.0/1.57079632679)+0.5),0.0,2.0);
            tree_atlas_uv=(vec2(angle,elevation)+vec2(corner.x+1.0,1.0-corner.y)*.5)/vec2(8.0,3.0);
        }
    }
    v_terrain_uv=vec3(0.0);v_terrain_normal=vec3(0.0);v_terrain_native=((mc.flags & 524288u)!=0u ? 1u : 0u) | ((mc.flags & 1048576u)!=0u ? 2u : 0u);
    v_tree_coverage=vec2(0.0,1.0);
    atmosphere();
    vec4 position = vec4(a_position, 1.0);
    vec4 clip     = mc.mvp * position;
    // The GS rasterises vertices at 1/16-pixel precision. Separate ground cells can reach the
    // same screen edge through different transforms, whose last floating-point bits may differ.
    // Quantise in logical-pixel units before viewport conversion so both edges use one location.
    vec2 logical_pixel_ndc = pc.xform.xy;
    // At the eye plane keep the homogeneous position: perspective division is undefined.
    if (clip.w != 0.0) {
        vec2 ndc = clip.xy / clip.w;
        ndc = round(ndc / (logical_pixel_ndc / 16.0)) * (logical_pixel_ndc / 16.0);
        clip.xy = ndc * clip.w;
    }
    gl_Position   = clip;
    if((mc.flags & 16384u)!=0u) {
        float d=length(a_position-mc.clip_plane[0].xyz);
        v_tree_coverage=vec2(0.0,1.0-smoothstep(1500.0,2400.0,d));
    }
    if((mc.flags & 1024u)!=0u) {
        float d=length(a_position-mc.clip_plane[0].xyz);
        float a=smoothstep(1800.0,2600.0,d),b=smoothstep(5000.0,7000.0,d);
        vec3 weights=vec3(1.0-a,a*(1.0-b),b);
        uint available=uint(mc.world_uv[0].y);
        for(int i=0;i<3;i++)if((available&(1u<<uint(i)))==0u)weights[i]=0.0;
        float sum=weights.x+weights.y+weights.z;
        if(sum<0.0001) {
            weights=vec3(0.0);
            for(int i=2;i>=0;i--)if((available&(1u<<uint(i)))!=0u){weights[i]=1.0;break;}
        } else weights/=sum;
        int level=int(mc.world_uv[0].x);
        float begin=level==0?0.0:level==1?weights.x:weights.x+weights.y;
        // Every instance survives until its own projected height is subpixel.
        float height=round(a_color.r*255.0)+256.0*round(a_color.g*255.0);
        float pixels=height*mc.world_uv[0].z/max(clip.w,1.0);
          float coverage=smoothstep(0.15,0.35,pixels)*mc.world_uv[0].w;
        v_tree_coverage=vec2(begin,begin+weights[level])*coverage;
        float detail=smoothstep(2.0,4.0,pixels);
        if((mc.flags&65536u)!=0u)v_tree_coverage=vec2(0.0,coverage*(1.0-detail));
        if((mc.flags&131072u)!=0u)v_tree_coverage=vec2(coverage*(1.0-detail),coverage);
    }

    // Ring ownership selects exactly one representation. Camera-relative
    // fade thresholds must not erase that representation when looking down.
    if((mc.flags&262144u)!=0u && (mc.flags&1024u)!=0u)
        v_tree_coverage=vec2(0.0,1.0);

    gl_ClipDistance[0] = (mc.flags & kClip0) != 0u ? dot(mc.clip_plane[0], position) : 1.0;
    gl_ClipDistance[1] = (mc.flags & kClip1) != 0u ? dot(mc.clip_plane[1], position) : 1.0;

    vec3  color = mc.diffuse.rgb;
    float alpha = mc.diffuse.a;
    if ((mc.flags & kShadow) == 0u) {
        if ((mc.flags & kLit) != 0u) {
            // Native terrain joins can carry interpolated authored normals:
            // preserving their length preserves the original vertex lighting.
            vec3 normal = mc.normal_matrix * a_normal;
            if((mc.flags & 524288u)==0u)normal=normalize(normal);
            vec3 light  = vec3(0.0);
            for (uint i = 0u; i < min(mc.light_count, 4u); i++) {
                light += max(dot(normal, -mc.light_direction[i].xyz), 0.0) * mc.light_color[i].rgb;
            }
            color = mc.ambient.rgb * mc.ambient_material.rgb + light * mc.diffuse.rgb;
        }
        if ((mc.flags & kVertexColor) != 0u) {
            color *= a_color.rgb * kModulate;
            alpha *= a_color.a * kModulate;
        }
    }

    // Back to GS bytes, saturated as VU1 saturates its colour output.
    v_color = clamp(vec4(color, alpha) / kModulate, 0.0, 1.0);
    if((mc.flags & 2048u)!=0u) {
        float height=round(a_color.r*255.0)+256.0*round(a_color.g*255.0);
        float pixels=height*mc.world_uv[0].z/max(clip.w,1.0);
        float regional=smoothstep(mc.world_uv[1].w,mc.world_uv[1].w*1.4,length(a_position-mc.clip_plane[0].xyz));
        if ((mc.flags & 4096u)!=0u) {
            // Persistent forest ground coverage must not disappear while the
            // independent object queue is still generating visible trees.
            v_color.a *= a_color.a*kModulate*(1.0-smoothstep(0.15,0.35,pixels)*mc.world_uv[0].w);
        } else {
            v_color.a *= (1.0-smoothstep(0.75,1.5,pixels))*mc.world_uv[0].w*(1.0-regional);
        }
    }
    if((mc.flags&262144u)!=0u && (mc.flags&4096u)!=0u)
        v_color.a=clamp(alpha/kModulate,0.0,1.0)*(1.0-mc.world_uv[0].w);
    v_uv    = (mc.flags & kWorldUv) != 0u ? vec2(dot(mc.world_uv[0], position), dot(mc.world_uv[1], position)) :
              (mc.flags & kScreenUv) != 0u ? clip.xy / clip.w * 0.5 + 0.5 + a_uv : a_uv;
    if((mc.flags&65536u)!=0u)v_uv=tree_atlas_uv;
    if((mc.flags & 8192u)!=0u){
        v_terrain_uv=vec3(v_uv.x,a_position.y*mc.world_uv[0].x,v_uv.y);
        v_terrain_normal=a_normal;
    }
    v_fog_mode = vec4(mc.fog.w, mc.fog.z, 0.0, 1.0);
    if ((mc.flags & kFog) == 0u) {
        v_fog = vec4(1.0, 0.0, 0.0, 0.0);
        v_fog_mode.z = -2.0;
    } else if (mc.fog.y == 0.0) {
        v_fog = vec4(0.0);
        v_fog_mode.w = min(max(mc.fog.x, mc.fog.z), mc.fog.w) / 255.0;
        v_fog_mode.z = -2.0;
    } else {
        // Reverse-Z: only near/eye crossings need fresh fog; far-plane vertices retain their F.
        // The full homogeneous norm keeps the weight continuous at z=w=0 with nonzero x/y.
        float clip_scale = max(max(abs(clip.x), abs(clip.y)), max(abs(clip.z), abs(clip.w)));
        float marker = clip.z > clip.w ? min((clip.z - clip.w) / clip_scale, 1.0) : 0.0;
        float fog = clip.w <= 0.0 ? 0.0 : min(max(mc.fog.x + mc.fog.y / clip.w, mc.fog.z), mc.fog.w);
        float weight = max(clip.w, 0.0) * (1.0 - marker);
        v_fog = vec4(fog * weight, mc.fog.x * clip.w + mc.fog.y, marker, weight);
    }
}
