
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <GL/gl.h>

#ifndef GL_VERSION_1_0
#define GL_VERSION_1_0 1
#endif

#define MAX_GL_TEXPARAMETER_COUNT	4

extern int gl_texparameter_count(GLenum pname);

#define MAX_GL_TEXENV_COUNT	4

extern int gl_texenv_count(GLenum pname);

#define MAX_GL_TEXGEN_COUNT	4

extern int gl_texgen_count(GLenum pname);

#define MAX_GL_MATERIAL_COUNT	4

extern int gl_material_count(GLenum pname);

#define MAX_GL_MAP_COUNT	4

extern int gl_map_count(GLenum target, GLenum query);

#define MAX_GL_LIGHT_COUNT	4

extern int gl_light_count(GLenum pname);

#define MAX_GL_LIGHTMODEL_COUNT	4

extern int gl_lightmodel_count(GLenum pname);

#define MAX_GL_FOG_COUNT	4

extern int gl_fog_count(GLenum pname);

#define MAX_GL_GET_COUNT	16

extern int gl_get_count(GLenum param);

extern int gl_pixelmap_size(GLenum map);

extern int gl_state_count(GLenum state);

enum {
	gl_pixelbuffer_pack = 1,
	gl_pixelbuffer_unpack = 2,
};

extern unsigned long gl_pixelbuffer_size(
	GLenum format,
	GLsizei	width,
	GLsizei	height,
	GLenum	type,
	int mode);

extern GLvoid * pack_image_ST(SV ** stack, int count, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, int mode);
extern GLvoid * allocate_image_ST(GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, int mode);

extern SV ** unpack_image_ST(SV ** SP, void * data, 
GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, int mode);

extern GLvoid * ELI(SV * sv, GLsizei width, GLsizei height, GLenum format, GLenum type, int mode);

extern GLvoid * EL(SV * sv, int needlen);

extern int gl_type_size(GLenum type);

extern int gl_component_count(GLenum format, GLenum type);

struct oga_struct {
	int type_count, item_count;
	GLenum * types;
	GLint * type_offset;
	int total_types_width;
	void * data;
	int data_length;
	
	int free_data;
};

typedef struct oga_struct oga_struct;

typedef oga_struct * OpenGL__Array;
