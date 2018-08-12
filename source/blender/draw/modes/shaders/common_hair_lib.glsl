/**
 * Library to create hairs dynamically from control points.
 * This is less bandwidth intensive than fetching the vertex attributes
 * but does more ALU work per vertex. This also reduce the number
 * of data the CPU has to precompute and transfert for each update.
 **/

/**
 * hairThicknessRes : Subdiv around the hair.
 * 1 - Wire Hair: Only one pixel thick, independant of view distance.
 * 2 - Polystrip Hair: Correct width, flat if camera is parallel.
 * 3+ - Cylinder Hair: Massive calculation but potentially perfect. Still need proper support.
 **/
uniform int hairThicknessRes = 1;

/* Hair thickness shape. */
uniform float hairRadRoot = 0.01;
uniform float hairRadTip = 0.0;
uniform float hairRadShape = 0.5;
uniform bool hairCloseTip = true;

/* -- Per control points -- */
uniform samplerBuffer hairPointBuffer; /* RGBA32F */
#define point_position     xyz
#define point_time         w           /* Position along the hair length */

/* -- Per strands data -- */
uniform usamplerBuffer hairStrandBuffer; /* R32UI */
uniform usamplerBuffer hairIndexBuffer; /* R32UI */

/* Not used, use one buffer per uv layer */
//uniform samplerBuffer hairUVBuffer; /* RG32F */
//uniform samplerBuffer hairColBuffer; /* RGBA16 linear color */

void unpack_strand_data(uint data, out int strand_offset, out int strand_segments)
{
#if 0 /* Pack point count */
	// strand_offset = (data & 0x1FFFFFFFu);
	// strand_segments = 1u << (data >> 29u); /* We only need 3 bits to store subdivision level. */
#else
	strand_offset = int(data & 0x00FFFFFFu);
	strand_segments = int(data >> 24u);
#endif
}

int hair_get_strand_id(void)
{
	//return gl_VertexID / (hairStrandsRes * hairThicknessRes);
	uint strand_index = texelFetch(hairIndexBuffer, gl_VertexID).x;
	return int(strand_index);
}

/* -- Subdivision stage -- */
/**
 * We use a transform feedback to preprocess the strands and add more subdivision to it.
 * For the moment theses are simple smooth interpolation but one could hope to see the full
 * children particle modifiers being evaluated at this stage.
 *
 * If no more subdivision is needed, we can skip this step.
 **/

#ifdef HAIR_PHASE_SUBDIV
/**
 * Calculate segment and local time for interpolation
 */
void hair_get_interp_time(float local_time, int strand_segments, out int interp_segment, out float interp_time)
{
	float time_per_strand_seg = 1.0 / float(strand_segments);

	float ratio = local_time / time_per_strand_seg;
	interp_segment = int(ratio);
	interp_time = fract(ratio);
}

void hair_get_interp_attribs(out vec4 data0, out vec4 data1, out vec4 data2, out vec4 data3, out float interp_time)
{
	int strand_index = hair_get_strand_id();
	uint strand_data = texelFetch(hairStrandBuffer, strand_index).x;
	int strand_offset, strand_segments;
	unpack_strand_data(strand_data, strand_offset, strand_segments);

	float local_time = float(gl_VertexID - strand_offset) / float(strand_segments);
	int interp_segment;
	hair_get_interp_time(local_time, strand_segments, interp_segment, interp_time);
	int interp_point = interp_segment + strand_offset;

	data0 = texelFetch(hairPointBuffer, interp_point - 1);
	data1 = texelFetch(hairPointBuffer, interp_point);
	data2 = texelFetch(hairPointBuffer, interp_point + 1);
	data3 = texelFetch(hairPointBuffer, interp_point + 2);

	if (interp_segment <= 0) {
		/* root points. Need to reconstruct previous data. */
		data0 = data1 * 2.0 - data2;
	}
	if (interp_segment + 1 >= strand_segments) {
		/* tip points. Need to reconstruct next data. */
		data3 = data2 * 2.0 - data1;
	}
}
#endif

/* -- Drawing stage -- */
/**
 * For final drawing, the vertex index and the number of vertex per segment
 **/

#ifndef HAIR_PHASE_SUBDIV
int hair_get_base_id(void)
{
	return gl_VertexID / hairThicknessRes;
}

/* Copied from cycles. */
float hair_shaperadius(float shape, float root, float tip, float time)
{
	float radius = 1.0 - time;

	if (shape < 0.0) {
		radius = pow(radius, 1.0 + shape);
	}
	else {
		radius = pow(radius, 1.0 / (1.0 - shape));
	}

	if (hairCloseTip && (time > 0.99)) {
		return 0.0;
	}

	return (radius * (root - tip)) + tip;
}

void hair_get_pos_tan_binor_time(
        bool is_persp, vec3 camera_pos, vec3 camera_z,
        out vec3 wpos, out vec3 wtan, out vec3 wbinor, out float time, out float thickness, out float thick_time)
{
	int id = hair_get_base_id();
	vec4 data = texelFetch(hairPointBuffer, id);
	wpos = data.point_position;
	time = data.point_time;
	if (time == 0.0) {
		/* Hair root */
		wtan = texelFetch(hairPointBuffer, id + 1).point_position - wpos;
	}
	else {
		wtan = wpos - texelFetch(hairPointBuffer, id - 1).point_position;
	}

	vec3 camera_vec = (is_persp) ? wpos - camera_pos : -camera_z;
	wbinor = normalize(cross(camera_vec, wtan));

	thickness = hair_shaperadius(hairRadShape, hairRadRoot, hairRadTip, time);

	if (hairThicknessRes > 1) {
		thick_time = float(gl_VertexID % hairThicknessRes) / float(hairThicknessRes - 1);
		thick_time = thickness * (thick_time * 2.0 - 1.0);

		wpos += wbinor * thick_time;
	}
}

vec2 hair_get_customdata_vec2(const samplerBuffer cd_buf)
{
	int strand_index = hair_get_strand_id();
	return texelFetch(cd_buf, strand_index).rg;
}

vec3 hair_get_customdata_vec3(const samplerBuffer cd_buf)
{
	int strand_index = hair_get_strand_id();
	return texelFetch(cd_buf, strand_index).rgb;
}

vec4 hair_get_customdata_vec4(const samplerBuffer cd_buf)
{
	int strand_index = hair_get_strand_id();
	return texelFetch(cd_buf, strand_index).rgba;
}

vec3 hair_get_strand_pos()
{
	int id = hair_get_base_id();
	return texelFetch(hairPointBuffer, id).point_position;
}

#endif
