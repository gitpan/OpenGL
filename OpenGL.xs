/*  Copyright (c) 1998 Kenneth Albanowski. All rights reserved.
 *  Copyright (c) 2007 Bob Free. All rights reserved.
 *  This program is free software; you can redistribute it and/or
 *  modify it under the same terms as Perl itself.
 */


#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#ifdef HAVE_GL
#include "gl_util.h"
#endif

#ifdef HAVE_GLX
#include "glx_util.h"
#endif

#ifdef HAVE_GLU
#include "glu_util.h"
#endif

#ifdef HAVE_GLUT
#include "glut_util.h"
#endif



static int
not_here(s)
char *s;
{
    croak("%s not implemented on this architecture", s);
    return -1;
}


/* GLUT on OS/2 PM runs callbacks from a secondary thread.  This thread
   is not instrumented to run EMX CRTL functions.  Basically, no Perl
   function may be run from this thread.
   We create a ternary thread via CRTL _beginthread() call, and communicate
   the requests to this thread via inter-thread communication (ITC).  */

#ifndef __PM__
#  define DO_perl_call_sv(handler, flag) perl_call_sv(handler, flag)
#  define ENSURE_callback_thread
#  define GLUT_PUSH_NEW_SV(sv)		XPUSHs(sv_2mortal(newSVsv(sv)))
#  define GLUT_PUSH_NEW_IV(i)		XPUSHs(sv_2mortal(newSViv(i)))
#  define GLUT_PUSH_NEW_U8(c)		XPUSHs(sv_2mortal(newSViv((int)c)))
#  define GLUT_EXTEND_STACK(sp,n)
#  define GLUT_PUSHMARK(sp)		PUSHMARK(sp)
#else

#  define GLUT_PUSHMARK(sp)

#  include "sys/builtin.h"
#  include "sys/fmutex.h"

#  include "os2pm_X.h"

#  define DO_perl_call_sv(handler, flag) 				\
    STMT_START {   	PUSHs(handler);					\
			PUTBACK;					\
			extend_by = 0;					\
			RUN_perl_call_sv();				\
    } STMT_END

#  define GLUT_START_PUSHING		7
#  define GLUT_PUSHING_IVP		17
#  define GLUT_PUSHING_U8		27
#  define GLUT_PUSHING_SV		37

#  define GLUT_EXTEND_STACK(p,n)					\
    STMT_START {   if (PL_stack_max - p < 2*(n)+4) {			\
		     extend_by = 2*(n)+4;				\
		     RUN_perl_call_sv();				\
		   }							\
		   SPAGAIN;						\
		   PUSHs((SV*)GLUT_START_PUSHING);			\
    } STMT_END

#  define GLUT_PUSH_NEW_SV(sv)	(PUSHs(sv), PUSHs((SV*)GLUT_PUSHING_SV))
#  define GLUT_PUSH_NEW_IV(i)	(PUSHs((SV*)&i), PUSHs((SV*)GLUT_PUSHING_IVP))
#  define GLUT_PUSH_NEW_U8(c)	(PUSHs((SV*)(int)c), PUSHs((SV*)GLUT_PUSHING_U8))

_fmutex run_mutex, result_mutex;
static int worker_started;
static int extend_by;

void
RUN_perl_call_sv(void)
{
    char *s = NULL;
    
    if (_fmutex_release(&run_mutex))
	s = "Error unlocking the callback thread";
    /* result_mutex is requested on entry!  Block until looper finishes. */
    else if (_fmutex_request(&result_mutex, _FMR_IGNINT))
	s = "Error requesting the callback thread";
    if (s)
	write(2, s, strlen(s));
    return;
}

void
callback_thread_looper(void *dummy)
{
    while (1) {
	/* It is requested already!  Wait until somebody requests a run */
	if (_fmutex_request(&run_mutex, _FMR_IGNINT)) {
	    warn("Error unlocking in the callback thread");
	    worker_started = 0;
	    return;
	}
	if (extend_by) {  /* Need to extend the stack */
	    dSP;

	    EXTEND(sp, extend_by);
	} else {
	    dSP;
	    SV* handler = POPs;
	    STRLEN n_a;
	    SV **last = sp, **f;

	    /* The rest is put on stack in a "raw" pointer form */
	    while (1) {
		switch ((IV)*sp) {
		case GLUT_START_PUSHING:
		    goto start_found;
		    break;
		case GLUT_PUSHING_IVP:
		case GLUT_PUSHING_SV:
		case GLUT_PUSHING_U8:
		    break;
		default:
		    croak("Panic: broken descriptor/down when ITC for Glut: %#lx", (unsigned long)*sp);
		    break;
		}
		sp -= 2;
	    }
	  start_found:
	    f = sp + 1;
	    sp--;
	    PUSHMARK(sp);
	    while (f < last) {
		switch ((IV)f[1]) {
		case GLUT_PUSHING_IVP:
		    PUSHs(sv_2mortal(newSViv(*(IV*)*f)));
		    break;
		case GLUT_PUSHING_U8:
		    PUSHs(sv_2mortal(newSViv((IV)*f)));
		    break;
		case GLUT_PUSHING_SV:
		    PUSHs(sv_2mortal(newSVsv(*f)));
		    break;
		default:
		    croak("Panic: broken descriptor/up when ITC for Glut: %#lx", (unsigned long)f[1]);
		    break;
		}
		f += 2;
	    }
	    PUTBACK;
	    perl_call_sv(handler, G_DISCARD|G_EVAL);
	    if (SvTRUE(ERRSV))
		fprintf(stderr, "Error in a GLUT Callback: %s", SvPV(ERRSV, n_a));
	}
	if (_fmutex_release(&result_mutex)) {
	    warn("Error in a callback thread");
	    worker_started = 0;
	    return;
	}	
    }
}

#  define ENSURE_callback_thread					\
	if (!worker_started)						\
	    start_callback_thread()

void
start_callback_thread()
{
    unsigned long rc;

    if (worker_started)
	return;
    if (  CheckOSError(_fmutex_create(&run_mutex, 0))
	  || CheckOSError(_fmutex_create(&result_mutex, 0))
	  || CheckOSError(_fmutex_request(&run_mutex, _FMR_IGNINT))
	  || CheckOSError(_fmutex_request(&result_mutex, _FMR_IGNINT)))
	croak("Error creating semaphores");
    worker_started = _beginthread(&callback_thread_looper, NULL,
				   8*1024*1024, NULL);
    if (worker_started == -1) {
	worker_started = 0;
	croak("Error creating callback thread");
    }
}

#endif	/* __PM__ */

#define i(test) if (strEQ(name, #test)) return newSViv((int)test);
#define f(test) if (strEQ(name, #test)) return newSVnv((double)test);

#ifdef __PM__
#endif

static SV *
neoconstant(char * name, int arg)
{
#include "gl_const.h"
#include "glu_const.h"
#include "glut_const.h"
#include "glx_const.h"
#include "glpm_const.h"
	;
	return 0;
}

#undef i
#undef f

/* Note: this is caching procs once for all contexts */
/* !!! This should instead cache per context */
#ifdef HAVE_GL
#ifdef _WIN32
#define loadProc(proc,name) \
{ \
  if (!proc) \
  { \
    proc = (void *)wglGetProcAddress(name); \
    if (!proc) croak(name " is not supported by this renderer"); \
  } \
}
#define testProc(proc,name) ((proc) ? 1 : !!(proc = (void *)wglGetProcAddress(name)))
#else
#define loadProc(proc,name)
#define testProc(proc,name) 1
#endif
#endif


#ifdef HAVE_GLX
#  define HAVE_GLpc			/* Perl interface */
#  define nativeWindowId(d, w)	(w)
static Bool WaitForNotify(Display *d, XEvent *e, char *arg) {
    return (e->type == MapNotify) && (e->xmap.window == (Window)arg);
}
#  define glpResizeWindow(s1,s2,w,d)	XResizeWindow(d,w,s1,s2)
#  define glpMoveWindow(s1,s2,w,d)		XMoveWindow(d,w,s1,s2)
#  define glpMoveResizeWindow(s1,s2,s3,s4,w,d)	XMoveResizeWindow(d,w,s1,s2,s3,s4)
#endif	/* defined HAVE_GLX */ 


#ifdef __PM__

#  define HAVE_GLpc			/* Perl interface */
#  define auxXWindow()	(croak("Not implemented: auxXWindow"),0)

HMQ hmq;
AV *EventAv;
unsigned long LastEventMask;	/* !! Common for all the windows */
Display myDisplay;

#else
#  define InitSys()
#endif	/* defined __PM__ */ 

#ifdef HAVE_GLpc

#  define NUM_ARG 7

Display *dpy;
int dpy_open;
XVisualInfo *vi;
Colormap cmap;
XSetWindowAttributes swa;
Window win;
GLXContext cx;

static int default_attributes[] = { GLX_DOUBLEBUFFER, GLX_RGBA };

#endif	/* defined HAVE_GLpc */ 

static int DBUFFER_HACK = 0;
#define __had_dbuffer_hack() (DBUFFER_HACK)

#define PackCallbackST(av,first)					\
	if (SvROK(ST(first)) && (SvTYPE(SvRV(ST(first))) == SVt_PVAV)){	\
		int i;							\
		AV * x = (AV*)SvRV(ST(first));				\
		for(i=0;i<=av_len(x);i++) {				\
			av_push(av, newSVsv(*av_fetch(x, i, 0)));	\
		}							\
	} else {							\
		int i;							\
		for(i=first;i<items;i++)				\
			av_push(av, newSVsv(ST(i)));			\
	}

#ifdef GLUT_API_VERSION

static AV * glut_handlers = 0;

static void set_glut_win_handler(int win, int type, SV * data)
{
	SV ** h;
	AV * a;
	
	if (!glut_handlers)
		glut_handlers = newAV();
	
	h = av_fetch(glut_handlers, win, FALSE);
	
	if (!h) {
		a = newAV();
		av_store(glut_handlers, win, newRV_inc((SV*)a));
		SvREFCNT_dec(a);
	} else if (!SvOK(*h) || !SvROK(*h))
		croak("Unable to establish glut handler");
	else 
		a = (AV*)SvRV(*h);
	
	av_store(a, type, newRV_inc(data));
	SvREFCNT_dec(data);
}

static SV * get_glut_win_handler(int win, int type)
{
	SV ** h;
	
	if (!glut_handlers)
		croak("Unable to locate glut handler");
	
	h = av_fetch(glut_handlers, win, FALSE);

	if (!h || !SvOK(*h) || !SvROK(*h))
		croak("Unable to locate glut handler");
	
	h = av_fetch((AV*)SvRV(*h), type, FALSE);
	
	if (!h || !SvOK(*h) || !SvROK(*h))
		croak("Unable to locate glut handler");

	return SvRV(*h);
}

static void destroy_glut_win_handlers(int win)
{
	SV ** h;
	
	if (!glut_handlers)
		return;
	
	h = av_fetch(glut_handlers, win, FALSE);
	
	if (!h || !SvOK(*h) || !SvROK(*h))
		return;

	av_store(glut_handlers, win, newSVsv(&PL_sv_undef));
}

static void destroy_glut_win_handler(int win, int type)
{
	SV ** h;
	AV * a;
	
	if (!glut_handlers)
		glut_handlers = newAV();
	
	h = av_fetch(glut_handlers, win, FALSE);
	
	if (!h || !SvOK(*h) || !SvROK(*h))
		return;

	a = (AV*)SvRV(*h);
	
	av_store(a, type, newSVsv(&PL_sv_undef));
}


#define begin_decl_gwh(type, params, nparam)				\
									\
static void generic_glut_ ## type ## _handler params			\
{									\
	int win = glutGetWindow();					\
	AV * handler_data = (AV*)get_glut_win_handler(win, HANDLE_GLUT_ ## type);\
	SV * handler;							\
	int i;								\
	dSP;								\
									\
	handler = *av_fetch(handler_data, 0, 0);			\
									\
	GLUT_PUSHMARK(sp);						\
	GLUT_EXTEND_STACK(sp,av_len(handler_data)+nparam);		\
	for (i=1;i<=av_len(handler_data);i++)				\
		GLUT_PUSH_NEW_SV(*av_fetch(handler_data, i, 0));

#define end_decl_gwh()							\
	PUTBACK;							\
	DO_perl_call_sv(handler, G_DISCARD);				\
}

#define decl_gwh_xs(type)						\
	{								\
		int win = glutGetWindow();				\
									\
		if (!handler || !SvOK(handler)) {			\
			destroy_glut_win_handler(win, HANDLE_GLUT_ ## type);\
			glut ## type ## Func(NULL);			\
		} else {						\
			AV * handler_data = newAV();			\
									\
			PackCallbackST(handler_data, 0);		\
									\
			set_glut_win_handler(win, HANDLE_GLUT_ ## type, (SV*)handler_data);\
									\
			glut ## type ## Func(generic_glut_ ## type ## _handler);\
		}							\
	ENSURE_callback_thread;}

#define decl_gwh_xs_nullfail(type, fail)				\
	{								\
		int win = glutGetWindow();				\
									\
		if (!handler || !SvOK(handler)) {			\
			croak fail;					\
		} else {						\
			AV * handler_data = newAV();			\
									\
			PackCallbackST(handler_data, 0);		\
									\
			set_glut_win_handler(win, HANDLE_GLUT_ ## type, (SV*)handler_data);\
									\
			glut ## type ## Func(generic_glut_ ## type ## _handler);\
		}							\
	ENSURE_callback_thread;}


#define decl_ggh_xs(type)						\
	{								\
		if (glut_ ## type ## _handler_data)			\
			SvREFCNT_dec(glut_ ## type ## _handler_data);	\
									\
		if (!handler || !SvOK(handler)) {			\
			glut_ ## type ## _handler_data = 0;		\
			glut ## type ## Func(NULL);			\
		} else {						\
			AV * handler_data = newAV();			\
									\
			PackCallbackST(handler_data, 0);		\
									\
			glut_ ## type ## _handler_data = handler_data;	\
									\
			glut ## type ## Func(generic_glut_ ## type ## _handler);\
		}							\
	ENSURE_callback_thread;}


#define begin_decl_ggh(type, params, nparam)				\
									\
static AV * glut_ ## type ## _handler_data = 0;				\
									\
static void generic_glut_ ## type ## _handler params			\
{									\
	AV * handler_data = glut_ ## type ## _handler_data;		\
	SV * handler;							\
	int i;								\
	dSP;								\
									\
	handler = *av_fetch(handler_data, 0, 0);			\
									\
	GLUT_PUSHMARK(sp);						\
	GLUT_EXTEND_STACK(sp,av_len(handler_data)+nparam);		\
	for (i=1;i<=av_len(handler_data);i++)				\
		GLUT_PUSH_NEW_SV(*av_fetch(handler_data, i, 0));

#define end_decl_ggh()							\
	PUTBACK;							\
	DO_perl_call_sv(handler, G_DISCARD);				\
}

enum {
	HANDLE_GLUT_Display,
	HANDLE_GLUT_OverlayDisplay,
	HANDLE_GLUT_Reshape,
	HANDLE_GLUT_Keyboard,
	HANDLE_GLUT_Mouse,
	HANDLE_GLUT_Motion,
	HANDLE_GLUT_PassiveMotion,
	HANDLE_GLUT_Entry,
	HANDLE_GLUT_Visibility,
	HANDLE_GLUT_Special,
	HANDLE_GLUT_SpaceballMotion,
	HANDLE_GLUT_SpaceballRotate,
	HANDLE_GLUT_SpaceballButton,
	HANDLE_GLUT_ButtonBox,
	HANDLE_GLUT_Dials,
	HANDLE_GLUT_TabletMotion,
	HANDLE_GLUT_TabletButton
};

begin_decl_gwh(Display, (void), 0)
end_decl_gwh()

begin_decl_gwh(OverlayDisplay, (void), 0)
end_decl_gwh()

begin_decl_gwh(Reshape, (int width, int height), 2)
	GLUT_PUSH_NEW_IV(width);
	GLUT_PUSH_NEW_IV(height);
end_decl_gwh()

begin_decl_gwh(Keyboard, (unsigned char key, int width, int height), 3)
	GLUT_PUSH_NEW_U8(key);
	GLUT_PUSH_NEW_IV(width);
	GLUT_PUSH_NEW_IV(height);
end_decl_gwh()

begin_decl_gwh(Mouse, (int button, int state, int x, int y), 4)
	GLUT_PUSH_NEW_IV(button);
	GLUT_PUSH_NEW_IV(state);
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
end_decl_gwh()

begin_decl_gwh(PassiveMotion, (int x, int y), 2)
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
end_decl_gwh()

begin_decl_gwh(Motion, (int x, int y), 2)
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
end_decl_gwh()

begin_decl_gwh(Visibility, (int state), 1)
	GLUT_PUSH_NEW_IV(state);
end_decl_gwh()

begin_decl_gwh(Entry, (int state), 1)
	GLUT_PUSH_NEW_IV(state);
end_decl_gwh()

begin_decl_gwh(Special, (int key, int width, int height), 3)
	GLUT_PUSH_NEW_IV(key);
	GLUT_PUSH_NEW_IV(width);
	GLUT_PUSH_NEW_IV(height);
end_decl_gwh()

begin_decl_gwh(SpaceballMotion, (int x, int y, int z), 3)
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
	GLUT_PUSH_NEW_IV(z);
end_decl_gwh()

begin_decl_gwh(SpaceballRotate, (int x, int y, int z), 3)
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
	GLUT_PUSH_NEW_IV(z);
end_decl_gwh()

begin_decl_gwh(SpaceballButton, (int button, int state), 2)
	GLUT_PUSH_NEW_IV(button);
	GLUT_PUSH_NEW_IV(state);
end_decl_gwh()

begin_decl_gwh(ButtonBox, (int button, int state), 2)
	GLUT_PUSH_NEW_IV(button);
	GLUT_PUSH_NEW_IV(state);
end_decl_gwh()

begin_decl_gwh(Dials, (int dial, int value), 2)
	GLUT_PUSH_NEW_IV(dial);
	GLUT_PUSH_NEW_IV(value);
end_decl_gwh()

begin_decl_gwh(TabletMotion, (int x, int y), 2)
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
end_decl_gwh()

begin_decl_gwh(TabletButton, (int button, int state, int x, int y), 4)
	GLUT_PUSH_NEW_IV(button);
	GLUT_PUSH_NEW_IV(state);
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
end_decl_gwh()

begin_decl_ggh(Idle, (void), 0)
end_decl_ggh()

begin_decl_ggh(MenuStatus, (int status, int x, int y), 3)
	GLUT_PUSH_NEW_IV(status);
	GLUT_PUSH_NEW_IV(x);
	GLUT_PUSH_NEW_IV(y);
end_decl_ggh()

begin_decl_ggh(MenuState, (int status), 1)
	GLUT_PUSH_NEW_IV(status);
end_decl_ggh()


static void generic_glut_timer_handler(int value)
{
	AV * handler_data = (AV*)value;
	SV * handler;
	int i;
	dSP;

	handler = *av_fetch(handler_data, 0, 0);

	GLUT_PUSHMARK(sp);
	GLUT_EXTEND_STACK(sp,av_len(handler_data));
	for (i=1;i<=av_len(handler_data);i++)
		GLUT_PUSH_NEW_SV(*av_fetch(handler_data, i, 0));

	PUTBACK;
	DO_perl_call_sv(handler, G_DISCARD);
	
	SvREFCNT_dec(handler_data);
}

static AV * glut_menu_handlers = 0;

static void generic_glut_menu_handler(int value)
{
	AV * handler_data;
	SV * handler;
	SV ** h;
	int i;
	dSP;
	
	h = av_fetch(glut_menu_handlers, glutGetMenu(), FALSE);
	if (!h || !SvOK(*h) || !SvROK(*h))
		croak("Unable to locate menu handler");
	
	handler_data = (AV*)SvRV(*h);

	handler = *av_fetch(handler_data, 0, 0);

	GLUT_PUSHMARK(sp);
	GLUT_EXTEND_STACK(sp,av_len(handler_data) + 1);
	for (i=1;i<=av_len(handler_data);i++)
		GLUT_PUSH_NEW_SV(*av_fetch(handler_data, i, 0));

	GLUT_PUSH_NEW_IV(value);

	PUTBACK;
	DO_perl_call_sv(handler, G_DISCARD);
}


#endif /* def GLUT_API_VERSION */

#define begin_void_specific_marshaller(name, assign_handler_av, params) \
static void _s_marshal_ ## name params					\
{                                                                       \
    SV * handler;                                                       \
	AV * handler_av;                                                \
	dSP;                                                            \
	int i;                                                          \
	assign_handler_av;                                              \
	if (!handler_av) croak("Failure of callback handler");          \
	handler = *av_fetch(handler_av, 0, 0);                          \
    PUSHMARK(sp);                                                       \
    for (i=1; i<=av_len(handler_av); i++)                               \
        XPUSHs(sv_2mortal(newSVsv(*av_fetch(handler_av, i, 0))));

#define end_void_specific_marshaller()                                  \
	PUTBACK;                                                        \
	perl_call_sv(handler, G_DISCARD);                               \
}


struct PGLUtess {
	GLUtriangulatorObj * triangulator;

#ifdef GLU_VERSION_1_2
	AV * polygon_data_av;
	AV * begin_callback;
	AV * edgeFlag_callback;
	AV * vertex_callback;
	AV * end_callback;
	AV * error_callback;
	AV * combine_callback;
#endif
	
	AV * vertex_datas;
};

typedef struct PGLUtess PGLUtess;

#ifdef GLU_VERSION_1_2


#define begin_tess_marshaller(type, params)				\
begin_void_specific_marshaller(glu_t_callback_ ## type,                 \
	PGLUtess * t = (PGLUtess*)polygon_data;                         \
	handler_av = t-> type ## _callback                              \
	, params)                                                       \
    if (t->polygon_data_av)                                             \
      for (i=0; i<=av_len(t->polygon_data_av); i++)                     \
        XPUSHs(sv_2mortal(newSVsv(*av_fetch(t->polygon_data_av, i, 0))));

#define end_tess_marshaller()                                           \
end_void_specific_marshaller()

begin_tess_marshaller(begin, (GLenum type, void * polygon_data))
	XPUSHs(sv_2mortal(newSViv(type)));
end_tess_marshaller()

begin_tess_marshaller(end, (void * polygon_data))
end_tess_marshaller()

begin_tess_marshaller(edgeFlag, (GLboolean flag, void * polygon_data))
	XPUSHs(sv_2mortal(newSViv(flag)));
end_tess_marshaller()

begin_tess_marshaller(vertex, (void * vertex_data, void * polygon_data))
	if (vertex_data) {
      AV * vd = (AV*)vertex_data;
      for (i=0; i<=av_len(vd); i++)
        XPUSHs(sv_2mortal(newSVsv(*av_fetch(vd, i, 0))));
    }
end_tess_marshaller()

begin_tess_marshaller(error, (GLenum errno_, void * polygon_data))
	XPUSHs(sv_2mortal(newSViv(errno_)));
end_tess_marshaller()

begin_tess_marshaller(combine, (GLdouble coords[3], void * vertex_data[4], GLfloat weight[4], void ** outd, void * polygon_data))
	croak("combine tess marshaller needs FIXME (see OpenGL.xs)");
end_tess_marshaller()

#endif

typedef void * ptr;


#define SvItems(type,offset,count,dst)					\
{									\
	GLuint i;							\
	switch (type)							\
	{								\
		case GL_UNSIGNED_BYTE:					\
		case GL_BITMAP:						\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLubyte*)(dst))[i] = SvIV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_BYTE:						\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLbyte*)(dst))[i] = SvIV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_UNSIGNED_SHORT:					\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLushort*)(dst))[i] = SvIV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_SHORT:						\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLshort*)(dst))[i] = SvIV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_UNSIGNED_INT:					\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLuint*)(dst))[i] = SvIV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_INT:						\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLint*)(dst))[i] = SvIV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_FLOAT:						\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLfloat*)(dst))[i] = SvNV(ST(i+(offset)));	\
			}						\
			break;						\
		case GL_DOUBLE:						\
			for (i=0;i<(count);i++)				\
			{						\
			  ((GLdouble*)(dst))[i] = SvNV(ST(i+(offset)));	\
			}						\
			break;						\
		default:						\
			croak("unknown type");				\
	}								\
}


MODULE = OpenGL		PACKAGE = OpenGL::Array

OpenGL::Array
new(Class, count, type, ...)
	GLsizei	count
	GLenum	type
	CODE:
	{
		int oga_len = sizeof(oga_struct);
		oga_struct * oga = malloc(oga_len);
		int i,j;

		memset(oga,0,oga_len);
		
		oga->type_count = items - 2;
		oga->item_count = count;
		
		oga->types = malloc(sizeof(GLenum) * oga->type_count);
		oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
		for(i=0,j=0;i<oga->type_count;i++) {
			oga->types[i] = SvIV(ST(i+2));
			oga->type_offset[i] = j;
			j += gl_type_size(oga->types[i]);
		}
		oga->total_types_width = j;
		
		oga->data_length = oga->total_types_width *
			// ((count + oga->type_count-1) / oga->type_count); # vas is das?
			count;
		
		oga->data = malloc(oga->data_length);
		memset(oga->data,0,oga->data_length);

		oga->free_data = 1;
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

OpenGL::Array
new_list(Class, type, ...)
	GLenum	type
	CODE:
	{
		int oga_len = sizeof(oga_struct);
		oga_struct * oga = malloc(oga_len);

		memset(oga,0,oga_len);

		oga->type_count = 1;
		oga->item_count = items - 2;
		oga->total_types_width = gl_type_size(type);
		oga->data_length = oga->total_types_width * oga->item_count;
		
		oga->types = malloc(sizeof(GLenum) * oga->type_count);
		oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
		oga->data = malloc(oga->data_length);
		oga->free_data = 1;

		oga->type_offset[0] = 0;
		oga->types[0] = type;

		SvItems(type,2,(GLuint)oga->item_count,oga->data);
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

OpenGL::Array
new_scalar(Class, type, data, length)
	GLenum	type
	SV *	data
        GLsizei	length
	CODE:
	{
		int width = gl_type_size(type);
		void * data_s = EL(data, width*length);
		int oga_len = sizeof(oga_struct);
		oga_struct * oga = malloc(oga_len);

		memset(oga,0,oga_len);

		oga->type_count = 1;
		oga->item_count = length / width;
		oga->total_types_width = width;
		oga->data_length = length;
		
		oga->types = malloc(sizeof(GLenum) * oga->type_count);
		oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
		oga->data = malloc(oga->data_length);
		oga->free_data = 1;

		oga->type_offset[0] = 0;
		oga->types[0] = type;

		memcpy(oga->data,data_s,oga->data_length);
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

OpenGL::Array
new_pointer(Class, type, ptr, elements)
	GLenum	type
	void *	ptr
	GLsizei	elements
	CODE:
	{
		int width = gl_type_size(type);
		int oga_len = sizeof(oga_struct);
		oga_struct * oga = malloc(sizeof(oga_struct));

		memset(oga,0,oga_len);
		
		oga->type_count = 1;
		oga->item_count = elements;
		
		oga->types = malloc(sizeof(GLenum) * oga->type_count);
		oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
		oga->types[0] = type;
		oga->type_offset[0] = 0;
		oga->total_types_width = 1;
		
		oga->data_length = elements * width;
		
		oga->data = ptr;
		oga->free_data = 0;
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

OpenGL::Array
new_from_pointer(Class, ptr, length)
	void *	ptr
	GLsizei	length
	CODE:
	{
		int oga_len = sizeof(oga_struct);
		oga_struct * oga = malloc(sizeof(oga_struct));

		memset(oga,0,oga_len);
		
		oga->type_count = 1;
		oga->item_count = length;
		
		oga->types = malloc(sizeof(GLenum) * oga->type_count);
		oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
		oga->types[0] = GL_UNSIGNED_BYTE;
		oga->type_offset[0] = 0;
		oga->total_types_width = 1;
		
		oga->data_length = oga->item_count;
		
		oga->data = ptr;
		oga->free_data = 0;
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

GLboolean
update_pointer(oga, ptr)
	OpenGL::Array oga
	void *	ptr
	CODE:
	{
                RETVAL = (oga->data != ptr);
		oga->data = ptr;
	}
	OUTPUT:
		RETVAL

void
bind(oga, bind)
	OpenGL::Array oga
	GLint	bind
	INIT:
#ifdef GL_ARB_vertex_buffer_object
		loadProc(glBindBufferARB,"glBindBufferARB");
#endif
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		oga->bind = bind;
		glBindBufferARB(GL_ARRAY_BUFFER_ARB,bind);
#else
		croak("OpenGL::Array::bind requires GL_ARB_vertex_buffer_object");
#endif
	}

GLint
bound(oga)
	OpenGL::Array oga
	CODE:
		RETVAL = oga->bind;
	OUTPUT:
		RETVAL

void
assign(oga, pos, ...)
	OpenGL::Array oga
	GLint	pos
	CODE:
	{
		int i,j;
		int end;
		GLenum t;
		char* offset;
		
		i = pos;
		end = i + items - 2;
		
		if (end > oga->item_count)
			end = oga->item_count;
		/* FIXME: is this char* conversion what is intended? */
		offset = ((char*)oga->data) +
			(pos / oga->type_count * oga->total_types_width) + 
			oga->type_offset[pos % oga->type_count];
		
		j = 2;
		
		for (;i<end;i++,j++) {
			t = oga->types[i % oga->type_count];
			switch (t) {
#ifdef GL_VERSION_1_2
			case GL_UNSIGNED_BYTE_3_3_2:
			case GL_UNSIGNED_BYTE_2_3_3_REV:
				(*(GLubyte*)offset) = SvIV(ST(j));
				offset += sizeof(GLubyte);
				break;
			case GL_UNSIGNED_SHORT_5_6_5:
			case GL_UNSIGNED_SHORT_5_6_5_REV:
			case GL_UNSIGNED_SHORT_4_4_4_4:
			case GL_UNSIGNED_SHORT_4_4_4_4_REV:
			case GL_UNSIGNED_SHORT_5_5_5_1:
			case GL_UNSIGNED_SHORT_1_5_5_5_REV:
				(*(GLushort*)offset) = SvIV(ST(j));
				offset += sizeof(GLushort);
				break;
			case GL_UNSIGNED_INT_8_8_8_8:
			case GL_UNSIGNED_INT_8_8_8_8_REV:
			case GL_UNSIGNED_INT_10_10_10_2:
			case GL_UNSIGNED_INT_2_10_10_10_REV:
				(*(GLuint*)offset) = SvIV(ST(j));
				offset += sizeof(GLuint);
				break;
#endif
			case GL_UNSIGNED_BYTE:
			case GL_BITMAP:
				(*(GLubyte*)offset) = SvIV(ST(j));
				offset += sizeof(GLubyte);
				break;
			case GL_BYTE:
				(*(GLbyte*)offset) = SvIV(ST(j));
				offset += sizeof(GLbyte);
				break;
			case GL_UNSIGNED_SHORT:
				(*(GLushort*)offset) = SvIV(ST(j));
				offset += sizeof(GLushort);
				break;
			case GL_SHORT:
				(*(GLshort*)offset) = SvIV(ST(j));
				offset += sizeof(GLshort);
				break;
			case GL_UNSIGNED_INT:
				(*(GLuint*)offset) = SvIV(ST(j));
				offset += sizeof(GLuint);
				break;
			case GL_INT:
				(*(GLint*)offset) = SvIV(ST(j));
				offset += sizeof(GLint);
				break;
			case GL_FLOAT: 
				(*(GLfloat*)offset) = SvNV(ST(j));
				offset += sizeof(GLfloat);
				break;
			case GL_DOUBLE: 
				(*(GLdouble*)offset) = SvNV(ST(j));
				offset += sizeof(GLdouble);
				break;
			case GL_2_BYTES:
			{
				unsigned long v = SvIV(ST(j));
				(*(GLubyte*)offset) = v >> 8;
				offset++;
				(*(GLubyte*)offset) = v & 0xff;
				offset++;
				break;
			}
			case GL_3_BYTES:
			{
				unsigned long v = SvIV(ST(j));
				(*(GLubyte*)offset) = (v >> 16)& 0xff;
				offset++;
				(*(GLubyte*)offset) = (v >> 8) & 0xff;
				offset++;
				(*(GLubyte*)offset) = (v >> 0) & 0xff;
				offset++;
				break;
			}
			case GL_4_BYTES:
			{
				unsigned long v = SvIV(ST(j));
				(*(GLubyte*)offset) = (v >> 24)& 0xff;
				offset++;
				(*(GLubyte*)offset) = (v >> 16)& 0xff;
				offset++;
				(*(GLubyte*)offset) = (v >> 8) & 0xff;
				offset++;
				(*(GLubyte*)offset) = (v >> 0) & 0xff;
				offset++;
				break;
			}
			default:
				croak("unknown type");
			}
		}
	}

void
assign_data(oga, pos, data)
	OpenGL::Array	oga
	GLint	pos
	SV *	data
	CODE:
	{
		void * offset;
		void * src;
		STRLEN len;
		
		offset = ((char*)oga->data) +
			(pos / oga->type_count * oga->total_types_width) + 
			oga->type_offset[pos % oga->type_count];
		
		src = SvPV(data, len);
		
		memcpy(offset, src, len);
	}

void
retrieve(oga, ...)	
	OpenGL::Array	oga
	PPCODE:
	{
		GLint	pos = (items > 1) ? SvIV(ST(1)) : 0;
		GLint	len = (items > 2) ? SvIV(ST(2)) : (oga->item_count - pos);
		char * offset;
		int end = pos + len;
		int i;

		offset = ((char*)oga->data) +
			(pos / oga->type_count * oga->total_types_width) + 
			oga->type_offset[pos % oga->type_count];
		
		if (end > oga->item_count)
			end = oga->item_count;
		
		EXTEND(sp, end-pos);
		
		i = pos;
		
		for (;i<end;i++) {
			GLenum t = oga->types[i % oga->type_count];
			switch (t) {
#ifdef GL_VERSION_1_2
			case GL_UNSIGNED_BYTE_3_3_2:
			case GL_UNSIGNED_BYTE_2_3_3_REV:
				PUSHs(sv_2mortal(newSViv( (*(GLubyte*)offset) )));
				offset += sizeof(GLubyte);
				break;
			case GL_UNSIGNED_SHORT_5_6_5:
			case GL_UNSIGNED_SHORT_5_6_5_REV:
			case GL_UNSIGNED_SHORT_4_4_4_4:
			case GL_UNSIGNED_SHORT_4_4_4_4_REV:
			case GL_UNSIGNED_SHORT_5_5_5_1:
			case GL_UNSIGNED_SHORT_1_5_5_5_REV:
				PUSHs(sv_2mortal(newSViv( (*(GLushort*)offset) )));
				offset += sizeof(GLushort);
				break;
			case GL_UNSIGNED_INT_8_8_8_8:
			case GL_UNSIGNED_INT_8_8_8_8_REV:
			case GL_UNSIGNED_INT_10_10_10_2:
			case GL_UNSIGNED_INT_2_10_10_10_REV:
				PUSHs(sv_2mortal(newSViv( (*(GLuint*)offset) )));
				offset += sizeof(GLuint);
				break;
#endif
			case GL_UNSIGNED_BYTE:
			case GL_BITMAP:
				PUSHs(sv_2mortal(newSViv( (*(GLubyte*)offset) )));
				offset += sizeof(GLubyte);
				break;
			case GL_BYTE:
				PUSHs(sv_2mortal(newSViv( (*(GLbyte*)offset) )));
				offset += sizeof(GLbyte);
				break;
			case GL_UNSIGNED_SHORT:
				PUSHs(sv_2mortal(newSViv( (*(GLushort*)offset) )));
				offset += sizeof(GLushort);
				break;
			case GL_SHORT:
				PUSHs(sv_2mortal(newSViv( (*(GLshort*)offset) )));
				offset += sizeof(GLshort);
				break;
			case GL_UNSIGNED_INT:
				PUSHs(sv_2mortal(newSViv( (*(GLuint*)offset) )));
				offset += sizeof(GLuint);
				break;
			case GL_INT:
				PUSHs(sv_2mortal(newSViv( (*(GLint*)offset) )));
				offset += sizeof(GLint);
				break;
			case GL_FLOAT: 
				PUSHs(sv_2mortal(newSVnv( (*(GLfloat*)offset) )));
				offset += sizeof(GLfloat);
				break;
			case GL_DOUBLE: 
				PUSHs(sv_2mortal(newSVnv( (*(GLdouble*)offset) )));
				offset += sizeof(GLdouble);
				break;
			case GL_2_BYTES:
			case GL_3_BYTES:
			case GL_4_BYTES:
			default:
				croak("unknown type");
			}
		}
	}

SV *
retrieve_data(oga, ...)
	OpenGL::Array	oga
	CODE:
	{
		GLint	pos = (items > 1) ? SvIV(ST(1)) : 0;
		GLint	len = (items > 2) ? SvIV(ST(2)) : (oga->item_count - pos);
		void * offset;
		
		offset = ((char*)oga->data) +
			(pos / oga->type_count * oga->total_types_width) + 
			oga->type_offset[pos % oga->type_count];

		RETVAL = newSVpv((char*)offset, len);
	}
	OUTPUT:
	RETVAL

GLsizei
elements(oga)
	OpenGL::Array	oga
	CODE:
		RETVAL = oga->item_count;
	OUTPUT:
		RETVAL

GLsizei
length(oga)
	OpenGL::Array	oga
	CODE:
		RETVAL = oga->data_length;
	OUTPUT:
		RETVAL

void *
ptr(oga)
	OpenGL::Array	oga
	CODE:
	RETVAL = oga->data;
	OUTPUT:
	RETVAL

void *
offset(oga, pos)
	OpenGL::Array	oga
	GLint	pos
	CODE:
	RETVAL = ((char*)oga->data) +
		(pos / oga->type_count * oga->total_types_width) + 
		oga->type_offset[pos % oga->type_count];
	OUTPUT:
	RETVAL

void
DESTROY(oga)
	OpenGL::Array	oga
	CODE:
	{
		if (oga->free_data) {
			/* To make sure dangling pointers will be obvious */
			memset(oga->data, '\0', oga->data_length);
			free(oga->data);
		}
	
		free(oga->types);
		free(oga->type_offset);
		free(oga);
	}

MODULE = OpenGL		PACKAGE = OpenGL

SV *
constant(name,arg)
	char *	name
	int	arg
	CODE:
	{
		RETVAL = neoconstant(name, arg);
		if (!RETVAL)
			RETVAL = newSVsv(&PL_sv_undef);
	}
	OUTPUT:
	RETVAL

int
_have_gl()
	CODE:
#ifdef HAVE_GL
	RETVAL = 1;
#else
	RETVAL = 0;
#endif
	OUTPUT:
	RETVAL

int
_have_glu()
	CODE:
#ifdef HAVE_GLU
	RETVAL = 1;
#else
	RETVAL = 0;
#endif
	OUTPUT:
	RETVAL

int
_have_glut()
	CODE:
#ifdef HAVE_GLUT
	RETVAL = 1;
#else
	RETVAL = 0;
#endif
	OUTPUT:
	RETVAL

int
_have_glx()
	CODE:
#ifdef HAVE_GLX
	RETVAL = 1;
#else
	RETVAL = 0;
#endif
	OUTPUT:
	RETVAL

int
_have_glp()
	CODE:
#ifdef HAVE_GLpc
	RETVAL = 1;
#else
	RETVAL = 0;
#endif
	OUTPUT:
	RETVAL



#ifdef HAVE_GL

# 1.0
void
glAccum(op, value)
	GLenum	op
	GLfloat	value

# 1.0
void
glAlphaFunc(func, ref)
	GLenum	func
	GLclampf	ref

#ifdef GL_VERSION_1_1

void
glAreTexturesResident_c(n, textures, residences)
	GLsizei	n
	void *	textures
	void *	residences
	CODE:
	glAreTexturesResident(n, textures, residences);

void
glAreTexturesResident_s(n, textures, residences)
	GLsizei	n
	SV *	textures
	SV *	residences
	CODE:
	{
	void * textures_s = EL(textures, sizeof(GLuint)*n);
	void * residences_s = EL(residences, sizeof(GLboolean)*n);
	glAreTexturesResident(n, textures_s, residences_s);
	}

# 1.1
void
glAreTexturesResident_p(...)
	PPCODE:
	{
		GLsizei n = items;
		GLuint * textures = malloc(sizeof(GLuint) * (n+1));
		GLboolean * residences = malloc(sizeof(GLboolean) * (n+1));
		GLboolean result;
		int i;
		
		for (i=0;i<n;i++)
			textures[i] = SvIV(ST(i));
		
		result = glAreTexturesResident(n, textures, residences);
		
		if ((result == GL_TRUE) || (GIMME != G_ARRAY))
			PUSHs(sv_2mortal(newSViv(result)));
		else {
			EXTEND(sp, n+1);
			PUSHs(sv_2mortal(newSViv(result)));
			for(i=0;i<n;i++)
				PUSHs(sv_2mortal(newSViv(residences[i])));
		}
		
		free(textures);
		free(residences);
	}

# 1.1
void
glArrayElement(i)
	GLint	i

#endif

# 1.0
void
glBegin(mode)
	GLenum	mode

# 1.0
void
glEnd()

#ifdef GL_VERSION_1_1

void
glBindTexture(target, texture)
	GLenum	target
	GLuint	texture

#endif


# 1.0
void
glBitmap_c(width, height, xorig, yorig, xmove, ymove, bitmap)
	GLsizei	width
	GLsizei	height
	GLfloat	xorig
	GLfloat	yorig
	GLfloat	xmove
	GLfloat	ymove
	void *	bitmap
	CODE:
	glBitmap(width, height, xorig, yorig, xmove, ymove, bitmap);

void
glBitmap_s(width, height, xorig, yorig, xmove, ymove, bitmap)
	GLsizei	width
	GLsizei	height
	GLfloat	xorig
	GLfloat	yorig
	GLfloat	xmove
	GLfloat	ymove
	SV *	bitmap
	CODE:
	{
	GLubyte * bitmap_s = ELI(bitmap, width, height,
		GL_COLOR_INDEX, GL_BITMAP, gl_pixelbuffer_unpack);
	glBitmap(width, height, xorig, yorig, xmove, ymove, bitmap_s);
	}

void
glBitmap_p(width, height, xorig, yorig, xmove, ymove, ...)
	GLsizei	width
	GLsizei	height
	GLfloat	xorig
	GLfloat	yorig
	GLfloat	xmove
	GLfloat	ymove
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(6)), items-6, width, height,
		1, GL_COLOR_INDEX, GL_BITMAP, 0);
	glBitmap(width, height, xorig, yorig, xmove, ymove, ptr);
	glPopClientAttrib();
	free(ptr);
	}

# 1.0
void
glBlendFunc(sfactor, dfactor)
	GLenum	sfactor
	GLenum	dfactor

# 1.0
void
glCallList(list)
	GLuint	list

# 1.0
void
glCallLists_c(n, type, lists)
	GLsizei	n
	GLenum	type
	void *	lists
	CODE:
	glCallLists(n, type, lists);

# 1.0
void
glCallLists_s(n, type, lists)
	GLsizei	n
	GLenum	type
	SV *	lists
	CODE:
	{
	void * lists_s = EL(lists, gl_type_size(type) * n);
	glCallLists(n, type, lists_s);
	}

# 1.0
void
glCallLists_p(...)
	CODE:
	if (items) {
		int * list = malloc(sizeof(int) * items);
		int i;
		for(i=0;i<items;i++)
			list[i] = SvIV(ST(i));
		glCallLists(items, GL_INT, list);
		free(list);
	}

# 1.0
void
glClear(mask)
	GLbitfield	mask

# 1.0
void
glClearAccum(red, green, blue, alpha)
	GLfloat	red
	GLfloat	green
	GLfloat	blue
	GLfloat	alpha

# 1.0
void
glClearColor(red, green, blue, alpha)
	GLclampf	red
	GLclampf	green
	GLclampf	blue
	GLclampf	alpha

# 1.0
void
glClearDepth(depth)
	GLclampd	depth

# 1.0
void
glClearIndex(c)
	GLfloat	c

# 1.0
void
glClearStencil(s)
	GLint	s

# 1.0
void
glClipPlane_c(plane, eqn)
	GLenum	plane
	void *	eqn
	CODE:
	glClipPlane(plane, eqn);

# 1.0
void
glClipPlane_s(plane, eqn)
	GLenum	plane
	SV *	eqn
	CODE:
	{
		GLdouble * eqn_s = EL(eqn, sizeof(GLdouble) * 4);
		glClipPlane(plane, eqn_s);
	}

# 1.0
void
glClipPlane_p(plane, eqn0, eqn1, eqn2, eqn3)
	GLenum	plane
	double	eqn0
	double	eqn1
	double	eqn2
	double	eqn3
	CODE:
	{
		double eqn[4];
		eqn[0] = eqn0;
		eqn[1] = eqn1;
		eqn[2] = eqn2;
		eqn[3] = eqn3;
		glClipPlane(plane, &eqn[0]);
	}

# 1.0
void
glColorMask(red, green, blue, alpha)
	GLboolean	red
	GLboolean	green
	GLboolean	blue
	GLboolean	alpha

# 1.0
void
glColorMaterial(face, mode)
	GLenum	face
	GLenum	mode

#ifdef GL_VERSION_1_1

# 1.1
void
glColorPointer_c(size, type, stride, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	void *	pointer
	CODE:
	glColorPointer(size, type, stride, pointer);


void
glColorPointer_s(size, type, stride, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	SV *	pointer
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*size);
		void * pointer_s = EL(pointer, width);
		glColorPointer(size, type, stride, pointer_s);
	}

void
glColorPointer_p(size, oga)
	GLint	size
	OpenGL::Array oga
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glColorPointer(size, oga->types[0], 0, oga->bind ? 0 : oga->data);
#else
		glColorPointer(size, oga->types[0], 0, oga->data);
#endif
	}

#endif

# 1.0
void
glCopyPixels(x, y, width, height, type)
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	GLenum	type

#ifdef GL_VERSION_1_1

# 1.1
void
glCopyTexImage1D(target, level, internalFormat, x, y, width, border)
	GLenum	target
	GLint	level
	GLenum	internalFormat
	GLint	x
	GLint	y
	GLsizei	width
	GLint	border

# 1.1
void
glCopyTexImage2D(target, level, internalFormat, x, y, width, height, border)
	GLenum	target
	GLint	level
	GLenum	internalFormat
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	GLint	border

# 1.1
void
glCopyTexSubImage1D(target, level, xoffset, x, y, width)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	x
	GLint	y
	GLsizei	width

# 1.1
void
glCopyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height

#ifdef GL_VERSION_1_2

# 1.2
void
glCopyTexSubImage3D(target, level, xoffset, yoffset, zoffset, x, y, width, height)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	INIT:
		loadProc(glCopyTexSubImage3D,"glCopyTexSubImage3D");
	CODE:
	{
		glCopyTexSubImage3D(target, level, xoffset, yoffset, zoffset,
			x, y, width, height);
	}

#endif

#endif

# 1.0
void
glCullFace(mode)
	GLenum	mode

# 1.0
void
glDeleteLists(list, range)
	GLenum	list
	GLsizei	range

#ifdef GL_VERSION_1_1

# 1.1
void
glDeleteTextures_c(items, list)
	GLint	items
	void *	list
	CODE:
	glDeleteTextures(items,list);

# 1.1
void
glDeleteTextures_s(items, list)
	GLint	items
	SV *	list
	CODE:
	{
	void * list_s = EL(list, sizeof(GLuint) * items);
	glDeleteTextures(items,list_s);
	}

# 1.1
void
glDeleteTextures_p(...)
	CODE:
	if (items) {
		GLuint * list = malloc(sizeof(GLuint) * items);
		int i;

		for(i=0;i<items;i++)
			list[i] = SvIV(ST(i));
		
		glDeleteTextures(items, list);
		free(list);
	}

#endif

# 1.0
void
glDepthFunc(func)
	GLenum	func

# 1.0
void
glDepthMask(flag)
	GLboolean	flag

# 1.0
void
glDepthRange(zNear, zFar)
	GLclampd	zNear
	GLclampd	zFar

#ifdef GL_VERSION_1_1

# 1.1
void
glDrawArrays(mode, first, count)
	GLenum	mode
	GLint	first
	GLsizei	count

#endif

# 1.0
void
glDrawBuffer(mode)
	GLenum	mode

#ifdef GL_VERSION_1_1

# 1.1
void
glDrawElements_c(mode, count, type, indices)
	GLenum	mode
	GLint	count
	GLenum	type
	void *	indices
	CODE:
		glDrawElements(mode, count, type, indices);

# 1.1
void
glDrawElements_s(mode, count, type, indices)
	GLenum	mode
	GLint	count
	GLenum	type
	SV *	indices
	CODE:
	{
		void * indices_s = EL(indices, gl_type_size(type)*count);
		glDrawElements(mode, count, type, indices_s);
	}

void
glDrawElements_p(mode, ...)
	GLenum	mode
	CODE:
	{
		GLuint * indices = malloc(sizeof(GLuint) * items);
		int i;
		
		for (i=1; i<items; i++)
			indices[i-1] = SvIV(ST(i));
		
		glDrawElements(mode, items-1, GL_UNSIGNED_INT, indices);
		
		free(indices);
	}

#endif

# 1.0
void
glDrawPixels_c(width, height, format, type, pixels)
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glDrawPixels(width, height, format, type, pixels);

# 1.0
void
glDrawPixels_s(width, height, format, type, pixels)
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
	GLvoid * ptr = ELI(pixels, width, height,
		format, type, gl_pixelbuffer_unpack);
	glDrawPixels(width, height, format, type, ptr);
	}

# 1.0
void
glDrawPixels_p(width, height, format, type, ...)
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(4)), items-4, width, height, 1, format, type, 0);
	glDrawPixels(width, height, format, type, ptr);
	glPopClientAttrib();
	free(ptr);
	}

#ifdef GL_VERSION_1_2

# 1.2
void
glDrawRangeElements_c(mode, start, end, count, type, indices)
	GLenum	mode
	GLuint	start
	GLuint	end
	GLsizei	count
	GLenum	type
	void *	indices
	INIT:
		loadProc(glDrawRangeElements,"glDrawRangeElements");
	CODE:
		glDrawRangeElements(mode, start, end, count, type, indices);

void
glDrawRangeElements_s(mode, start, end, count, type, indices)
	GLenum	mode
	GLuint	start
	GLuint	end
	GLsizei	count
	GLenum	type
	SV *	indices
	INIT:
		loadProc(glDrawRangeElements,"glDrawRangeElements");
	CODE:
	{
		void * indices_s = EL(indices, gl_type_size(type) * count);
		glDrawRangeElements(mode, start, end, count, type, indices_s);
	}

void
glDrawRangeElements_p(mode, start, count, ...)
	GLenum	mode
	GLuint	start
	GLuint	count
	INIT:
		loadProc(glDrawRangeElements,"glDrawRangeElements");
	CODE:
	{
		if (items > 3)
		{
			if (start < (GLuint)items-3)
			{
				GLuint * indices;
				GLuint i;

				if (start+count > (GLuint)(items-3))
					count = (GLuint)items-(start+3);

				indices = malloc(sizeof(GLuint) * count);
		
				for (i=start; i<count; i++)
					indices[i] = SvIV(ST(i+3));
		
				glDrawRangeElements(mode, start, start+count-1,
					count, GL_UNSIGNED_INT, indices);
		
				free(indices);
			}
		}
		else
		{
			glDrawRangeElements(mode, start, start+count-1,
				count, GL_UNSIGNED_INT, 0);
		}
	}

#endif

# 1.0
void
glEdgeFlag(flag)
	GLboolean	flag

#ifdef GL_VERSION_1_1

# 1.1
void
glEdgeFlagPointer_c(stride, pointer)
	GLint	stride
	void *	pointer
	CODE:
	glEdgeFlagPointer(stride, pointer);

void
glEdgeFlagPointer_s(stride, pointer)
	GLsizei	stride
	SV *	pointer
	CODE:
	{
		int width = stride ? stride : sizeof(GLboolean);
		void * pointer_s = EL(pointer, width);
		glEdgeFlagPointer(stride, pointer_s);
	}

void
glEdgeFlagPointer_p(oga)
	OpenGL::Array oga
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glEdgeFlagPointer(0, oga->bind ? 0 : oga->data);
#else
		glEdgeFlagPointer(0, oga->data);
#endif
	}

#endif

# 1.0
void
glEnable(cap)
	GLenum	cap

# 1.0
void
glDisable(cap)
	GLenum	cap

#ifdef GL_VERSION_1_1

# 1.1
void
glEnableClientState(cap)
	GLenum	cap

# 1.1
void
glDisableClientState(cap)
	GLenum	cap

#endif

# 1.0
void
glEvalCoord1d(u)
	GLdouble	u

# 1.0
void
glEvalCoord1f(u)
	GLfloat	u

# 1.0
void
glEvalCoord2d(u, v)
	GLdouble	u
	GLdouble	v

# 1.0
void
glEvalCoord2f(u, v)
	GLfloat	u
	GLfloat	v

# 1.0
void
glEvalMesh1(mode, i1, i2)
	GLenum	mode
	GLint	i1
	GLint	i2
	
# 1.0
void
glEvalMesh2(mode, i1, i2, j1, j2)
	GLenum	mode
	GLint	i1
	GLint	i2
	GLint	j1
	GLint	j2

# 1.0
void
glEvalPoint1(i)
	GLint	i
	
# 1.0
void
glEvalPoint2(i, j)
	GLint	i
	GLint	j

# 1.0
void
glFeedbackBuffer_c(size, type, buffer)
	GLsizei	size
	GLenum	type
	void *	buffer
	CODE:
	glFeedbackBuffer(size, type, (GLfloat*)(buffer));

# 1.0
void
glFinish()

# 1.0
void
glFlush()

# 1.0
void
glFogf(pname, param)
	GLenum	pname
	GLfloat	param

# 1.0
void
glFogi(pname, param)
	GLenum	pname
	GLint	param

# 1.0
void
glFogfv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glFogfv(pname, params);

# 1.0
void
glFogiv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glFogiv(pname, params);

# 1.0
void
glFogfv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params, sizeof(GLfloat)*gl_fog_count(pname));
	glFogfv(pname, params_s);
	}

# 1.0
void
glFogiv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint)*gl_fog_count(pname));
	glFogiv(pname, params_s);
	}

# 1.0
void
glFogfv_p(pname, param1, param2=0, param3=0, param4=0)
	GLenum	pname
	GLfloat	param1
	GLfloat	param2
	GLfloat	param3
	GLfloat	param4
	CODE:
	{
		GLfloat p[4];
		p[0] = param1;
		p[1] = param2;
		p[2] = param3;
		p[3] = param4;
		glFogfv(pname, &p[0]);
	}

# 1.0
void
glFogiv_p(pname, param1, param2=0, param3=0, param4=0)
	GLenum	pname
	GLint	param1
	GLint	param2
	GLint	param3
	GLint	param4
	CODE:
	{
		GLint p[4];
		p[0] = param1;
		p[1] = param2;
		p[2] = param3;
		p[3] = param4;
		glFogiv(pname, &p[0]);
	}

# 1.0
void
glFrontFace(mode)
	GLenum	mode

# 1.0
void
glFrustum(left, right, bottom, top, zNear, zFar)
	GLdouble	left
	GLdouble	right
	GLdouble	bottom
	GLdouble	top
	GLdouble	zNear
	GLdouble	zFar

# 1.0
GLuint
glGenLists(range)
	GLsizei	range

#ifdef GL_VERSION_1_1

# 1.1
void
glGenTextures_c(n, textures)
	GLint	n
	void *	textures
	CODE:
	glGenTextures(n, textures);

# 1.1
void
glGenTextures_s(n, textures)
	GLint	n
	SV *	textures
	CODE:
	{
	void * textures_s = EL(textures, sizeof(GLuint)*n);
	glGenTextures(n, textures_s);
	}

# 1.1
void
glGenTextures_p(n)
	GLint	n
	PPCODE:
	if (n) {
		GLuint * textures = malloc(sizeof(GLuint) * n);
		int i;
		
		glGenTextures(n, textures);
		
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(textures[i])));

		free(textures);
	} 

#endif

# 1.0
void
glGetDoublev_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glGetDoublev(pname, params);

# 1.0
void
glGetDoublev_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	void * params_s = EL(params, sizeof(GLdouble) * gl_get_count(pname));
	glGetDoublev(pname, params_s);
	}

# 1.0
void
glGetBooleanv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glGetBooleanv(pname, params);

# 1.0
void
glGetBooleanv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	void * params_s = EL(params, sizeof(GLboolean) * gl_get_count(pname));
	glGetBooleanv(pname, params_s);
	}

# 1.0
void
glGetIntegerv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glGetIntegerv(pname, params);

# 1.0
void
glGetIntegerv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	void * params_s = EL(params, sizeof(GLint) * gl_get_count(pname));
	glGetIntegerv(pname, params_s);
	}

# 1.0
void
glGetFloatv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glGetFloatv(pname, params);

# 1.0
void
glGetFloatv_s(pname, params)
	GLenum	pname
	void *	params
	CODE:
	{
	void * params_s = EL(params, sizeof(GLfloat) * gl_get_count(pname));
	glGetFloatv(pname, params_s);
	}

# 1.0
void
glGetDoublev_p(param)
	GLenum	param
	PPCODE:
	{
		GLdouble	ret[MAX_GL_GET_COUNT];
		int n = gl_get_count(param);
		int i;
		glGetDoublev(param, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetBooleanv_p(param)
	GLenum	param
	PPCODE:
	{
		GLboolean	ret[MAX_GL_GET_COUNT];
		int n = gl_get_count(param);
		int i;
		glGetBooleanv(param, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetIntegerv_p(param)
	GLenum	param
	PPCODE:
	{
		GLint	ret[MAX_GL_GET_COUNT];
		int n = gl_get_count(param);
		int i;
		glGetIntegerv(param, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetFloatv_p(param)
	GLenum	param
	PPCODE:
	{
		GLfloat	ret[MAX_GL_GET_COUNT];
		int n = gl_get_count(param);
		int i;
		glGetFloatv(param, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetClipPlane_c(plane, eqn)
	GLenum	plane
	void *	eqn
	CODE:
	glGetClipPlane(plane, eqn);

# 1.0
void
glGetClipPlane_s(plane, eqn)
	GLenum	plane
	SV *	eqn
	CODE:
	{
	GLdouble * eqn_s = EL(eqn, sizeof(GLdouble)*4);
	glGetClipPlane(plane, eqn_s);
	}

# 1.0
void
glGetClipPlane_p(plane)
	GLenum	plane
	PPCODE:
	{
		int i;
		GLdouble	eqn[4];
		eqn[0] = eqn[1] = eqn[2] = eqn[3] = 0;
		glGetClipPlane(plane, &eqn[0]);
		EXTEND(sp, 4);
		for(i=0;i<4;i++)
			PUSHs(sv_2mortal(newSVnv(eqn[i])));
	}

# 1.0
GLenum
glGetError()

# 1.0
void
glGetLightfv_c(light, pname, p)
	GLenum	light
	GLenum	pname
	void *	p
	CODE:
	glGetLightfv(light, pname, p);

# 1.0
void
glGetLightiv_c(light, pname, p)
	GLenum	light
	GLenum	pname
	void *	p
	CODE:
	glGetLightiv(light, pname, p);

# 1.0
void
glGetLightfv_s(light, pname, p)
	GLenum	light
	GLenum	pname
	SV *	p
	CODE:
	{
	void * p_s = EL(p, sizeof(GLfloat)*gl_light_count(pname));
	glGetLightfv(light, pname, p_s);
	}

# 1.0
void
glGetLightiv_s(light, pname, p)
	GLenum	light
	GLenum	pname
	SV *	p
	CODE:
	{
	void * p_s = EL(p, sizeof(GLint)*gl_light_count(pname));
	glGetLightiv(light, pname, p_s);
	}

# 1.0
void
glGetLightfv_p(light, pname)
	GLenum	light
	GLenum	pname
	PPCODE:
	{
		GLfloat	ret[MAX_GL_LIGHT_COUNT];
		int n = gl_light_count(pname);
		int i;
		glGetLightfv(light, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetLightiv_p(light, pname)
	GLenum	light
	GLenum	pname
	PPCODE:
	{
		GLint	ret[MAX_GL_LIGHT_COUNT];
		int n = gl_light_count(pname);
		int i;
		glGetLightiv(light, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetMapiv_c(target, query, v)
	GLenum	target
	GLenum	query
	void *	v
	CODE:
	glGetMapiv(target, query, (GLint*)v);

# 1.0
void
glGetMapfv_c(target, query, v)
	GLenum	target
	GLenum	query
	void *	v
	CODE:
	glGetMapfv(target, query, (GLfloat*)v);

# 1.0
void
glGetMapdv_c(target, query, v)
	GLenum	target
	GLenum	query
	void *	v
	CODE:
	glGetMapdv(target, query, (GLdouble*)v);

# 1.0
void
glGetMapdv_s(target, query, v)
	GLenum	target
	GLenum	query
	SV * v
	CODE:
	{
		GLdouble * v_s = EL(v,
			sizeof(GLdouble)*gl_map_count(target, query));
		glGetMapdv(target, query, v_s);
	}

# 1.0
void
glGetMapfv_s(target, query, v)
	GLenum	target
	GLenum	query
	SV * v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*gl_map_count(target, query));
		glGetMapfv(target, query, v_s);
	}

# 1.0
void
glGetMapiv_s(target, query, v)
	GLenum	target
	GLenum	query
	SV * v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*gl_map_count(target, query));
		glGetMapiv(target, query, v_s);
	}

# 1.0
void
glGetMapfv_p(target, query)
	GLenum	target
	GLenum	query
	PPCODE:
	{
		GLfloat	ret[MAX_GL_MAP_COUNT];
		int n = gl_map_count(target, query);
		int i;
		glGetMapfv(target, query, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetMapdv_p(target, query)
	GLenum	target
	GLenum	query
	PPCODE:
	{
		GLdouble	ret[MAX_GL_MAP_COUNT];
		int n = gl_map_count(target, query);
		int i;
		glGetMapdv(target, query, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetMapiv_p(target, query)
	GLenum	target
	GLenum	query
	PPCODE:
	{
		GLint	ret[MAX_GL_MAP_COUNT];
		int n = gl_map_count(target, query);
		int i;
		glGetMapiv(target, query, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetMaterialfv_c(face, query, params)
	GLenum	face
	GLenum	query
	void *	params
	CODE:
	glGetMaterialfv(face, query, params);

# 1.0
void
glGetMaterialiv_c(face, query, params)
	GLenum	face
	GLenum	query
	void *	params
	CODE:
	glGetMaterialiv(face, query, params);

# 1.0
void
glGetMaterialfv_s(face, query, params)
	GLenum	face
	GLenum	query
	SV *	params
	CODE:
	{
		GLfloat * params_s = EL(params,
			sizeof(GLfloat)*gl_material_count(query));
		glGetMaterialfv(face, query, params_s);
	}

# 1.0
void
glGetMaterialiv_s(face, query, params)
	GLenum	face
	GLenum	query
	SV *	params
	CODE:
	{
		GLint * params_s = EL(params,
			sizeof(GLfloat)*gl_material_count(query));
		glGetMaterialiv(face, query, params_s);
	}

# 1.0
void
glGetMaterialfv_p(face, query)
	GLenum	face
	GLenum	query
	PPCODE:
	{
		GLfloat	ret[MAX_GL_MATERIAL_COUNT];
		int n = gl_material_count(query);
		int i;
		glGetMaterialfv(face, query, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetMaterialiv_p(face, query)
	GLenum	face
	GLenum	query
	PPCODE:
	{
		GLint	ret[MAX_GL_MATERIAL_COUNT];
		int n = gl_material_count(query);
		int i;
		glGetMaterialiv(face, query, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetPixelMapfv_c(map, values)
	GLenum	map
	void *	values
	CODE:
	glGetPixelMapfv(map, values);

# 1.0
void
glGetPixelMapuiv_c(map, values)
	GLenum	map
	void *	values
	CODE:
	glGetPixelMapuiv(map, values);

# 1.0
void
glGetPixelMapusv_c(map, values)
	GLenum	map
	void *	values
	CODE:
	glGetPixelMapusv(map, values);

# 1.0
void
glGetPixelMapfv_s(map, values)
	GLenum	map
	SV *	values
	CODE:
	{
	GLfloat * values_s = EL(values, sizeof(GLfloat)* gl_pixelmap_size(map));
	glGetPixelMapfv(map, values_s);
	}

# 1.0
void
glGetPixelMapuiv_s(map, values)
	GLenum	map
	SV *	values
	CODE:
	{
	GLuint * values_s = EL(values, sizeof(GLuint)* gl_pixelmap_size(map));
	glGetPixelMapuiv(map, values_s);
	}

# 1.0
void
glGetPixelMapusv_s(map, values)
	GLenum	map
	SV *	values
	CODE:
	{
	GLushort * values_s = EL(values, sizeof(GLushort)* gl_pixelmap_size(map));
	glGetPixelMapusv(map, values_s);
	}

# 1.0
void
glGetPixelMapfv_p(map)
	GLenum	map
	CODE:
	{
		int count = gl_pixelmap_size(map);
		GLfloat * values;
		int i;

		values = malloc(sizeof(GLfloat) * count);

		glGetPixelMapfv(map, values);
		
		EXTEND(sp, count);
		
		for(i=0; i<count; i++)
			PUSHs(sv_2mortal(newSVnv(values[i])));

		free(values);
	}

# 1.0
void
glGetPixelMapuiv_p(map)
	GLenum	map
	CODE:
	{
		int count = gl_pixelmap_size(map);
		GLuint * values;
		int i;
		values = malloc(sizeof(GLuint) * count);
		glGetPixelMapuiv(map, values);
		EXTEND(sp, count);
		for(i=0; i<count; i++)
			PUSHs(sv_2mortal(newSViv(values[i])));
		free(values);
	}
	
# 1.0
void
glGetPixelMapusv_p(map)
	GLenum	map
	CODE:
	{
		int count = gl_pixelmap_size(map);
		GLushort * values;
		int i;
		values = malloc(sizeof(GLushort) * count);
		glGetPixelMapusv(map, values);
		EXTEND(sp, count);
		for(i=0; i<count; i++)
			PUSHs(sv_2mortal(newSViv(values[i])));
		free(values);
	}

# 1.0
void
glGetPolygonStipple_c(mask)
	void *	mask
	CODE:
	glGetPolygonStipple(mask);

# 1.0
void
glGetPolygonStipple_s(mask)
	SV *	mask
	CODE:
	{
	GLubyte * ptr = ELI(mask, 32, 32, GL_COLOR_INDEX, GL_BITMAP, gl_pixelbuffer_unpack);
	glGetPolygonStipple(ptr);
	}

# 1.0
void
glGetPolygonStipple_p()
	PPCODE:
	{
		void * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_PACK_ROW_LENGTH, 0);
		glPixelStorei(GL_PACK_ALIGNMENT, 1);
		ptr = allocate_image_ST(32, 32, 1, GL_COLOR_INDEX, GL_BITMAP, 0);
		glGetPolygonStipple(ptr);
		sp = unpack_image_ST(sp, ptr, 32, 32, 1,
			GL_COLOR_INDEX, GL_BITMAP, 0);
		free(ptr);
		glPopClientAttrib();
	}

#ifdef GL_VERSION_1_1

# 1.1
void
glGetPointerv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glGetPointerv(pname,&params);

# 1.1
void
glGetPointerv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
		void ** params_s = EL(params, sizeof(void*));
		glGetPointerv(pname, params_s);
	}

# 1.1
void *
glGetPointerv_p(pname)
	GLenum	pname
	CODE:
	glGetPointerv(pname, &RETVAL);
	OUTPUT:
	RETVAL

#endif

# 1.0
SV *
glGetString(name)
	GLenum	name
	CODE:
	{
		char * c = (char*)glGetString(name);
		if (c)
			RETVAL = newSVpv(c, 0);
		else
			RETVAL = newSVsv(&PL_sv_undef);
	}
	OUTPUT:
	RETVAL

# 1.0
void
glGetTexEnvfv_c(target, pname, params)
	GLenum	target
	GLenum	pname
	void * params
	CODE:
	glGetTexEnvfv(target, pname, params);

# 1.0
void
glGetTexEnviv_c(target, pname, params)
	GLenum	target
	GLenum	pname
	void * params
	CODE:
	glGetTexEnviv(target, pname, params);

# 1.0
void
glGetTexEnvfv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV * params
	CODE:
	{
	GLfloat * params_s = EL(params, sizeof(GLfloat) * gl_texenv_count(pname));
	glGetTexEnvfv(target, pname, params_s);
	}

# 1.0
void
glGetTexEnviv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV * params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint) * gl_texenv_count(pname));
	glGetTexEnviv(target, pname, params_s);
	}

# 1.0
void
glGetTexEnvfv_p(target, pname)
	GLenum	target
	GLenum	pname
	PPCODE:
	{
		GLfloat	ret[MAX_GL_TEXENV_COUNT];
		int n = gl_texenv_count(pname);
		int i;
		glGetTexEnvfv(target, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetTexEnviv_p(target, pname)
	GLenum	target
	GLenum	pname
	PPCODE:
	{
		GLint	ret[MAX_GL_TEXENV_COUNT];
		int n = gl_texenv_count(pname);
		int i;
		glGetTexEnviv(target, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetTexGenfv_c(coord, pname, params)
	GLenum	coord
	GLenum	pname
	void *	params
	CODE:
	glGetTexGenfv(coord, pname, params);

# 1.0
void
glGetTexGendv_c(coord, pname, params)
	GLenum	coord
	GLenum	pname
	void *	params
	CODE:
	glGetTexGendv(coord, pname, params);

# 1.0
void
glGetTexGeniv_c(coord, pname, params)
	GLenum	coord
	GLenum	pname
	void *	params
	CODE:
	glGetTexGeniv(coord, pname, params);

# 1.0
void
glGetTexGendv_s(coord, pname, params)
	GLenum	coord
	GLenum	pname
	SV *	params
	CODE:
	{
	GLdouble * params_s = EL(params, sizeof(GLdouble)*gl_texgen_count(pname));
	glGetTexGendv(coord, pname, params_s);
	}

# 1.0
void
glGetTexGenfv_s(coord, pname, params)
	GLenum	coord
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params, sizeof(GLfloat)*gl_texgen_count(pname));
	glGetTexGenfv(coord, pname, params_s);
	}

# 1.0
void
glGetTexGeniv_s(coord, pname, params)
	GLenum	coord
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint)*gl_texgen_count(pname));
	glGetTexGeniv(coord, pname, params_s);
	}

# 1.0
void
glGetTexGenfv_p(coord, pname)
	GLenum	coord
	GLenum	pname
	PPCODE:
	{
		GLfloat	ret[MAX_GL_TEXGEN_COUNT];
		int n = gl_texgen_count(pname);
		int i;
		glGetTexGenfv(coord, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetTexGendv_p(coord, pname)
	GLenum	coord
	GLenum	pname
	PPCODE:
	{
		GLdouble	ret[MAX_GL_TEXGEN_COUNT];
		int n = gl_texgen_count(pname);
		int i;
		glGetTexGendv(coord, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetTexGeniv_p(coord, pname)
	GLenum	coord
	GLenum	pname
	PPCODE:
	{
		GLint	ret[MAX_GL_TEXGEN_COUNT];
		int n = gl_texgen_count(pname);
		int i;
		glGetTexGeniv(coord, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glGetTexImage_c(target, level, format, type, pixels)
	GLenum	target
	GLint	level
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glGetTexImage(target, level, format, type, pixels);

# 1.0
void
glGetTexImage_s(target, level, format, type, pixels)
	GLenum	target
	GLint	level
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
		GLint width, height;
		GLvoid * ptr;
		
		glGetTexLevelParameteriv(target, level,
			GL_TEXTURE_WIDTH, &width);
		glGetTexLevelParameteriv(target, level,
			GL_TEXTURE_HEIGHT, &height);
		
		ptr = ELI(pixels, width, height, format, type,
			gl_pixelbuffer_unpack);
		glGetTexImage(target, level, format, type, pixels);
	}

# 1.0
void
glGetTexImage_p(target, level, format, type)
	GLenum	target
	GLint	level
	GLenum	format
	GLenum	type
	PPCODE:
	{
		GLint width, height;
		GLvoid * ptr;
		
		glGetTexLevelParameteriv(target, level,
			GL_TEXTURE_WIDTH, &width);
		glGetTexLevelParameteriv(target, level,
			GL_TEXTURE_HEIGHT, &height);
		
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_PACK_ROW_LENGTH, 0);
		glPixelStorei(GL_PACK_ALIGNMENT, 1);

		ptr = allocate_image_ST(width, height, 1, format, type, 0);
		glGetTexImage(target, level, format, type, ptr);
		sp = unpack_image_ST(sp, ptr, width, height, 1, format, type, 0);

		free(ptr);
		glPopClientAttrib();
	}

# 1.0
void
glGetTexLevelParameterfv_c(target, level, pname, params)
	GLenum	target
	GLint	level
	GLenum	pname
	void *	params
	CODE:
	glGetTexLevelParameterfv(target, level, pname, params);

# 1.0
void
glGetTexLevelParameteriv_c(target, level, pname, params)
	GLenum	target
	GLint	level
	GLenum	pname
	void *	params
	CODE:
	glGetTexLevelParameteriv(target, level, pname, params);

# 1.0
void
glGetTexLevelParameterfv_s(target, level, pname, params)
	GLenum	target
	GLint	level
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params, sizeof(GLfloat)*1);
	glGetTexLevelParameterfv(target, level, pname, params_s);
	}

# 1.0
void
glGetTexLevelParameteriv_s(target, level, pname, params)
	GLenum	target
	GLint	level
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint)*1);
	glGetTexLevelParameteriv(target, level, pname, params_s);
	}

# 1.0
void
glGetTexLevelParameterfv_p(target, level, pname)
	GLenum	target
	GLint	level
	GLenum	pname
	PPCODE:
	{
		GLfloat	ret;
		glGetTexLevelParameterfv(target, level, pname, &ret);
		PUSHs(sv_2mortal(newSVnv(ret)));
	}

# 1.0
void
glGetTexLevelParameteriv_p(target, level, pname)
	GLenum	target
	GLint	level
	GLenum	pname
	PPCODE:
	{
		GLint	ret;
		glGetTexLevelParameteriv(target, level, pname, &ret);
		PUSHs(sv_2mortal(newSViv(ret)));
	}

# 1.0
void
glGetTexParameterfv_c(target, pname, params)
	GLenum	target
	GLenum	pname
	void *	params
	CODE:
	glGetTexParameterfv(target, pname, params);

# 1.0
void
glGetTexParameteriv_c(target, pname, params)
	GLenum	target
	GLenum	pname
	void *	params
	CODE:
	glGetTexParameteriv(target, pname, params);

# 1.0
void
glGetTexParameterfv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params,
		sizeof(GLfloat)*gl_texparameter_count(pname));
	glGetTexParameterfv(target, pname, params_s);
	}

# 1.0
void
glGetTexParameteriv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params,
		sizeof(GLint)*gl_texparameter_count(pname));
	glGetTexParameteriv(target, pname, params_s);
	}

# 1.0
void
glGetTexParameterfv_p(target, pname)
	GLenum	target
	GLenum	pname
	PPCODE:
	{
		GLfloat	ret[MAX_GL_TEXPARAMETER_COUNT];
		int n = gl_texparameter_count(pname);
		int i;
		glGetTexParameterfv(target, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

# 1.0
void
glGetTexParameteriv_p(target, pname)
	GLenum	target
	GLenum	pname
	PPCODE:
	{
		GLint	ret[MAX_GL_TEXPARAMETER_COUNT];
		int n = gl_texparameter_count(pname);
		int i;
		glGetTexParameteriv(target, pname, &ret[0]);
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

# 1.0
void
glHint(target, mode)
	GLenum	target
	GLenum	mode

# 1.0
void
glIndexd(c)
	GLdouble	c

# 1.0
void
glIndexi(c)
	GLint	c

# 1.0
void
glIndexMask(mask)
	GLuint	mask

#ifdef GL_VERSION_1_1

# 1.1
void
glIndexPointer_c(type, stride, pointer)
	GLenum	type
	GLsizei	stride
	void *	pointer
	CODE:
	glIndexPointer(type, stride, pointer);

void
glIndexPointer_s(type, stride, pointer)
	GLenum	type
	GLsizei	stride
	SV *	pointer
	CODE:
	{
		int width = stride ? stride : sizeof(type);
		void * pointer_s = EL(pointer, width);
		glIndexPointer(type, stride, pointer_s);
	}

void
glIndexPointer_p(oga)
	OpenGL::Array oga
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glIndexPointer(oga->types[0], 0, oga->bind ? 0 : oga->data);
#else
		glIndexPointer(oga->types[0], 0, oga->data);
#endif
	}

#endif

# 1.0
void
glInitNames()

#ifdef GL_VERSION_1_1

# 1.1
void
glInterleavedArrays_c(format, stride, pointer)
	GLenum	format
	GLsizei	stride
	void *	pointer
	CODE:
	glInterleavedArrays(format, stride, pointer);

#endif

# 1.0
GLboolean
glIsEnabled(cap)
	GLenum	cap

# 1.0
GLboolean
glIsList(list)
	GLuint	list

#ifdef GL_VERSION_1_1

# 1.1
GLboolean
glIsTexture(list)
	GLuint	list

#endif


# 1.0
void
glLightf(light, pname, param)
	GLenum	light
	GLenum	pname
	GLfloat	param

# 1.0
void
glLighti(light, pname, param)
	GLenum	light
	GLenum	pname
	GLint	param

# 1.0
void
glLightfv_c(light, pname, params)
	GLenum	light
	GLenum	pname
	void *	params
	CODE:
	glLightfv(light, pname, params);

# 1.0
void
glLightiv_c(light, pname, params)
	GLenum	light
	GLenum	pname
	void *	params
	CODE:
	glLightiv(light, pname, params);

# 1.0
void
glLightfv_s(light, pname, params)
	GLenum	light
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params, sizeof(GLfloat)*gl_light_count(pname));
	glLightfv(light, pname, params_s);
	}

# 1.0
void
glLightiv_s(light, pname, params)
	GLenum	light
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint)*gl_light_count(pname));
	glLightiv(light, pname, params_s);
	}

# 1.0
void
glLightfv_p(light, pname, ...)
	GLenum	light
	GLenum	pname
	CODE:
	{
		GLfloat p[MAX_GL_LIGHT_COUNT];
		int i;
		if ((items-2) != gl_light_count(pname))
			croak("Incorrect number of arguments");
		for(i=2;i<items;i++)
			p[i-2] = SvNV(ST(i));
		glLightfv(light, pname, &p[0]);
	}

# 1.0
void
glLightiv_p(light, pname, ...)
	GLenum	light
	GLenum	pname
	CODE:
	{
		GLint p[MAX_GL_LIGHT_COUNT];
		int i;
		if ((items-2) != gl_light_count(pname))
			croak("Incorrect number of arguments");
		for(i=2;i<items;i++)
			p[i-2] = SvIV(ST(i));
		glLightiv(light, pname, &p[0]);
	}

# 1.0
void
glLightModelf(pname, param)
	GLenum	pname
	GLfloat	param

# 1.0
void
glLightModeli(pname, param)
	GLenum	pname
	GLint	param

# 1.0
void
glLightModeliv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glLightModeliv(pname, params);

# 1.0
void
glLightModelfv_c(pname, params)
	GLenum	pname
	void *	params
	CODE:
	glLightModelfv(pname, params);

# 1.0
void
glLightModeliv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint)*gl_lightmodel_count(pname));
	glLightModeliv(pname, params_s);
	}

# 1.0
void
glLightModelfv_s(pname, params)
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params,
		sizeof(GLfloat)*gl_lightmodel_count(pname));
	glLightModelfv(pname, params_s);
	}

# 1.0
void
glLightModelfv_p(pname, ...)
	GLenum	pname
	CODE:
	{
		GLfloat p[MAX_GL_LIGHTMODEL_COUNT];
		int i;
		if ((items-1) != gl_lightmodel_count(pname))
			croak("Incorrect number of arguments");
		for(i=1;i<items;i++)
			p[i-1] = SvNV(ST(i));
		glLightModelfv(pname, &p[0]);
	}

# 1.0
void
glLightModeliv_p(pname, ...)
	GLenum	pname
	CODE:
	{
		GLint p[MAX_GL_LIGHTMODEL_COUNT];
		int i;
		if ((items-1) != gl_lightmodel_count(pname))
			croak("Incorrect number of arguments");
		for(i=1;i<items;i++)
			p[i-1] = SvIV(ST(i));
		glLightModeliv(pname, &p[0]);
	}

# 1.0
void
glLineStipple(factor, pattern)
	GLint	factor
	GLushort	pattern

# 1.0
void
glLineWidth(width)
	GLfloat	width

# 1.0
void
glListBase(base)
	GLuint	base

# 1.0
void
glLoadIdentity()

# 1.0
void
glLoadMatrixf_c(m)
	void *	m
	CODE:
	glLoadMatrixf(m);

# 1.0
void
glLoadMatrixd_c(m)
	void *	m
	CODE:
	glLoadMatrixd(m);

# 1.0
void
glLoadMatrixf_s(m)
	SV *	m
	CODE:
	{
	GLfloat * m_s = EL(m, sizeof(GLfloat)*16);
	glLoadMatrixf(m_s);
	}

# 1.0
void
glLoadMatrixd_s(m)
	SV *	m
	CODE:
	{
	GLdouble * m_s = EL(m, sizeof(GLdouble)*16);
	glLoadMatrixd(m_s);
	}

# 1.0
void
glLoadMatrixd_p(...)
	CODE:
	{
		GLdouble m[16];
		int i;
		if (items != 16)
			croak("Incorrect number of arguments");
		for (i=0;i<16;i++)
			m[i] = SvNV(ST(i));
		glLoadMatrixd(&m[0]);
	}

# 1.0
void
glLoadMatrixf_p(...)
	CODE:
	{
		GLfloat m[16];
		int i;
		if (items != 16)
			croak("Incorrect number of arguments");
		for (i=0;i<16;i++)
			m[i] = SvNV(ST(i));
		glLoadMatrixf(&m[0]);
	}

# 1.0
void
glLoadName(name)
	GLuint	name

# 1.0
void
glLogicOp(opcode)
	GLenum	opcode

# 1.0
void
glMap1d_c(target, u1, u2, stride, order, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	stride
	GLint	order
	void *	points
	CODE:
	glMap1d(target, u1, u2, stride, order, points);

# 1.0
void
glMap1f_c(target, u1, u2, stride, order, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	stride
	GLint	order
	void *	points
	CODE:
	glMap1f(target, u1, u2, stride, order, points);

# 1.0
void
glMap1d_s(target, u1, u2, stride, order, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	stride
	GLint	order
	SV *	points
	CODE:
	{
	GLdouble * points_s = EL(points, 0 /*FIXME*/);
	glMap1d(target, u1, u2, stride, order, points_s);
	}

# 1.0
void
glMap1f_s(target, u1, u2, stride, order, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	stride
	GLint	order
	SV *	points
	CODE:
	{
	GLfloat * points_s = EL(points, 0 /*FIXME*/);
	glMap1f(target, u1, u2, stride, order, points_s);
	}

# 1.0
void
glMap1d_p(target, u1, u2, ...)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	CODE:
	{
		int count = items-3;
		GLint order = (items - 3) / gl_map_count(target, GL_COEFF);
		GLdouble * points = malloc(sizeof(GLdouble) * (count+1));
		int i;
		for (i=0;i<count;i++)
			points[i] = SvNV(ST(i+3));
		glMap1d(target, u1, u2, 0, order, points);
		free(points);
	}

# 1.0
void
glMap1f_p(target, u1, u2, ...)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	CODE:
	{
		int count = items-3;
		GLint order = (items - 3) / gl_map_count(target, GL_COEFF);
		GLfloat * points = malloc(sizeof(GLfloat) * (count+1));
		int i;
		for (i=0;i<count;i++)
			points[i] = SvNV(ST(i+3));
		glMap1f(target, u1, u2, 0, order, points);
		free(points);
	}

# 1.0
void
glMap2d_c(target, u1, u2, ustride, uorder, v1, v2, vstride, vorder, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	ustride
	GLint	uorder
	GLdouble	v1
	GLdouble	v2
	GLint	vstride
	GLint	vorder
	void *	points
	CODE:
	glMap2d(target, u1, u2, ustride, uorder, v1, v2,
		vstride, vorder, points);

# 1.0
void
glMap2f_c(target, u1, u2, ustride, uorder, v1, v2, vstride, vorder, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	ustride
	GLint	uorder
	GLdouble	v1
	GLdouble	v2
	GLint	vstride
	GLint	vorder
	void *	points
	CODE:
	glMap2f(target, u1, u2, ustride, uorder, v1, v2,
		vstride, vorder, points);

# 1.0
void
glMap2d_s(target, u1, u2, ustride, uorder, v1, v2, vstride, vorder, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	ustride
	GLint	uorder
	GLdouble	v1
	GLdouble	v2
	GLint	vstride
	GLint	vorder
	SV *	points
	CODE:
	{
	GLdouble * points_s = EL(points, 0 /*FIXME*/);
	glMap2d(target, u1, u2, ustride, uorder, v1, v2,
		vstride, vorder, points_s);
	}

# 1.0
void
glMap2f_s(target, u1, u2, ustride, uorder, v1, v2, vstride, vorder, points)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	ustride
	GLint	uorder
	GLdouble	v1
	GLdouble	v2
	GLint	vstride
	GLint	vorder
	SV *	points
	CODE:
	{
	GLfloat * points_s = EL(points, 0 /*FIXME*/);
	glMap2f(target, u1, u2, ustride, uorder, v1, v2,
		vstride, vorder, points_s);
	}

# 1.0
void
glMap2d_p(target, u1, u2, uorder, v1, v2, ...)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	uorder
	GLdouble	v1
	GLdouble	v2
	CODE:
	{
		int count = items-6;
		GLint vorder = (count / uorder) / gl_map_count(target, GL_COEFF);
		GLdouble * points = malloc(sizeof(GLdouble) * (count+1));
		int i;
		for (i=0;i<count;i++)
			points[i] = SvNV(ST(i+6));
		glMap2d(target, u1, u2, 0, uorder, v1, v2, 0, vorder, points);
		free(points);
	}

# 1.0
void
glMap2f_p(target, u1, u2, uorder, v1, v2, ...)
	GLenum	target
	GLdouble	u1
	GLdouble	u2
	GLint	uorder
	GLdouble	v1
	GLdouble	v2
	CODE:
	{
		int count = items-6;
		GLint vorder = (count / uorder) / gl_map_count(target, GL_COEFF);
		GLfloat * points = malloc(sizeof(GLfloat) * (count+1));
		int i;
		for (i=0;i<count;i++)
			points[i] = SvNV(ST(i+6));
		glMap2f(target, u1, u2, 0, uorder, v1, v2, 0, vorder, points);
		free(points);
	}

# 1.0
void
glMapGrid1d(un, u1, u2)
	GLint	un
	GLdouble	u1
	GLdouble	u2

# 1.0
void
glMapGrid1f(un, u1, u2)
	GLint	un
	GLfloat	u1
	GLfloat	u2

# 1.0
void
glMapGrid2d(un, u1, u2, vn, v1, v2)
	GLint	un
	GLdouble	u1
	GLdouble	u2
	GLint	vn
	GLdouble	v1
	GLdouble	v2

# 1.0
void
glMapGrid2f(un, u1, u2, vn, v1, v2)
	GLint	un
	GLfloat	u1
	GLfloat	u2
	GLint	vn
	GLfloat	v1
	GLfloat	v2

# 1.0
void
glMaterialf(face, pname, param)
	GLenum	face
	GLenum	pname
	GLfloat	param

# 1.0
void
glMateriali(face, pname, param)
	GLenum	face
	GLenum	pname
	GLint	param

# 1.0
void
glMaterialfv_c(face, pname, param)
	GLenum	face
	GLenum	pname
	void *	param
	CODE:
	glMaterialfv(face, pname, param);

# 1.0
void
glMaterialiv_c(face, pname, param)
	GLenum	face
	GLenum	pname
	void *	param
	CODE:
	glMaterialiv(face, pname, param);

# 1.0
void
glMaterialfv_s(face, pname, param)
	GLenum	face
	GLenum	pname
	SV *	param
	CODE:
	{
	GLfloat * param_s = EL(param, sizeof(GLfloat)*gl_material_count(pname));
	glMaterialfv(face, pname, param_s);
	}

# 1.0
void
glMaterialiv_s(face, pname, param)
	GLenum	face
	GLenum	pname
	SV *	param
	CODE:
	{
	GLint * param_s = EL(param, sizeof(GLint)*gl_material_count(pname));
	glMaterialiv(face, pname, param_s);
	}

# 1.0
void
glMaterialfv_p(face, pname, ...)
	GLenum	face
	GLenum	pname
	CODE:
	{
		GLfloat p[MAX_GL_MATERIAL_COUNT];
		int i;
		if ((items-2) != gl_material_count(pname))
			croak("Incorrect number of arguments");
		for(i=2;i<items;i++)
			p[i-2] = SvNV(ST(i));
		glMaterialfv(face, pname, &p[0]);
	}

# 1.0
void
glMaterialiv_p(face, pname, ...)
	GLenum	face
	GLenum	pname
	CODE:
	{
		GLint p[MAX_GL_MATERIAL_COUNT];
		int i;
		if ((items-2) != gl_material_count(pname))
			croak("Incorrect number of arguments");
		for(i=2;i<items;i++)
			p[i-2] = SvIV(ST(i));
		glMaterialiv(face, pname, &p[0]);
	}

# 1.0
void
glMatrixMode(mode)
	GLenum	mode

# 1.0
void
glMultMatrixd_p(...)
	CODE:
	{
		GLdouble m[16];
		int i;
		if (items != 16)
			croak("Incorrect number of arguments");
		for (i=0;i<16;i++)
			m[i] = SvNV(ST(i));
		glMultMatrixd(&m[0]);
	}

# 1.0
void
glMultMatrixf_p(...)
	CODE:
	{
		GLfloat m[16];
		int i;
		if (items != 16)
			croak("Incorrect number of arguments");
		for (i=0;i<16;i++)
			m[i] = SvNV(ST(i));
		glMultMatrixf(&m[0]);
	}

# 1.0
void
glNewList(list, mode)
	GLuint	list
	GLenum	mode

# 1.0
void
glEndList()

#ifdef GL_VERSION_1_1

# 1.1
void
glNormalPointer_c(type, stride, pointer)
	GLenum	type
	GLsizei	stride
	void *	pointer
	CODE:
	glNormalPointer(type, stride, pointer);


void
glNormalPointer_s(type, stride, pointer)
	GLenum	type
	GLsizei	stride
	SV *	pointer
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*3);
		void * pointer_s = EL(pointer, width);
		glNormalPointer(type, stride, pointer_s);
	}

void
glNormalPointer_p(oga)
	OpenGL::Array oga
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glNormalPointer(oga->types[0], 0, oga->bind ? 0 : oga->data);
#else
		glNormalPointer(oga->types[0], 0, oga->data);
#endif
	}

#endif

# 1.0
void
glOrtho(left, right, bottom, top, zNear, zFar)
	GLdouble	left
	GLdouble	right
	GLdouble	bottom
	GLdouble	top
	GLdouble	zNear
	GLdouble	zFar

# 1.0
void
glPassThrough(token)
	GLfloat	token

# 1.0
void
glPixelMapfv_c(map, mapsize, values)
	GLenum	map
	GLsizei	mapsize
	void *	values
	CODE:
	glPixelMapfv(map, mapsize, values);

# 1.0
void
glPixelMapuiv_c(map, mapsize, values)
	GLenum	map
	GLsizei	mapsize
	void *	values
	CODE:
	glPixelMapuiv(map, mapsize, values);

# 1.0
void
glPixelMapusv_c(map, mapsize, values)
	GLenum	map
	GLsizei	mapsize
	void *	values
	CODE:
	glPixelMapusv(map, mapsize, values);

# 1.0
void
glPixelMapfv_s(map, mapsize, values)
	GLenum	map
	GLsizei	mapsize
	SV *	values
	CODE:
	{
	GLfloat * values_s = EL(values, sizeof(GLfloat)*mapsize);
	glPixelMapfv(map, mapsize, values_s);
	}

# 1.0
void
glPixelMapuiv_s(map, mapsize, values)
	GLenum	map
	GLsizei	mapsize
	SV *	values
	CODE:
	{
	GLuint * values_s = EL(values, sizeof(GLuint)*mapsize);
	glPixelMapuiv(map, mapsize, values_s);
	}

# 1.0
void
glPixelMapusv_s(map, mapsize, values)
	GLenum	map
	GLsizei	mapsize
	SV *	values
	CODE:
	{
	GLushort * values_s = EL(values, sizeof(GLushort)*mapsize);
	glPixelMapusv(map, mapsize, values_s);
	}

# 1.0
void
glPixelMapfv_p(map, ...)
	GLenum	map
	CODE:
	{
		GLint mapsize = items-1;
		GLfloat * values;
		int i;
		values = malloc(sizeof(GLfloat) * (mapsize+1));
		for (i=0;i<mapsize;i++)
			values[i] = SvNV(ST(i+1));
		glPixelMapfv(map, mapsize, values);
		free(values);
	}

# 1.0
void
glPixelMapuiv_p(map, ...)
	GLenum	map
	CODE:
	{
		GLint mapsize = items-1;
		GLuint * values;
		int i;
		values = malloc(sizeof(GLuint) * (mapsize+1));
		for (i=0;i<mapsize;i++)
			values[i] = SvIV(ST(i+1));
		glPixelMapuiv(map, mapsize, values);
		free(values);
	}

# 1.0
void
glPixelMapusv_p(map, ...)
	GLenum	map
	CODE:
	{
		GLint mapsize = items-1;
		GLushort * values;
		int i;
		values = malloc(sizeof(GLushort) * (mapsize+1));
		for (i=0;i<mapsize;i++)
			values[i] = SvIV(ST(i+1));
		glPixelMapusv(map, mapsize, values);
		free(values);
	}

# 1.0
void
glPixelStoref(pname, param)
	GLenum	pname
	GLfloat	param

# 1.0
void
glPixelStorei(pname, param)
	GLenum	pname
	GLint	param

# 1.0
void
glPixelTransferf(pname, param)
	GLenum	pname
	GLfloat	param

# 1.0
void
glPixelTransferi(pname, param)
	GLenum	pname
	GLint	param

# 1.0
void
glPixelZoom(xfactor, yfactor)
	GLfloat	xfactor
	GLfloat	yfactor

# 1.0
void
glPointSize(size)
	GLfloat	size

# 1.0
void
glPolygonMode(face, mode)
	GLenum	face
	GLenum	mode

#ifdef GL_VERSION_1_1

# 1.1
void
glPolygonOffset(factor, units)
	GLfloat	factor
	GLfloat	units

#endif

# 1.0
void
glPolygonStipple_c(mask)
	void *	mask
	CODE:
	glPolygonStipple(mask);

# 1.0
void
glPolygonStipple_s(mask)
	SV *	mask
	CODE:
	{
	GLubyte * ptr = ELI(mask, 32, 32, GL_COLOR_INDEX, GL_BITMAP, 0);
	glPolygonStipple(ptr);
	}

void
glPolygonStipple_p(...)
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(0)), items, 32, 32, 1,
		GL_COLOR_INDEX, GL_BITMAP, 0);
	glPolygonStipple(ptr);
	glPopClientAttrib();
	free(ptr);
	}

#ifdef GL_VERSION_1_1

# 1.1
void
glPrioritizeTextures_c(n, textures, priorities)
	GLsizei	n
	void *	textures
	void *	priorities
	CODE:
	glPrioritizeTextures(n, textures, priorities);

# 1.1
void
glPrioritizeTextures_s(n, textures, priorities)
	GLsizei	n
	SV *	textures
	SV *	priorities
	CODE:
	{
	GLuint * textures_s = EL(textures, sizeof(GLuint) * n);
	GLclampf * priorities_s = EL(priorities, sizeof(GLclampf) * n);
	glPrioritizeTextures(n, textures_s, priorities_s);
	}

# 1.1
void
glPrioritizeTextures_p(...)
	CODE:
	{
		GLsizei n = items/2;
		GLuint * textures = malloc(sizeof(GLuint) * (n+1));
		GLclampf * prior = malloc(sizeof(GLclampf) * (n+1));
		int i;
		
		for (i=0;i<n;i++) {
			textures[i] = SvIV(ST(i * 2 + 0));
			prior[i] = SvNV(ST(i * 2 + 1));
		}
		
		glPrioritizeTextures(n, textures, prior);
		
		free(textures);
		free(prior);
	}

#endif



# 1.0
void
glPushAttrib(mask)
	GLbitfield	mask

# 1.0
void
glPopAttrib()

# 1.0
void
glPushClientAttrib(mask)
	GLbitfield	mask

# 1.0
void
glPopClientAttrib()

# 1.0
void
glPushMatrix()

# 1.0
void
glPopMatrix()

# 1.0
void
glPushName(name)
	GLuint	name

# 1.0
void
glPopName()


# 1.0
void
glReadBuffer(mode)
	GLenum	mode

# 1.0
void
glReadPixels_c(x, y, width, height, format, type, pixels)
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glReadPixels(x, y, width, height, format, type, pixels);

# 1.0
void
glReadPixels_s(x, y, width, height, format, type, pixels)
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
		void * ptr = ELI(pixels, width, height,
			format, type, gl_pixelbuffer_pack);
		glReadPixels(x, y, width, height, format, type, ptr);
	}

# 1.0
void
glReadPixels_p(x, y, width, height, format, type)
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	PPCODE:
	{
		void * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_PACK_ROW_LENGTH, 0);
		glPixelStorei(GL_PACK_ALIGNMENT, 1);
		ptr = allocate_image_ST(width, height, 1, format, type, 0);
		glReadPixels(x, y, width, height, format, type, ptr);
		sp = unpack_image_ST(sp, ptr, width, height, 1, format, type, 0);
		free(ptr);
		glPopClientAttrib();
	}

# 1.0
void
glRecti(x1, y1, x2, y2)
	GLint	x1
	GLint	y1
	GLint	x2
	GLint	y2
	ALIAS:
		glRectiv_p = 1


# 1.0
void
glRects(x1, y1, x2, y2)
	GLshort	x1
	GLshort	y1
	GLshort	x2
	GLshort	y2
	ALIAS:
		glRectsv_p = 1

# 1.0
void
glRectd(x1, y1, x2, y2)
	GLdouble	x1
	GLdouble	y1
	GLdouble	x2
	GLdouble	y2
	ALIAS:
		glRectdv_p = 1

# 1.0
void
glRectf(x1, y1, x2, y2)
	GLfloat	x1
	GLfloat	y1
	GLfloat	x2
	GLfloat	y2
	ALIAS:
		glRectfv_p = 1


# 1.0
void
glRectsv_c(v1, v2)
	void *	v1
	void *	v2
	CODE:
	glRectsv(v1, v2);

# 1.0
void
glRectiv_c(v1, v2)
	void *	v1
	void *	v2
	CODE:
	glRectiv(v1, v2);

# 1.0
void
glRectfv_c(v1, v2)
	void *	v1
	void *	v2
	CODE:
	glRectfv(v1, v2);

# 1.0
void
glRectdv_c(v1, v2)
	void *	v1
	void *	v2
	CODE:
	glRectdv(v1, v2);

# 1.0
void
glRectdv_s(v1, v2)
	SV *	v1
	SV *	v2
	CODE:
	{
	GLdouble * v1_s = EL(v1, sizeof(GLdouble)*2);
	GLdouble * v2_s = EL(v2, sizeof(GLdouble)*2);
	glRectdv(v1_s, v2_s);
	}

# 1.0
void
glRectfv_s(v1, v2)
	SV *	v1
	SV *	v2
	CODE:
	{
	GLfloat * v1_s = EL(v1, sizeof(GLfloat)*2);
	GLfloat * v2_s = EL(v2, sizeof(GLfloat)*2);
	glRectfv(v1_s, v2_s);
	}

# 1.0
void
glRectiv_s(v1, v2)
	SV *	v1
	SV *	v2
	CODE:
	{
	GLint * v1_s = EL(v1, sizeof(GLint)*2);
	GLint * v2_s = EL(v2, sizeof(GLint)*2);
	glRectiv(v1_s, v2_s);
	}

# 1.0
void
glRectsv_s(v1, v2)
	SV *	v1
	SV *	v2
	CODE:
	{
	GLshort * v1_s = EL(v1, sizeof(GLshort)*2);
	GLshort * v2_s = EL(v2, sizeof(GLshort)*2);
	glRectsv(v1_s, v2_s);
	}

# 1.0
GLint
glRenderMode(mode)
	GLenum	mode

# 1.0
void
glRotated(angle, x, y, z)
	GLdouble	angle
	GLdouble	x
	GLdouble	y
	GLdouble	z

# 1.0
void
glRotatef(angle, x, y, z)
	GLfloat	angle
	GLfloat	x
	GLfloat	y
	GLfloat	z

# 1.0
void
glScaled(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z

# 1.0
void
glScalef(x, y, z)
	GLfloat	x
	GLfloat	y
	GLfloat	z

# 1.0
void
glScissor(x, y, width, height)
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height

# 1.0
void
glSelectBuffer_c(size, list)
	GLsizei	size
	void *	list
	CODE:
	glSelectBuffer(size, list);

# 1.0
void
glShadeModel(mode)
	GLenum	mode

# 1.0
void
glStencilFunc(func, ref, mask)
	GLenum	func
	GLint	ref
	GLuint	mask

# 1.0
void
glStencilMask(mask)
	GLuint	mask

# 1.0
void
glStencilOp(fail, zfail, zpass)
	GLenum	fail
	GLenum	zfail
	GLenum	zpass


#ifdef GL_VERSION_1_1

# 1.1
void
glTexCoordPointer_c(size, type, stride, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	void *	pointer
	CODE:
	glTexCoordPointer(size, type, stride, pointer);

void
glTexCoordPointer_s(size, type, stride, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	SV *	pointer
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*size);
		void * pointer_s = EL(pointer, width);
		glTexCoordPointer(size, type, stride, pointer_s);
	}

void
glTexCoordPointer_p(size, oga)
	GLint	size
	OpenGL::Array oga
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glTexCoordPointer(size, oga->types[0], 0, oga->bind ? 0 : oga->data);
#else
		glTexCoordPointer(size, oga->types[0], 0, oga->data);
#endif
	}

#endif

# 1.0
void
glTexEnvf(target, pname, param)
	GLenum	target
	GLenum	pname
	GLfloat	param

# 1.0
void
glTexEnvi(target, pname, param)
	GLenum	target
	GLenum	pname
	GLint	param

# 1.0
void
glTexEnvfv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params, sizeof(GLfloat)*gl_texenv_count(pname));
	glTexEnvfv(target, pname, params_s);
	}

# 1.0
void
glTexEnviv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params, sizeof(GLint)*gl_texenv_count(pname));
	glTexEnviv(target, pname, params_s);
	}

# 1.0
void
glTexEnvfv_p(target, pname, ...)
	GLenum	target
	GLenum	pname
	CODE:
	{
		GLfloat p[MAX_GL_TEXENV_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texenv_count(pname))
			croak("Incorrect number of arguments");
		for (i=2;i<items;i++)
			p[i-2] = SvNV(ST(i));
		glTexEnvfv(target, pname, &p[0]);
	}

# 1.0
void
glTexEnviv_p(target, pname, ...)
	GLenum	target
	GLenum	pname
	CODE:
	{
		GLint p[MAX_GL_TEXENV_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texenv_count(pname))
			croak("Incorrect number of arguments");
		for (i=2;i<items;i++)
			p[i-2] = SvNV(ST(i));
		glTexEnviv(target, pname, &p[0]);
	}

# 1.0
void
glTexGend(Coord, pname, param)
	GLenum	Coord
	GLenum	pname
	GLdouble	param

# 1.0
void
glTexGenf(Coord, pname, param)
	GLenum	Coord
	GLenum	pname
	GLint	param

# 1.0
void
glTexGeni(Coord, pname, param)
	GLenum	Coord
	GLenum	pname
	GLint	param

# 1.0
void
glTexGendv_c(Coord, pname, params)
	GLenum	Coord
	GLenum	pname
	void *	params
	CODE:
	glTexGendv(Coord, pname, params);

# 1.0
void
glTexGenfv_c(Coord, pname, params)
	GLenum	Coord
	GLenum	pname
	void *	params
	CODE:
	glTexGenfv(Coord, pname, params);

# 1.0
void
glTexGeniv_c(Coord, pname, params)
	GLenum	Coord
	GLenum	pname
	void *	params
	CODE:
	glTexGeniv(Coord, pname, params);

# 1.0
void
glTexGendv_s(Coord, pname, params)
	GLenum	Coord
	GLenum	pname
	SV *	params
	CODE:
	{
	GLdouble * params_s = EL(params,
		sizeof(GLdouble)* gl_texgen_count(pname));
	glTexGendv(Coord, pname, params_s);
	}

# 1.0
void
glTexGenfv_s(Coord, pname, params)
	GLenum	Coord
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params,
		sizeof(GLfloat)* gl_texgen_count(pname));
	glTexGenfv(Coord, pname, params_s);
	}

# 1.0
void
glTexGeniv_s(Coord, pname, params)
	GLenum	Coord
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params,
		sizeof(GLint)* gl_texgen_count(pname));
	glTexGeniv(Coord, pname, params_s);
	}

# 1.0
void
glTexGendv_p(Coord, pname, ...)
	GLenum	Coord
	GLenum	pname
	CODE:
	{
		GLdouble p[MAX_GL_TEXGEN_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texgen_count(pname))
			croak("Incorrect number of arguments");
		for (i=2;i<items;i++)
			p[i-2] = SvNV(ST(i));
		glTexGendv(Coord, pname, &p[0]);
	}

# 1.0
void
glTexGenfv_p(Coord, pname, ...)
	GLenum	Coord
	GLenum	pname
	CODE:
	{
		GLfloat p[MAX_GL_TEXGEN_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texgen_count(pname))
			croak("Incorrect number of arguments");
		for (i=2;i<items;i++)
			p[i-2] = SvNV(ST(i));
		glTexGenfv(Coord, pname, &p[0]);
	}

# 1.0
void
glTexGeniv_p(Coord, pname, ...)
	GLenum	Coord
	GLenum	pname
	CODE:
	{
		GLint p[MAX_GL_TEXGEN_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texgen_count(pname))
			croak("Incorrect number of arguments");
		for (i=2;i<items;i++)
			p[i-2] = SvIV(ST(i));
		glTexGeniv(Coord, pname, &p[0]);
	}

# 1.0
void
glTexImage1D_c(target, level, internalformat, width, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLint	border
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glTexImage1D(target, level, internalformat,
		width, border, format, type, pixels);

# 1.0
void
glTexImage1D_s(target, level, internalformat, width, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLint	border
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
	GLvoid * ptr = ELI(pixels, width, 1, format, type,
		gl_pixelbuffer_unpack);
	glTexImage1D(target, level, internalformat,
		width, border, format, type, ptr);
	}

# 1.2
void
glTexImage1D_p(target, level, internalformat, width, border, format, type, ...)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLint	border
	GLenum	format
	GLenum	type
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(7)), items-7, width, 1, 1, format, type, 0);
	glTexImage1D(target, level, internalformat,
		width, border, format, type, ptr);
	glPopClientAttrib();
	free(ptr);
	}

# 1.0
void
glTexImage2D_c(target, level, internalformat, width, height, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLsizei	height
	GLint	border
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glTexImage2D(target, level, internalformat,
		width, height, border, format, type, pixels);

# 1.0
void
glTexImage2D_s(target, level, internalformat, width, height, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLsizei	height
	GLint	border
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
		GLvoid * ptr = NULL;
		if (pixels)
		{
			ptr = ELI(pixels, width, height,
				format, type, gl_pixelbuffer_unpack);
		}
		glTexImage2D(target, level, internalformat,
			width, height, border, format, type, ptr);
	}

# 1.2
void
glTexImage2D_p(target, level, internalformat, width, height, border, format, type, ...)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLsizei	height
	GLint	border
	GLenum	format
	GLenum	type
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(8)), items-8, width, height,
		1, format, type, 0);
	glTexImage2D(target, level, internalformat,
		width, height, border, format, type, ptr);
	glPopClientAttrib();
	free(ptr);
	}

#ifdef GL_VERSION_1_2

# 1.2
void
glTexImage3D_c(target, level, internalformat, width, height, depth, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLint	border
	GLenum	format
	GLenum	type
	void *	pixels
	INIT:
		loadProc(glTexImage3D,"glTexImage3D");
	CODE:
		glTexImage3D(target, level, internalformat,
			width, height, depth, border, format, type, pixels);

# 1.2
void
glTexImage3D_s(target, level, internalformat, width, height, depth, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLint	border
	GLenum	format
	GLenum	type
	SV *	pixels
	INIT:
		loadProc(glTexImage3D,"glTexImage3D");
	CODE:
	{
		GLvoid * ptr = ELI(pixels, width, height, format,
			type, gl_pixelbuffer_unpack);
		glTexImage3D(target, level, internalformat,
			width, height, depth, border, format, type, ptr);
	}

# 1.2
void
glTexImage3D_p(target, level, internalformat, width, height, depth, border, format, type, ...)
	GLenum	target
	GLint	level
	GLint	internalformat
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLint	border
	GLenum	format
	GLenum	type
	INIT:
		loadProc(glTexImage3D,"glTexImage3D");
	CODE:
	{
		GLvoid * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		ptr = pack_image_ST(&(ST(9)), items-9, width, height,
			depth, format, type, 0);
		glTexImage3D(target, level, internalformat,
			width, height, depth, border, format, type, ptr);
		glPopClientAttrib();
		free(ptr);
	}

#endif

# 1.0
void
glTexParameterf(target, pname, param)
	GLenum	target
	GLenum	pname
	GLfloat	param

# 1.0
void
glTexParameteri(target, pname, param)
	GLenum	target
	GLenum	pname
	GLint	param

# 1.0
void
glTexParameterfv_c(target, pname, params)
	GLenum	target
	GLenum	pname
	void *	params
	CODE:
	glTexParameterfv(target, pname, params);

# 1.0
void
glTexParameteriv_c(target, pname, params)
	GLenum	target
	GLenum	pname
	void *	params
	CODE:
	glTexParameteriv(target, pname, params);

# 1.0
void
glTexParameterfv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV *	params
	CODE:
	{
	GLfloat * params_s = EL(params,
		sizeof(GLfloat)*gl_texparameter_count(pname));
	glTexParameterfv(target, pname, params_s);
	}

# 1.0
void
glTexParameteriv_s(target, pname, params)
	GLenum	target
	GLenum	pname
	SV *	params
	CODE:
	{
	GLint * params_s = EL(params,
		sizeof(GLint)*gl_texparameter_count(pname));
	glTexParameteriv(target, pname, params_s);
	}

# 1.0
void
glTexParameterfv_p(target, pname, ...)
	GLenum	target
	GLenum	pname
	CODE:
	{
		GLfloat p[MAX_GL_TEXPARAMETER_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texparameter_count(pname))
			croak("Incorrect number of arguments");
		for(i=0;i<n;i++)
			p[i] = SvNV(ST(i+2));
		glTexParameterfv(target, pname, &p[0]);
	}

# 1.0
void
glTexParameteriv_p(target, pname, ...)
	GLenum	target
	GLenum	pname
	CODE:
	{
		GLint p[MAX_GL_TEXPARAMETER_COUNT];
		int n = items-2;
		int i;
		if (n != gl_texparameter_count(pname))
			croak("Incorrect number of arguments");
		for(i=0;i<n;i++)
			p[i] = SvIV(ST(i+2));
		glTexParameteriv(target, pname, &p[0]);
	}

#ifdef GL_VERSION_1_1

# 1.1
void
glTexSubImage1D_c(target, level, xoffset, width, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLsizei	width
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glTexSubImage1D(target, level, xoffset, width, format, type, pixels);

# 1.1
void
glTexSubImage1D_s(target, level, xoffset, width, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLsizei	width
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
	GLvoid * ptr = ELI(pixels, width, 1, format, type, gl_pixelbuffer_unpack);
	glTexSubImage1D(target, level, xoffset, width, format, type, ptr);
	}

# 1.1
void
glTexSubImage1D_p(target, level, xoffset, width, format, type, ...)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLsizei	width
	GLenum	format
	GLenum	type
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(7)), items-7, width, 1, 1, format, type, 0);
	glTexSubImage1D(target, level, xoffset, width, format, type, ptr);
	glPopClientAttrib();
	free(ptr);
	}

# 1.1
void
glTexSubImage2D_c(target, level, xoffset, yoffset, width, height, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	void *	pixels
	CODE:
	glTexSubImage2D(target, level, xoffset, yoffset,
		width, height, format, type, pixels);

# 1.1
void
glTexSubImage2D_s(target, level, xoffset, yoffset, width, height, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	SV *	pixels
	CODE:
	{
	GLvoid * ptr = ELI(pixels, width, height,
		format, type, gl_pixelbuffer_unpack);
	glTexSubImage2D(target, level, xoffset, yoffset,
		width, height, format, type, ptr);
	}

# 1.1
void
glTexSubImage2D_p(target, level, xoffset, yoffset, width, height, format, type, ...)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	CODE:
	{
	GLvoid * ptr;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	ptr = pack_image_ST(&(ST(8)), items-8, width, height, 1,
		format, type, 0);
	glTexSubImage2D(target, level, xoffset, yoffset,
		width, height, format, type, ptr);
	glPopClientAttrib();
	free(ptr);
	}

#ifdef GL_VERSION_1_2

# 1.2
void
glTexSubImage3D_c(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLenum	format
	GLenum	type
	void *	pixels
	INIT:
		loadProc(glTexSubImage3D,"glTexSubImage3D");
	CODE:
		glTexSubImage3D(target, level, xoffset, yoffset, zoffset,
			width, height, depth, format, type, pixels);

# 1.2
void
glTexSubImage3D_s(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLenum	format
	GLenum	type
	SV *	pixels
	INIT:
		loadProc(glTexSubImage3D,"glTexSubImage3D");
	CODE:
	{
		GLvoid * ptr = ELI(pixels, width, height,
			format, type, gl_pixelbuffer_unpack);
		glTexSubImage3D(target, level, xoffset, yoffset, zoffset,
			width, height, depth, format, type, ptr);
	}

# 1.1
void
glTexSubImage3D_p(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, ...)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLenum	format
	GLenum	type
	INIT:
		loadProc(glTexSubImage3D,"glTexSubImage3D");
	CODE:
	{
		GLvoid * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		ptr = pack_image_ST(&(ST(10)), items-10, width, height,
			depth, format, type, 0);
		glTexSubImage3D(target, level, xoffset, yoffset, zoffset,
			width, height, depth, format, type, ptr);
		glPopClientAttrib();
		free(ptr);
	}

#endif

#endif

# 1.0
void
glTranslated(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z

# 1.0
void
glTranslatef(x, y, z)
	GLfloat	x
	GLfloat	y
	GLfloat	z


#ifdef GL_VERSION_1_1

# 1.1
void
glVertexPointer_c(size, type, stride, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	void *	pointer
	CODE:
		glVertexPointer(size, type, stride, pointer);

void
glVertexPointer_s(size, type, stride, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	SV *	pointer
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*size);
		void * pointer_s = EL(pointer, width);
		glVertexPointer(size, type, stride, pointer_s);
	}

void
glVertexPointer_p(size, oga)
	GLint	size
	OpenGL::Array oga
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glVertexPointer(size, oga->types[0], 0, oga->bind ? 0 : oga->data);
#else
		glVertexPointer(size, oga->types[0], 0, oga->data);
#endif
	}

#endif

# 1.0
void
glViewport(x, y, width, height)
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height

# Generated declarations

void
glVertex2d(x, y)
	GLdouble	x
	GLdouble	y

void
glVertex2dv_c(v)
	void *	v
	CODE:
	glVertex2dv(v);

void
glVertex2dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*2);
		glVertex2dv(v_s);
	}

void
glVertex2dv_p(x, y)
	GLdouble	x
	GLdouble	y
	CODE:
	{
		GLdouble param[2];
		param[0] = x;
		param[1] = y;
		glVertex2dv(param);
	}

void
glVertex2f(x, y)
	GLfloat	x
	GLfloat	y

void
glVertex2fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*2);
		glVertex2fv(v_s);
	}

void
glVertex2fv_c(v)
	void *	v
	CODE:
	glVertex2fv(v);

void
glVertex2fv_p(x, y)
	GLfloat	x
	GLfloat	y
	CODE:
	{
		GLfloat param[2];
		param[0] = x;
		param[1] = y;
		glVertex2fv(param);
	}

void
glVertex2i(x, y)
	GLint	x
	GLint	y

void
glVertex2iv_c(v)
	void *	v
	CODE:
	glVertex2iv(v);

void
glVertex2iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*2);
		glVertex2iv(v_s);
	}

void
glVertex2iv_p(x, y)
	GLint	x
	GLint	y
	CODE:
	{
		GLint param[2];
		param[0] = x;
		param[1] = y;
		glVertex2iv(param);
	}

void
glVertex2s(x, y)
	GLshort	x
	GLshort	y

void
glVertex2sv_c(v)
	void *	v
	CODE:
	glVertex2sv(v);

void
glVertex2sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*2);
		glVertex2sv(v_s);
	}

void
glVertex2sv_p(x, y)
	GLshort	x
	GLshort	y
	CODE:
	{
		GLshort param[2];
		param[0] = x;
		param[1] = y;
		glVertex2sv(param);
	}

void
glVertex3d(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z

void
glVertex3dv_c(v)
	void *	v
	CODE:
	glVertex3dv(v);

void
glVertex3dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*3);
		glVertex3dv(v_s);
	}

void
glVertex3dv_p(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	CODE:
	{
		GLdouble param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertex3dv(param);
	}

void
glVertex3f(x, y, z)
	GLfloat	x
	GLfloat	y
	GLfloat	z

void
glVertex3fv_c(v)
	void *	v
	CODE:
	glVertex3fv(v);

void
glVertex3fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*3);
		glVertex3fv(v_s);
	}

void
glVertex3fv_p(x, y, z)
	GLfloat	x
	GLfloat	y
	GLfloat	z
	CODE:
	{
		GLfloat param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertex3fv(param);
	}

void
glVertex3i(x, y, z)
	GLint	x
	GLint	y
	GLint	z

void
glVertex3iv_c(v)
	void *	v
	CODE:
	glVertex3iv(v);

void
glVertex3iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*3);
		glVertex3iv(v_s);
	}

void
glVertex3iv_p(x, y, z)
	GLint	x
	GLint	y
	GLint	z
	CODE:
	{
		GLint param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertex3iv(param);
	}

void
glVertex3s(x, y, z)
	GLshort	x
	GLshort	y
	GLshort	z

void
glVertex3sv_c(v)
	void *	v
	CODE:
	glVertex3sv(v);

void
glVertex3sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*3);
		glVertex3sv(v_s);
	}

void
glVertex3sv_p(x, y, z)
	GLshort	x
	GLshort	y
	GLshort	z
	CODE:
	{
		GLshort param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertex3sv(param);
	}

void
glVertex4d(x, y, z, w)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w

void
glVertex4dv_c(v)
	void *	v
	CODE:
	glVertex4dv(v);

void
glVertex4dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glVertex4dv(v_s);
	}

void
glVertex4dv_p(x, y, z, w)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w
	CODE:
	{
		GLdouble param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertex4dv(param);
	}

void
glVertex4f(x, y, z, w)
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w

void
glVertex4fv_c(v)
	void *	v
	CODE:
	glVertex4fv(v);

void
glVertex4fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glVertex4fv(v_s);
	}

void
glVertex4fv_p(x, y, z, w)
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w
	CODE:
	{
		GLfloat param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertex4fv(param);
	}

void
glVertex4i(x, y, z, w)
	GLint	x
	GLint	y
	GLint	z
	GLint	w

void
glVertex4iv_c(v)
	void *	v
	CODE:
	glVertex4iv(v);

void
glVertex4iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*4);
		glVertex4iv(v_s);
	}

void
glVertex4iv_p(x, y, z, w)
	GLint	x
	GLint	y
	GLint	z
	GLint	w
	CODE:
	{
		GLint param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertex4iv(param);
	}

void
glVertex4s(x, y, z, w)
	GLshort	x
	GLshort	y
	GLshort	z
	GLshort	w

void
glVertex4sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*4);
		glVertex4sv(v_s);
	}

void
glVertex4sv_c(v)
	void *	v
	CODE:
	glVertex4sv(v);

void
glVertex4sv_p(x, y, z, w)
	GLshort	x
	GLshort	y
	GLshort	z
	GLshort	w
	CODE:
	{
		GLshort param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertex4sv(param);
	}

void
glNormal3b(nx, ny, nz)
	GLbyte	nx
	GLbyte	ny
	GLbyte	nz

void
glNormal3bv_c(v)
	void *	v
	CODE:
	glNormal3bv(v);

void
glNormal3bv_s(v)
	SV *	v
	CODE:
	{
		GLbyte * v_s = EL(v, sizeof(GLbyte)*3);
		glNormal3bv(v_s);
	}

void
glNormal3bv_p(nx, ny, nz)
	GLbyte	nx
	GLbyte	ny
	GLbyte	nz
	CODE:
	{
		GLbyte param[3];
		param[0] = nx;
		param[1] = ny;
		param[2] = nz;
		glNormal3bv(param);
	}

void
glNormal3d(nx, ny, nz)
	GLdouble	nx
	GLdouble	ny
	GLdouble	nz

void
glNormal3dv_c(v)
	void *	v
	CODE:
	glNormal3dv(v);

void
glNormal3dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*3);
		glNormal3dv(v_s);
	}

void
glNormal3dv_p(nx, ny, nz)
	GLdouble	nx
	GLdouble	ny
	GLdouble	nz
	CODE:
	{
		GLdouble param[3];
		param[0] = nx;
		param[1] = ny;
		param[2] = nz;
		glNormal3dv(param);
	}

void
glNormal3f(nx, ny, nz)
	GLfloat	nx
	GLfloat	ny
	GLfloat	nz

void
glNormal3fv_c(v)
	void *	v
	CODE:
	glNormal3fv(v);

void
glNormal3fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*3);
		glNormal3fv(v_s);
	}

void
glNormal3fv_p(nx, ny, nz)
	GLfloat	nx
	GLfloat	ny
	GLfloat	nz
	CODE:
	{
		GLfloat param[3];
		param[0] = nx;
		param[1] = ny;
		param[2] = nz;
		glNormal3fv(param);
	}

void
glNormal3i(nx, ny, nz)
	GLint	nx
	GLint	ny
	GLint	nz

void
glNormal3iv_c(v)
	void *	v
	CODE:
	glNormal3iv(v);

void
glNormal3iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*3);
		glNormal3iv(v_s);
	}

void
glNormal3iv_p(nx, ny, nz)
	GLint	nx
	GLint	ny
	GLint	nz
	CODE:
	{
		GLint param[3];
		param[0] = nx;
		param[1] = ny;
		param[2] = nz;
		glNormal3iv(param);
	}

void
glNormal3s(nx, ny, nz)
	GLshort	nx
	GLshort	ny
	GLshort	nz

void
glNormal3sv_c(v)
	void *	v
	CODE:
	glNormal3sv(v);

void
glNormal3sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*3);
		glNormal3sv(v_s);
	}

void
glNormal3sv_p(nx, ny, nz)
	GLshort	nx
	GLshort	ny
	GLshort	nz
	CODE:
	{
		GLshort param[3];
		param[0] = nx;
		param[1] = ny;
		param[2] = nz;
		glNormal3sv(param);
	}

void
glColor3b(red, green, blue)
	GLbyte	red
	GLbyte	green
	GLbyte	blue

void
glColor3bv_c(v)
	void *	v
	CODE:
	glColor3bv(v);

void
glColor3bv_s(v)
	SV *	v
	CODE:
	{
		GLbyte * v_s = EL(v, sizeof(GLbyte)*3);
		glColor3bv(v_s);
	}

void
glColor3bv_p(red, green, blue)
	GLbyte	red
	GLbyte	green
	GLbyte	blue
	CODE:
	{
		GLbyte param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3bv(param);
	}

void
glColor3d(red, green, blue)
	GLdouble	red
	GLdouble	green
	GLdouble	blue

void
glColor3dv_c(v)
	void *	v
	CODE:
	glColor3dv(v);

void
glColor3dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*3);
		glColor3dv(v_s);
	}

void
glColor3dv_p(red, green, blue)
	GLdouble	red
	GLdouble	green
	GLdouble	blue
	CODE:
	{
		GLdouble param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3dv(param);
	}

void
glColor3f(red, green, blue)
	GLfloat	red
	GLfloat	green
	GLfloat	blue

void
glColor3fv_c(v)
	void *	v
	CODE:
	glColor3fv(v);

void
glColor3fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*3);
		glColor3fv(v_s);
	}

void
glColor3fv_p(red, green, blue)
	GLfloat	red
	GLfloat	green
	GLfloat	blue
	CODE:
	{
		GLfloat param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3fv(param);
	}

void
glColor3i(red, green, blue)
	GLint	red
	GLint	green
	GLint	blue

void
glColor3iv_c(v)
	void *	v
	CODE:
	glColor3iv(v);

void
glColor3iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*3);
		glColor3iv(v_s);
	}

void
glColor3iv_p(red, green, blue)
	GLint	red
	GLint	green
	GLint	blue
	CODE:
	{
		GLint param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3iv(param);
	}

void
glColor3s(red, green, blue)
	GLshort	red
	GLshort	green
	GLshort	blue

void
glColor3sv_c(v)
	void *	v
	CODE:
	glColor3sv(v);

void
glColor3sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*3);
		glColor3sv(v_s);
	}

void
glColor3sv_p(red, green, blue)
	GLshort	red
	GLshort	green
	GLshort	blue
	CODE:
	{
		GLshort param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3sv(param);
	}

void
glColor3ub(red, green, blue)
	GLubyte	red
	GLubyte	green
	GLubyte	blue

void
glColor3ubv_c(v)
	void *	v
	CODE:
	glColor3ubv(v);

void
glColor3ubv_s(v)
	SV *	v
	CODE:
	{
		GLubyte * v_s = EL(v, sizeof(GLubyte)*3);
		glColor3ubv(v_s);
	}

void
glColor3ubv_p(red, green, blue)
	GLubyte	red
	GLubyte	green
	GLubyte	blue
	CODE:
	{
		GLubyte param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3ubv(param);
	}

void
glColor3ui(red, green, blue)
	GLuint	red
	GLuint	green
	GLuint	blue

void
glColor3uiv_c(v)
	void *	v
	CODE:
	glColor3uiv(v);

void
glColor3uiv_s(v)
	SV *	v
	CODE:
	{
		GLuint * v_s = EL(v, sizeof(GLuint)*3);
		glColor3uiv(v_s);
	}

void
glColor3uiv_p(red, green, blue)
	GLuint	red
	GLuint	green
	GLuint	blue
	CODE:
	{
		GLuint param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3uiv(param);
	}

void
glColor3us(red, green, blue)
	GLushort	red
	GLushort	green
	GLushort	blue

void
glColor3usv_c(v)
	void *	v
	CODE:
	glColor3usv(v);

void
glColor3usv_s(v)
	SV *	v
	CODE:
	{
		GLushort * v_s = EL(v, sizeof(GLushort)*3);
		glColor3usv(v_s);
	}

void
glColor3usv_p(red, green, blue)
	GLushort	red
	GLushort	green
	GLushort	blue
	CODE:
	{
		GLushort param[3];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		glColor3usv(param);
	}

void
glColor4b(red, green, blue, alpha)
	GLbyte	red
	GLbyte	green
	GLbyte	blue
	GLbyte	alpha

void
glColor4bv_c(v)
	void *	v
	CODE:
	glColor4bv(v);

void
glColor4bv_s(v)
	SV *	v
	CODE:
	{
		GLbyte * v_s = EL(v, sizeof(GLbyte)*4);
		glColor4bv(v_s);
	}

void
glColor4bv_p(red, green, blue, alpha)
	GLbyte	red
	GLbyte	green
	GLbyte	blue
	GLbyte	alpha
	CODE:
	{
		GLbyte param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4bv(param);
	}

void
glColor4d(red, green, blue, alpha)
	GLdouble	red
	GLdouble	green
	GLdouble	blue
	GLdouble	alpha

void
glColor4dv_c(v)
	void *	v
	CODE:
	glColor4dv(v);

void
glColor4dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glColor4dv(v_s);
	}

void
glColor4dv_p(red, green, blue, alpha)
	GLdouble	red
	GLdouble	green
	GLdouble	blue
	GLdouble	alpha
	CODE:
	{
		GLdouble param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4dv(param);
	}

void
glColor4f(red, green, blue, alpha)
	GLfloat	red
	GLfloat	green
	GLfloat	blue
	GLfloat	alpha

void
glColor4fv_c(v)
	void *	v
	CODE:
	glColor4fv(v);

void
glColor4fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glColor4fv(v_s);
	}

void
glColor4fv_p(red, green, blue, alpha)
	GLfloat	red
	GLfloat	green
	GLfloat	blue
	GLfloat	alpha
	CODE:
	{
		GLfloat param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4fv(param);
	}

void
glColor4i(red, green, blue, alpha)
	GLint	red
	GLint	green
	GLint	blue
	GLint	alpha

void
glColor4iv_c(v)
	void *	v
	CODE:
	glColor4iv(v);

void
glColor4iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*4);
		glColor4iv(v_s);
	}

void
glColor4iv_p(red, green, blue, alpha)
	GLint	red
	GLint	green
	GLint	blue
	GLint	alpha
	CODE:
	{
		GLint param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4iv(param);
	}

void
glColor4s(red, green, blue, alpha)
	GLshort	red
	GLshort	green
	GLshort	blue
	GLshort	alpha

void
glColor4sv_c(v)
	void *	v
	CODE:
	glColor4sv(v);

void
glColor4sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*4);
		glColor4sv(v_s);
	}

void
glColor4sv_p(red, green, blue, alpha)
	GLshort	red
	GLshort	green
	GLshort	blue
	GLshort	alpha
	CODE:
	{
		GLshort param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4sv(param);
	}

void
glColor4ub(red, green, blue, alpha)
	GLubyte	red
	GLubyte	green
	GLubyte	blue
	GLubyte	alpha

void
glColor4ubv_c(v)
	void *	v
	CODE:
	glColor4ubv(v);

void
glColor4ubv_s(v)
	SV *	v
	CODE:
	{
		GLubyte * v_s = EL(v, sizeof(GLubyte)*4);
		glColor4ubv(v_s);
	}

void
glColor4ubv_p(red, green, blue, alpha)
	GLubyte	red
	GLubyte	green
	GLubyte	blue
	GLubyte	alpha
	CODE:
	{
		GLubyte param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4ubv(param);
	}

void
glColor4ui(red, green, blue, alpha)
	GLuint	red
	GLuint	green
	GLuint	blue
	GLuint	alpha

void
glColor4uiv_s(v)
	SV *	v
	CODE:
	{
		GLuint * v_s = EL(v, sizeof(GLuint)*4);
		glColor4uiv(v_s);
	}

void
glColor4uiv_c(v)
	void *	v
	CODE:
	glColor4uiv(v);

void
glColor4uiv_p(red, green, blue, alpha)
	GLuint	red
	GLuint	green
	GLuint	blue
	GLuint	alpha
	CODE:
	{
		GLuint param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4uiv(param);
	}

void
glColor4us(red, green, blue, alpha)
	GLushort	red
	GLushort	green
	GLushort	blue
	GLushort	alpha

void
glColor4usv_c(v)
	void *	v
	CODE:
	glColor4usv(v);

void
glColor4usv_s(v)
	SV *	v
	CODE:
	{
		GLushort * v_s = EL(v, sizeof(GLushort)*4);
		glColor4usv(v_s);
	}

void
glColor4usv_p(red, green, blue, alpha)
	GLushort	red
	GLushort	green
	GLushort	blue
	GLushort	alpha
	CODE:
	{
		GLushort param[4];
		param[0] = red;
		param[1] = green;
		param[2] = blue;
		param[3] = alpha;
		glColor4usv(param);
	}

void
glTexCoord1d(s)
	GLdouble	s

void
glTexCoord1dv_c(v)
	void *	v
	CODE:
	glTexCoord1dv(v);

void
glTexCoord1dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*1);
		glTexCoord1dv(v_s);
	}

void
glTexCoord1dv_p(s)
	GLdouble	s
	CODE:
	{
		GLdouble param[1];
		param[0] = s;
		glTexCoord1dv(param);
	}

void
glTexCoord1f(s)
	GLfloat	s

void
glTexCoord1fv_c(v)
	void *	v
	CODE:
	glTexCoord1fv(v);

void
glTexCoord1fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*1);
		glTexCoord1fv(v_s);
	}

void
glTexCoord1fv_p(s)
	GLfloat	s
	CODE:
	{
		GLfloat param[1];
		param[0] = s;
		glTexCoord1fv(param);
	}

void
glTexCoord1i(s)
	GLint	s

void
glTexCoord1iv_c(v)
	void *	v
	CODE:
	glTexCoord1iv(v);

void
glTexCoord1iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*1);
		glTexCoord1iv(v_s);
	}

void
glTexCoord1iv_p(s)
	GLint	s
	CODE:
	{
		GLint param[1];
		param[0] = s;
		glTexCoord1iv(param);
	}

void
glTexCoord1s(s)
	GLshort	s

void
glTexCoord1sv_c(v)
	void *	v
	CODE:
	glTexCoord1sv(v);

void
glTexCoord1sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*1);
		glTexCoord1sv(v_s);
	}

void
glTexCoord1sv_p(s)
	GLshort	s
	CODE:
	{
		GLshort param[1];
		param[0] = s;
		glTexCoord1sv(param);
	}

void
glTexCoord2d(s, t)
	GLdouble	s
	GLdouble	t

void
glTexCoord2dv_c(v)
	void *	v
	CODE:
	glTexCoord2dv(v);

void
glTexCoord2dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*2);
		glTexCoord2dv(v_s);
	}

void
glTexCoord2dv_p(s, t)
	GLdouble	s
	GLdouble	t
	CODE:
	{
		GLdouble param[2];
		param[0] = s;
		param[1] = t;
		glTexCoord2dv(param);
	}

void
glTexCoord2f(s, t)
	GLfloat	s
	GLfloat	t

void
glTexCoord2fv_c(v)
	void *	v
	CODE:
	glTexCoord2fv(v);

void
glTexCoord2fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*2);
		glTexCoord2fv(v_s);
	}

void
glTexCoord2fv_p(s, t)
	GLfloat	s
	GLfloat	t
	CODE:
	{
		GLfloat param[2];
		param[0] = s;
		param[1] = t;
		glTexCoord2fv(param);
	}

void
glTexCoord2i(s, t)
	GLint	s
	GLint	t

void
glTexCoord2iv_c(v)
	void *	v
	CODE:
	glTexCoord2iv(v);

void
glTexCoord2iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*2);
		glTexCoord2iv(v_s);
	}

void
glTexCoord2iv_p(s, t)
	GLint	s
	GLint	t
	CODE:
	{
		GLint param[2];
		param[0] = s;
		param[1] = t;
		glTexCoord2iv(param);
	}

void
glTexCoord2s(s, t)
	GLshort	s
	GLshort	t

void
glTexCoord2sv_c(v)
	void *	v
	CODE:
	glTexCoord2sv(v);

void
glTexCoord2sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*2);
		glTexCoord2sv(v_s);
	}

void
glTexCoord2sv_p(s, t)
	GLshort	s
	GLshort	t
	CODE:
	{
		GLshort param[2];
		param[0] = s;
		param[1] = t;
		glTexCoord2sv(param);
	}

void
glTexCoord3d(s, t, r)
	GLdouble	s
	GLdouble	t
	GLdouble	r

void
glTexCoord3dv_c(v)
	void *	v
	CODE:
	glTexCoord3dv(v);

void
glTexCoord3dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*3);
		glTexCoord3dv(v_s);
	}

void
glTexCoord3dv_p(s, t, r)
	GLdouble	s
	GLdouble	t
	GLdouble	r
	CODE:
	{
		GLdouble param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glTexCoord3dv(param);
	}

void
glTexCoord3f(s, t, r)
	GLfloat	s
	GLfloat	t
	GLfloat	r

void
glTexCoord3fv_c(v)
	void *	v
	CODE:
	glTexCoord3fv(v);

void
glTexCoord3fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*3);
		glTexCoord3fv(v_s);
	}

void
glTexCoord3fv_p(s, t, r)
	GLfloat	s
	GLfloat	t
	GLfloat	r
	CODE:
	{
		GLfloat param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glTexCoord3fv(param);
	}

void
glTexCoord3i(s, t, r)
	GLint	s
	GLint	t
	GLint	r

void
glTexCoord3iv_c(v)
	void *	v
	CODE:
	glTexCoord3iv(v);

void
glTexCoord3iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*3);
		glTexCoord3iv(v_s);
	}

void
glTexCoord3iv_p(s, t, r)
	GLint	s
	GLint	t
	GLint	r
	CODE:
	{
		GLint param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glTexCoord3iv(param);
	}

void
glTexCoord3s(s, t, r)
	GLshort	s
	GLshort	t
	GLshort	r

void
glTexCoord3sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*3);
		glTexCoord3sv(v_s);
	}

void
glTexCoord3sv_c(v)
	void *	v
	CODE:
	glTexCoord3sv(v);

void
glTexCoord3sv_p(s, t, r)
	GLshort	s
	GLshort	t
	GLshort	r
	CODE:
	{
		GLshort param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glTexCoord3sv(param);
	}

void
glTexCoord4d(s, t, r, q)
	GLdouble	s
	GLdouble	t
	GLdouble	r
	GLdouble	q

void
glTexCoord4dv_c(v)
	void *	v
	CODE:
	glTexCoord4dv(v);

void
glTexCoord4dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glTexCoord4dv(v_s);
	}

void
glTexCoord4dv_p(s, t, r, q)
	GLdouble	s
	GLdouble	t
	GLdouble	r
	GLdouble	q
	CODE:
	{
		GLdouble param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glTexCoord4dv(param);
	}

void
glTexCoord4f(s, t, r, q)
	GLfloat	s
	GLfloat	t
	GLfloat	r
	GLfloat	q

void
glTexCoord4fv_c(v)
	void *	v
	CODE:
	glTexCoord4fv(v);

void
glTexCoord4fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glTexCoord4fv(v_s);
	}

void
glTexCoord4fv_p(s, t, r, q)
	GLfloat	s
	GLfloat	t
	GLfloat	r
	GLfloat	q
	CODE:
	{
		GLfloat param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glTexCoord4fv(param);
	}

void
glTexCoord4i(s, t, r, q)
	GLint	s
	GLint	t
	GLint	r
	GLint	q

void
glTexCoord4iv_c(v)
	void *	v
	CODE:
	glTexCoord4iv(v);

void
glTexCoord4iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*4);
		glTexCoord4iv(v_s);
	}

void
glTexCoord4iv_p(s, t, r, q)
	GLint	s
	GLint	t
	GLint	r
	GLint	q
	CODE:
	{
		GLint param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glTexCoord4iv(param);
	}

void
glTexCoord4s(s, t, r, q)
	GLshort	s
	GLshort	t
	GLshort	r
	GLshort	q

void
glTexCoord4sv_c(v)
	void *	v
	CODE:
	glTexCoord4sv(v);

void
glTexCoord4sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*4);
		glTexCoord4sv(v_s);
	}

void
glTexCoord4sv_p(s, t, r, q)
	GLshort	s
	GLshort	t
	GLshort	r
	GLshort	q
	CODE:
	{
		GLshort param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glTexCoord4sv(param);
	}

void
glRasterPos2d(x, y)
	GLdouble	x
	GLdouble	y

void
glRasterPos2dv_c(v)
	void *	v
	CODE:
	glRasterPos2dv(v);

void
glRasterPos2dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*2);
		glRasterPos2dv(v_s);
	}

void
glRasterPos2dv_p(x, y)
	GLdouble	x
	GLdouble	y
	CODE:
	{
		GLdouble param[2];
		param[0] = x;
		param[1] = y;
		glRasterPos2dv(param);
	}

void
glRasterPos2f(x, y)
	GLfloat	x
	GLfloat	y

void
glRasterPos2fv_c(v)
	void *	v
	CODE:
	glRasterPos2fv(v);

void
glRasterPos2fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*2);
		glRasterPos2fv(v_s);
	}

void
glRasterPos2fv_p(x, y)
	GLfloat	x
	GLfloat	y
	CODE:
	{
		GLfloat param[2];
		param[0] = x;
		param[1] = y;
		glRasterPos2fv(param);
	}

void
glRasterPos2i(x, y)
	GLint	x
	GLint	y

void
glRasterPos2iv_c(v)
	void *	v
	CODE:
	glRasterPos2iv(v);

void
glRasterPos2iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*2);
		glRasterPos2iv(v_s);
	}

void
glRasterPos2iv_p(x, y)
	GLint	x
	GLint	y
	CODE:
	{
		GLint param[2];
		param[0] = x;
		param[1] = y;
		glRasterPos2iv(param);
	}

void
glRasterPos2s(x, y)
	GLshort	x
	GLshort	y

void
glRasterPos2sv_c(v)
	void *	v
	CODE:
	glRasterPos2sv(v);

void
glRasterPos2sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*2);
		glRasterPos2sv(v_s);
	}

void
glRasterPos2sv_p(x, y)
	GLshort	x
	GLshort	y
	CODE:
	{
		GLshort param[2];
		param[0] = x;
		param[1] = y;
		glRasterPos2sv(param);
	}

void
glRasterPos3d(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z

void
glRasterPos3dv_c(v)
	void *	v
	CODE:
	glRasterPos3dv(v);

void
glRasterPos3dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*3);
		glRasterPos3dv(v_s);
	}

void
glRasterPos3dv_p(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	CODE:
	{
		GLdouble param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glRasterPos3dv(param);
	}

void
glRasterPos3f(x, y, z)
	GLfloat	x
	GLfloat	y
	GLfloat	z

void
glRasterPos3fv_c(v)
	void *	v
	CODE:
	glRasterPos3fv(v);

void
glRasterPos3fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*3);
		glRasterPos3fv(v_s);
	}

void
glRasterPos3fv_p(x, y, z)
	GLfloat	x
	GLfloat	y
	GLfloat	z
	CODE:
	{
		GLfloat param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glRasterPos3fv(param);
	}

void
glRasterPos3i(x, y, z)
	GLint	x
	GLint	y
	GLint	z

void
glRasterPos3iv_c(v)
	void *	v
	CODE:
	glRasterPos3iv(v);

void
glRasterPos3iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*3);
		glRasterPos3iv(v_s);
	}

void
glRasterPos3iv_p(x, y, z)
	GLint	x
	GLint	y
	GLint	z
	CODE:
	{
		GLint param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glRasterPos3iv(param);
	}

void
glRasterPos3s(x, y, z)
	GLshort	x
	GLshort	y
	GLshort	z

void
glRasterPos3sv_c(v)
	void *	v
	CODE:
	glRasterPos3sv(v);

void
glRasterPos3sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*3);
		glRasterPos3sv(v_s);
	}

void
glRasterPos3sv_p(x, y, z)
	GLshort	x
	GLshort	y
	GLshort	z
	CODE:
	{
		GLshort param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glRasterPos3sv(param);
	}

void
glRasterPos4d(x, y, z, w)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w

void
glRasterPos4dv_c(v)
	void *	v
	CODE:
	glRasterPos4dv(v);

void
glRasterPos4dv_s(v)
	SV *	v
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glRasterPos4dv(v_s);
	}

void
glRasterPos4dv_p(x, y, z, w)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w
	CODE:
	{
		GLdouble param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glRasterPos4dv(param);
	}

void
glRasterPos4f(x, y, z, w)
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w

void
glRasterPos4fv_c(v)
	void *	v
	CODE:
	glRasterPos4fv(v);

void
glRasterPos4fv_s(v)
	SV *	v
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glRasterPos4fv(v_s);
	}

void
glRasterPos4fv_p(x, y, z, w)
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w
	CODE:
	{
		GLfloat param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glRasterPos4fv(param);
	}

void
glRasterPos4i(x, y, z, w)
	GLint	x
	GLint	y
	GLint	z
	GLint	w

void
glRasterPos4iv_c(v)
	void *	v
	CODE:
	glRasterPos4iv(v);

void
glRasterPos4iv_s(v)
	SV *	v
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*4);
		glRasterPos4iv(v_s);
	}

void
glRasterPos4iv_p(x, y, z, w)
	GLint	x
	GLint	y
	GLint	z
	GLint	w
	CODE:
	{
		GLint param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glRasterPos4iv(param);
	}

void
glRasterPos4s(x, y, z, w)
	GLshort	x
	GLshort	y
	GLshort	z
	GLshort	w

void
glRasterPos4sv_c(v)
	void *	v
	CODE:
	glRasterPos4sv(v);

void
glRasterPos4sv_s(v)
	SV *	v
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*4);
		glRasterPos4sv(v_s);
	}

void
glRasterPos4sv_p(x, y, z, w)
	GLshort	x
	GLshort	y
	GLshort	z
	GLshort	w
	CODE:
	{
		GLshort param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glRasterPos4sv(param);
	}

# End of generated declarations

################## DEPRECATED EXTENSIONS ########################

#ifdef DEPRECATED
#ifdef GL_EXT_polygon_offset

void
glPolygonOffsetEXT(factor, bias)
	GLfloat	factor
	GLfloat	units

#endif

#ifdef GL_EXT_texture_object

GLboolean
glIsTextureEXT(list)
	GLuint	list

void
glPrioritizeTexturesEXT_p(...)
	CODE:
	{
		GLsizei n = items/2;
		GLuint * textures = malloc(sizeof(GLuint) * (n+1));
		GLclampf * prior = malloc(sizeof(GLclampf) * (n+1));
		int i;
		
		for (i=0;i<n;i++) {
			textures[i] = SvIV(ST(i * 2 + 0));
			prior[i] = SvNV(ST(i * 2 + 1));
		}
		
		glPrioritizeTextures(n, textures, prior);
		
		free(textures);
		free(prior);
	}

void
glBindTextureEXT(target, texture)
	GLenum	target
	GLuint	texture

void
glDeleteTexturesEXT_p(...)
	CODE:
	if (items) {
		GLuint * list = malloc(sizeof(GLuint) * items);
		int i;

		for(i=0;i<items;i++)
			list[i] = SvIV(ST(i));
		
		glDeleteTextures(items, list);
		free(list);
	}

void
glGenTexturesEXT_p(n)
	GLint	n
	PPCODE:
	if (n) {
		GLuint * textures = malloc(sizeof(GLuint) * n);
		int i;
		
		glGenTextures(n, textures);
		
		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(textures[i])));

		free(textures);
	} 

void
glAreTexturesResidentEXT_p(...)
	PPCODE:
	{
		GLsizei n = items;
		GLuint * textures = malloc(sizeof(GLuint) * (n+1));
		GLboolean * residences = malloc(sizeof(GLboolean) * (n+1));
		GLboolean result;
		int i;
		
		for (i=0;i<n;i++)
			textures[i] = SvIV(ST(i));
		
		result = glAreTexturesResident(n, textures, residences);
		
		if (result == GL_TRUE)
			PUSHs(sv_2mortal(newSViv(1)));
		else {
			EXTEND(sp, n+1);
			PUSHs(sv_2mortal(newSViv(0)));
			for(i=0;i<n;i++)
				PUSHs(sv_2mortal(newSViv(residences[i])));
		}
		
		free(textures);
		free(residences);
	}

#endif

#ifdef GL_EXT_copy_texture

void
glCopyTexImage1DEXT(target, level, internalFormat, x, y, width, border)
	GLenum	target
	GLint	level
	GLenum	internalFormat
	GLint	x
	GLint	y
	GLsizei	width
	GLint	border

void
glCopyTexImage2DEXT(target, level, internalFormat, x, y, width, height, border)
	GLenum	target
	GLint	level
	GLenum	internalFormat
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height
	GLint	border

void
glCopyTexSubImage1DEXT(target, level, xoffset, x, y, width)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	x
	GLint	y
	GLsizei	width

void
glCopyTexSubImage2DEXT(target, level, xoffset, yoffset, x, y, width, height)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height

void
glCopyTexSubImage3DEXT(target, level, xoffset, yoffset, zoffset, x, y, width, height)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLint	x
	GLint	y
	GLsizei	width
	GLsizei	height

#endif

#ifdef GL_EXT_subtexture

void
glTexSubImage1DEXT_c(target, level, xoffset, width, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLsizei	width
	GLenum	format
	GLenum	type
	void *	pixels
	INIT:
		loadProc(glTexSubImage1DEXT,"glTexSubImage1DEXT");
	CODE:
	{
		glTexSubImage1DEXT(target, level, xoffset, width, format, type, pixels);
	}

void
glTexSubImage1DEXT_s(target, level, xoffset, width, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLsizei	width
	GLenum	format
	GLenum	type
	SV *	pixels
	INIT:
		loadProc(glTexSubImage1DEXT,"glTexSubImage1DEXT");
	CODE:
	{
		GLvoid * ptr = ELI(pixels, width, height,
			format, type, gl_pixelbuffer_unpack);
		glTexSubImage1DEXT(target, level, xoffset, width, format, type, ptr);
	}

void
glTexSubImage1DEXT_p(target, level, xoffset, width, format, type, ...)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLsizei	width
	GLenum	format
	GLenum	type
	INIT:
		loadProc(glTexSubImage1DEXT,"glTexSubImage1DEXT");
	CODE:
	{
		GLvoid * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		ptr = pack_image_ST(&(ST(4)), items-4, width, height, 1, format, type, 0);
		glTexSubImage1DEXT(target, level, xoffset, width, format, type, ptr);
		glPopClientAttrib();
		free(ptr);
	}

void
glTexSubImage2DEXT_c(target, level, xoffset, yoffset, width, height, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	void *	pixels
	INIT:
		loadProc(glTexSubImage2DEXT,"glTexSubImage2DEXT");
	CODE:
	{
		glTexSubImage2DEXT(target, level, xoffset, yoffset, width, height,
			format, type, pixels);
	}

void
glTexSubImage2DEXT_s(target, level, xoffset, yoffset, width, height, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	SV *	pixels
	INIT:
		loadProc(glTexSubImage2DEXT,"glTexSubImage2DEXT");
	CODE:
	{
		GLvoid * ptr = ELI(pixels, width, height,
			format, type, gl_pixelbuffer_unpack);
		glTexSubImage2DEXT(target, level, xoffset, yoffset, width, height,
			format, type, ptr);
	}

void
glTexSubImage2DEXT_p(target, level, xoffset, yoffset, width, height, format, type, ...)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	INIT:
		loadProc(glTexSubImage2DEXT,"glTexSubImage2DEXT");
	CODE:
	{
		GLvoid * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		ptr = pack_image_ST(&(ST(4)), items-4, width, height, 1, format, type, 0);
		glTexSubImage2DEXT(target, level, xoffset, yoffset, width, height,
			format, type, ptr);
		glPopClientAttrib();
		free(ptr);
	}

#endif
#endif

################## POST 1.1 VERSIONS ########################

#ifdef GL_VERSION_1_2

void
glBlendColor(red, green, blue, alpha)
	GLclampf	red
	GLclampf	green
	GLclampf	blue
	GLclampf	alpha
	INIT:
		loadProc(glBlendColor,"glBlendColor");
	CODE:
		glBlendColor(red, green, blue, alpha);

void
glBlendEquation(mode)
	GLenum	mode
	INIT:
		loadProc(glBlendEquation,"glBlendEquation");
	CODE:
		glBlendEquation(mode);


#endif

################## EXTENSIONS ########################

#ifdef GL_EXT_texture3D

void
glTexImage3DEXT_c(target, level, internalformat, width, height, depth, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLenum	internalformat
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLint	border
	GLenum	format
	GLenum	type
	void *	pixels
	INIT:
		loadProc(glTexImage3DEXT,"glTexImage3DEXT");
	CODE:
	{
		glTexImage3DEXT(target, level, internalformat, width, height,
			depth, border, format, type, pixels);
	}

void
glTexImage3DEXT_s(target, level, internalformat, width, height, depth, border, format, type, pixels)
	GLenum	target
	GLint	level
	GLenum	internalformat
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLint	border
	GLenum	format
	GLenum	type
	SV *	pixels
	INIT:
		loadProc(glTexImage3DEXT,"glTexImage3DEXT");
	CODE:
	{
		GLvoid * ptr = ELI(pixels, width, height,
			format, type, gl_pixelbuffer_unpack);
		glTexImage3DEXT(target, level, internalformat, width, height,
			depth, border, format, type, ptr);
	}

void
glTexImage3DEXT_p(target, level, internalformat, width, height, depth, border, format, type, ...)
	GLenum	target
	GLint	level
	GLenum	internalformat
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLint	border
	GLenum	format
	GLenum	type
	INIT:
		loadProc(glTexImage3DEXT,"glTexImage3DEXT");
	CODE:
	{
		GLvoid * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		ptr = pack_image_ST(&(ST(4)), items-4, width, height, 1, format, type, 0);
		glTexImage3DEXT(target, level, internalformat, width, height,
			depth, border, format, type, ptr);
		glPopClientAttrib();
		free(ptr);
	}

void
glTexSubImage3DEXT_c(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLenum	format
	GLenum	type
	void *	pixels
	INIT:
		loadProc(glTexSubImage3DEXT,"glTexSubImage3DEXT");
	CODE:
	{
		glTexSubImage3DEXT(target, level, xoffset, yoffset, zoffset,
			width, height, depth, format, type, pixels);
	}

void
glTexSubImage3DEXT_s(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLenum	format
	GLenum	type
	SV *	pixels
	INIT:
		loadProc(glTexSubImage3DEXT,"glTexSubImage3DEXT");
	CODE:
	{
		GLvoid * ptr = ELI(pixels, width, height,
			format, type, gl_pixelbuffer_unpack);
		glTexSubImage3DEXT(target, level, xoffset, yoffset, zoffset,
			width, height, depth, format, type, ptr);
	}

void
glTexSubImage3DEXT_p(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, ...)
	GLenum	target
	GLint	level
	GLint	xoffset
	GLint	yoffset
	GLint	zoffset
	GLsizei	width
	GLsizei	height
	GLsizei	depth
	GLenum	format
	GLenum	type
	INIT:
		loadProc(glTexSubImage3DEXT,"glTexSubImage3DEXT");
	CODE:
	{
		GLvoid * ptr;
		glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
		glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
		glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
		ptr = pack_image_ST(&(ST(4)), items-4, width, height, 1, format, type, 0);
		glTexSubImage3DEXT(target, level, xoffset, yoffset, zoffset,
			width, height, depth, format, type, ptr);
		glPopClientAttrib();
		free(ptr);
	}

#endif


# OS/2 PM implementation misses this function
# It is very hard to test for this, so we check for some other omission...

#if defined(GL_EXT_blend_minmax) && (!defined(GL_SRC_ALPHA_SATURATE) || defined(GL_CONSTANT_COLOR))

void
glBlendEquationEXT(mode)
	GLenum	mode
	INIT:
		loadProc(glBlendEquationEXT,"glBlendEquationEXT");
	CODE:
		glBlendEquationEXT(mode);

#endif

#ifdef GL_EXT_blend_color

void
glBlendColorEXT(red, green, blue, alpha)
	GLclampf	red
	GLclampf	green
	GLclampf	blue
	GLclampf	alpha
	INIT:
		loadProc(glBlendColorEXT,"glBlendColorEXT");
	CODE:
		glBlendColorEXT(red, green, blue, alpha);

#endif

#ifdef GL_EXT_vertex_array

void
glArrayElementEXT(i)
	GLint	i
	INIT:
		loadProc(glArrayElementEXT,"glArrayElementEXT");

void
glDrawArraysEXT(mode, first, count)
	GLenum	mode
	GLint	first
	GLsizei	count
	INIT:
		loadProc(glDrawArraysEXT,"glDrawArraysEXT");

void
glVertexPointerEXT_c(size, type, stride, count, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	GLsizei	count
	void *	pointer
	INIT:
		loadProc(glVertexPointerEXT,"glVertexPointerEXT");
	CODE:
		glVertexPointerEXT(size, type, stride, count, pointer);

void
glVertexPointerEXT_s(size, type, stride, count, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	GLsizei	count
	SV *	pointer
	INIT:
		loadProc(glVertexPointerEXT,"glVertexPointerEXT");
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*size);
		void * pointer_s = EL(pointer, width*count);
		glVertexPointerEXT(size, type, stride, count, pointer_s);
	}

void
glVertexPointerEXT_p(size, oga)
	GLint	size
	OpenGL::Array oga
	INIT:
		loadProc(glVertexPointerEXT,"glVertexPointerEXT");
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glVertexPointerEXT(size, oga->types[0], 0, oga->item_count/size,
			oga->bind ? 0 : oga->data);
#else
		glVertexPointerEXT(size, oga->types[0], 0, oga->item_count/size,
			oga->data);
#endif
	}

void
glNormalPointerEXT_c(type, stride, count, pointer)
	GLenum	type
	GLsizei	stride
	GLsizei	count
	void *	pointer
	INIT:
		loadProc(glNormalPointerEXT,"glNormalPointerEXT");
	CODE:
		glNormalPointerEXT(type, stride, count, pointer);

void
glNormalPointerEXT_s(type, stride, count, pointer)
	GLenum	type
	GLsizei	stride
	GLsizei	count
	SV *	pointer
	INIT:
		loadProc(glNormalPointerEXT,"glNormalPointerEXT");
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*3);
		void * pointer_s = EL(pointer, width*count);
		glNormalPointerEXT(type, stride, count, pointer_s);
	}

void
glNormalPointerEXT_p(oga)
	OpenGL::Array oga
	INIT:
		loadProc(glNormalPointerEXT,"glNormalPointerEXT");
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glNormalPointerEXT(oga->types[0], 0, oga->item_count/3,
			oga->bind ? 0 : oga->data);
#else
		glNormalPointerEXT(oga->types[0], 0, oga->item_count/3,
			oga->data);
#endif
	}

void
glColorPointerEXT_c(size, type, stride, count, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	GLsizei	count
	void *	pointer
	INIT:
		loadProc(glColorPointerEXT,"glColorPointerEXT");
	CODE:
		glColorPointerEXT(size, type, stride, count, pointer);

void
glColorPointerEXT_s(size, type, stride, count, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	GLsizei	count
	SV *	pointer
	INIT:
		loadProc(glColorPointerEXT,"glColorPointerEXT");
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*size);
		void * pointer_s = EL(pointer, width*count);
		glColorPointerEXT(size, type, stride, count, pointer_s);
	}

void
glColorPointerEXT_p(size, oga)
	GLint	size
	OpenGL::Array oga
	INIT:
		loadProc(glColorPointerEXT,"glColorPointerEXT");
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glColorPointerEXT(size, oga->types[0], 0, oga->item_count/size,
			oga->bind ? 0 : oga->data);
#else
		glColorPointerEXT(size, oga->types[0], 0, oga->item_count/size,
			oga->data);
#endif
	}

void
glIndexPointerEXT_c(type, stride, count, pointer)
	GLenum	type
	GLsizei	stride
	GLsizei	count
	void *	pointer
	INIT:
		loadProc(glIndexPointerEXT,"glIndexPointerEXT");
	CODE:
		glIndexPointerEXT(type, stride, count, pointer);

void
glIndexPointerEXT_s(type, stride, count, pointer)
	GLenum	type
	GLsizei	stride
	GLsizei	count
	SV *	pointer
	INIT:
		loadProc(glIndexPointerEXT,"glIndexPointerEXT");
	CODE:
	{
		int width = stride ? stride : (sizeof(type));
		void * pointer_s = EL(pointer, width*count);
		glIndexPointerEXT(type, stride, count, pointer_s);
	}

void
glIndexPointerEXT_p(oga)
	OpenGL::Array oga
	INIT:
		loadProc(glIndexPointerEXT,"glIndexPointerEXT");
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glIndexPointerEXT(oga->types[0], 0, oga->item_count,
			oga->bind ? 0 : oga->data);
#else
		glIndexPointerEXT(oga->types[0], 0, oga->item_count,
			oga->data);
#endif
	}

void
glTexCoordPointerEXT_c(size, type, stride, count, pointer)
	GLint	size
	GLenum	type
	GLsizei	count
	GLsizei	stride
	void *	pointer
	INIT:
		loadProc(glTexCoordPointerEXT,"glTexCoordPointerEXT");
	CODE:
		glTexCoordPointerEXT(size, type, stride, count, pointer);

void
glTexCoordPointerEXT_s(size, type, stride, count, pointer)
	GLint	size
	GLenum	type
	GLsizei	stride
	GLsizei	count
	SV *	pointer
	INIT:
		loadProc(glTexCoordPointerEXT,"glTexCoordPointerEXT");
	CODE:
	{
		int width = stride ? stride : (sizeof(type)*size);
		void * pointer_s = EL(pointer, width*count);
		glTexCoordPointerEXT(size, type, stride, count, pointer_s);
	}

void
glTexCoordPointerEXT_p(size, oga)
	GLint	size
	OpenGL::Array oga
	INIT:
		loadProc(glTexCoordPointerEXT,"glTexCoordPointerEXT");
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glTexCoordPointerEXT(size, oga->types[0], 0, oga->item_count/size,
			oga->bind ? 0 : oga->data);
#else
		glTexCoordPointerEXT(size, oga->types[0], 0, oga->item_count/size,
			oga->data);
#endif
	}

void
glEdgeFlagPointerEXT_c(stride, count, pointer)
	GLint	stride
	GLsizei	count
	void *	pointer
	INIT:
		loadProc(glEdgeFlagPointerEXT,"glEdgeFlagPointerEXT");
	CODE:
		glEdgeFlagPointerEXT(stride, count, pointer);

void
glEdgeFlagPointerEXT_s(stride, count, pointer)
	GLsizei	stride
	GLsizei	count
	SV *	pointer
	INIT:
		loadProc(glEdgeFlagPointerEXT,"glEdgeFlagPointerEXT");
	CODE:
	{
		int width = stride ? stride : (sizeof(GLboolean));
		void * pointer_s = EL(pointer, width*count);
		glEdgeFlagPointerEXT(stride, count, pointer_s);
	}

void
glEdgeFlagPointerEXT_p(oga)
	OpenGL::Array oga
	INIT:
		loadProc(glEdgeFlagPointerEXT,"glEdgeFlagPointerEXT");
	CODE:
	{
#ifdef GL_ARB_vertex_buffer_object
		if (testProc(glBindBufferARB,"glBindBufferARB"))
		{
			glBindBufferARB(GL_ARRAY_BUFFER_ARB, oga->bind);
		}
		glEdgeFlagPointerEXT(0, oga->item_count, oga->bind ? 0 : oga->data);
#else
		glEdgeFlagPointerEXT(0, oga->item_count, oga->data);
#endif
	}

#endif


#ifdef GL_MESA_window_pos

void
glWindowPos2iMESA(x, y)
	GLint	x
	GLint	y

void
glWindowPos2dMESA(x, y)
	GLdouble	x
	GLdouble	y

void
glWindowPos3iMESA(x, y, z)
	GLint	x
	GLint	y
	GLint	z

void
glWindowPos3dMESA(x, y, z)
	GLdouble	x
	GLdouble	y
	GLdouble	z

void
glWindowPos4iMESA(x, y, z, w)
	GLint	x
	GLint	y
	GLint	z
	GLint	w

void
glWindowPos4dMESA(x, y, z, w)
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w

#endif

#ifdef GL_MESA_resize_buffers

void
glResizeBuffersMESA()

#endif

#ifdef GL_ARB_draw_buffers

void
glDrawBuffersARB_c(n,buffers)
	GLsizei n
	void *	buffers
	INIT:
		loadProc(glDrawBuffersARB,"glDrawBuffersARB");
	CODE:
	{
		glDrawBuffersARB(n,buffers);
	}

void
glDrawBuffersARB_s(n,buffers)
	GLsizei n
	SV *	buffers
	INIT:
		loadProc(glDrawBuffersARB,"glDrawBuffersARB");
	CODE:
	{
		void * buffers_s = EL(buffers, sizeof(GLuint)*n);
		glDrawBuffersARB(n,buffers_s);
	}

void
glDrawBuffersARB_p(...)
	INIT:
		loadProc(glDrawBuffersARB,"glDrawBuffersARB");
	CODE:
	{
		if (items)
		{
			GLuint * list = malloc(sizeof(GLuint) * items);
			int i;
			for (i=0;i<items;i++)
				list[i] = SvIV(ST(i));
			glDrawBuffersARB(items, list);
			free(list);
		}
	}

#endif
#ifdef GL_VERSION_2_0

void
glDrawBuffers_c(n,buffers)
	GLsizei n
	void *	buffers
	CODE:
	{
		glDrawBuffers(n,buffers);
	}

void
glDrawBuffers_s(n,buffers)
	GLsizei n
	SV *	buffers
	CODE:
	{
		void * buffers_s = EL(buffers, sizeof(GLuint)*n);
		glDrawBuffers(n,buffers_s);
	}

void
glDrawBuffers_p(...)
	CODE:
	{
		if (items) {
			GLuint * list = malloc(sizeof(GLuint) * items);
			int i;

			for (i=0;i<items;i++)
				list[i] = SvIV(ST(i));

			glDrawBuffers(items, list);
			free(list);
		}
	}

#endif

#ifdef GL_EXT_framebuffer_object

GLboolean
glIsRenderbufferEXT(renderbuffer)
	GLuint	renderbuffer
	INIT:
		loadProc(glIsRenderbufferEXT,"glIsRenderbufferEXT");
	CODE:
	{
		RETVAL = glIsRenderbufferEXT(renderbuffer);
	}
	OUTPUT:
		RETVAL

void
glBindRenderbufferEXT(target,renderbuffer)
	GLenum target
	GLuint renderbuffer
	INIT:
		loadProc(glBindRenderbufferEXT,"glBindRenderbufferEXT");
	CODE:
	{
		glBindRenderbufferEXT(target,renderbuffer);
	}

void
glDeleteRenderbuffersEXT_c(n,renderbuffers)
	GLsizei n
	void *	renderbuffers
	INIT:
		loadProc(glDeleteRenderbuffersEXT,"glDeleteRenderbuffersEXT");
	CODE:
	{
		glDeleteRenderbuffersEXT(n,renderbuffers);
	}

void
glDeleteRenderbuffersEXT_s(n,renderbuffers)
	GLsizei n
	SV *	renderbuffers
	INIT:
		loadProc(glDeleteRenderbuffersEXT,"glDeleteRenderbuffersEXT");
	CODE:
	{
		void * renderbuffers_s = EL(renderbuffers, sizeof(GLuint)*n);
		glDeleteRenderbuffersEXT(n,renderbuffers_s);
	}

void
glDeleteRenderbuffersEXT_p(...)
	INIT:
		loadProc(glDeleteRenderbuffersEXT,"glDeleteRenderbuffersEXT");
	CODE:
	{
		if (items) {
			GLuint * list = malloc(sizeof(GLuint) * items);
			int i;

			for (i=0;i<items;i++)
				list[i] = SvIV(ST(i));

			glDeleteRenderbuffersEXT(items, list);
			free(list);
		}
	}

void
glGenRenderbuffersEXT_c(n,renderbuffers)
	GLsizei n
	void *	renderbuffers
	INIT:
		loadProc(glGenRenderbuffersEXT,"glGenRenderbuffersEXT");
	CODE:
	{
		glGenRenderbuffersEXT(n, renderbuffers);
	}

void
glGenRenderbuffersEXT_s(n,renderbuffers)
	GLsizei n
	SV *	renderbuffers
	INIT:
		loadProc(glGenRenderbuffersEXT,"glGenRenderbuffersEXT");
	CODE:
	{
		void * renderbuffers_s = EL(renderbuffers, sizeof(GLuint)*n);
		glGenRenderbuffersEXT(n, renderbuffers_s);
	}

void
glGenRenderbuffersEXT_p(n)
	GLsizei n
	INIT:
		loadProc(glGenRenderbuffersEXT,"glGenRenderbuffersEXT");
	PPCODE:
	if (n)
	{
		GLuint * renderbuffers = malloc(sizeof(GLuint) * n);
		int i;

		glGenRenderbuffersEXT(n, renderbuffers);

		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(renderbuffers[i])));

		free(renderbuffers);
	} 

void
glRenderbufferStorageEXT(target,internalformat,width,height)
	GLenum	target
	GLenum	internalformat
	GLsizei	width
	GLsizei	height
	INIT:
		loadProc(glRenderbufferStorageEXT,"glRenderbufferStorageEXT");
	CODE:
	{
		glRenderbufferStorageEXT(target,internalformat,width,height);
	}

void
glGetRenderbufferParameterivEXT_s(target,pname,params)
	GLenum	target
	GLenum	pname
        SV *	params
	INIT:
		loadProc(glGetRenderbufferParameterivEXT,"glGetRenderbufferParameterivEXT");
	CODE:
	{
		GLint * params_s = EL(params, sizeof(GLint));
		glGetRenderbufferParameterivEXT(target,pname,params_s);
        }

void
glGetRenderbufferParameterivEXT_c(target,pname,params)
	GLenum	target
	GLenum	pname
        void *	params
	INIT:
		loadProc(glGetRenderbufferParameterivEXT,"glGetRenderbufferParameterivEXT");
	CODE:
	{
		glGetRenderbufferParameterivEXT(target,pname,params);
        }

GLboolean
glIsFramebufferEXT(framebuffer)
	GLuint framebuffer
	INIT:
		loadProc(glIsFramebufferEXT,"glIsFramebufferEXT");
	CODE:
	{
		RETVAL = glIsFramebufferEXT(framebuffer);
        }
	OUTPUT:
		RETVAL

void
glBindFramebufferEXT(target,framebuffer)
	GLenum target
	GLuint framebuffer
	INIT:
		loadProc(glBindFramebufferEXT,"glBindFramebufferEXT");
	CODE:
	{
		glBindFramebufferEXT(target,framebuffer);
        }

void
glDeleteFramebuffersEXT_c(n,framebuffers)
	GLsizei n
	void *	framebuffers
	INIT:
		loadProc(glDeleteFramebuffersEXT,"glDeleteFramebuffersEXT");
	CODE:
	{
		glDeleteFramebuffersEXT(n,framebuffers);
	}

void
glDeleteFramebuffersEXT_s(n,framebuffers)
	GLsizei n
	SV *	framebuffers
	INIT:
		loadProc(glDeleteFramebuffersEXT,"glDeleteFramebuffersEXT");
	CODE:
	{
		void * framebuffers_s = EL(framebuffers, sizeof(GLuint)*n);
		glDeleteFramebuffersEXT(n,framebuffers_s);
	}

void
glDeleteFramebuffersEXT_p(...)
	INIT:
		loadProc(glDeleteFramebuffersEXT,"glDeleteFramebuffersEXT");
	CODE:
	{
		if (items) {
			GLuint * list = malloc(sizeof(GLuint) * items);
			int i;

			for(i=0;i<items;i++)
				list[i] = SvIV(ST(i));
		
			glDeleteFramebuffersEXT(items, list);
			free(list);
		}
	}

void
glGenFramebuffersEXT_c(n,framebuffers)
	GLsizei n
	void *	framebuffers
	INIT:
		loadProc(glGenFramebuffersEXT,"glGenFramebuffersEXT");
	CODE:
	{
		glGenFramebuffersEXT(n,framebuffers);
	}

void
glGenFramebuffersEXT_s(n,framebuffers)
	GLsizei n
	SV *	framebuffers
	INIT:
		loadProc(glGenFramebuffersEXT,"glGenFramebuffersEXT");
	CODE:
	{
		void * framebuffers_s = EL(framebuffers, sizeof(GLuint)*n);
		glGenFramebuffersEXT(n,framebuffers_s);
	}

void
glGenFramebuffersEXT_p(n)
	GLsizei n
	INIT:
		loadProc(glGenFramebuffersEXT,"glGenFramebuffersEXT");
	PPCODE:
	if (n)
	{
		GLuint * framebuffers = malloc(sizeof(GLuint) * n);
		int i;
		
		glGenFramebuffersEXT(n, framebuffers);

		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(framebuffers[i])));

		free(framebuffers);
	} 

GLenum
glCheckFramebufferStatusEXT(target)
	GLenum target
	INIT:
		loadProc(glCheckFramebufferStatusEXT,"glCheckFramebufferStatusEXT");
	CODE:
	{
		RETVAL = glCheckFramebufferStatusEXT(target);
	}
	OUTPUT:
		RETVAL

void
glFramebufferTexture1DEXT(target,attachment,textarget,texture,level)
	GLenum target
	GLenum attachment
	GLenum textarget
	GLuint texture
	GLint level
	INIT:
		loadProc(glFramebufferTexture1DEXT,"glFramebufferTexture1DEXT");
	CODE:
	{
		glFramebufferTexture1DEXT(target,attachment,textarget,texture,level);
	}

void
glFramebufferTexture2DEXT(target,attachment,textarget,texture,level)
	GLenum target
	GLenum attachment
	GLenum textarget
	GLuint texture
	GLint level
	INIT:
		loadProc(glFramebufferTexture2DEXT,"glFramebufferTexture2DEXT");
	CODE:
	{
		glFramebufferTexture2DEXT(target,attachment,textarget,texture,level);
	}

void
glFramebufferTexture3DEXT(target,attachment,textarget,texture,level,zoffset)
	GLenum target
	GLenum attachment
	GLenum textarget
	GLuint texture
	GLint level
	GLint zoffset
	INIT:
		loadProc(glFramebufferTexture3DEXT,"glFramebufferTexture3DEXT");
	CODE:
	{
		glFramebufferTexture3DEXT(target,attachment,textarget,texture,level,zoffset);
	}

void
glFramebufferRenderbufferEXT(target,attachment,renderbuffertarget,renderbuffer)
	GLenum target
	GLenum attachment
	GLenum renderbuffertarget
	GLuint renderbuffer
	INIT:
		loadProc(glFramebufferRenderbufferEXT,"glFramebufferRenderbufferEXT");
	CODE:
	{
		glFramebufferRenderbufferEXT(target,attachment,renderbuffertarget,renderbuffer);
	}

void
glGetFramebufferAttachmentParameterivEXT_s(target,attachment,pname,params)
	GLenum	target
	GLenum	attachment
	GLenum	pname
        SV *	params
	INIT:
		loadProc(glGetFramebufferAttachmentParameterivEXT,"glGetFramebufferAttachmentParameterivEXT");
	CODE:
	{
		GLint * params_s = EL(params, sizeof(GLint));
		glGetFramebufferAttachmentParameterivEXT(target,attachment,pname,params_s);
        }

void
glGetFramebufferAttachmentParameterivEXT_c(target,attachment,pname,params)
	GLenum	target
	GLenum	attachment
	GLenum	pname
        void *	params
	INIT:
		loadProc(glGetFramebufferAttachmentParameterivEXT,"glGetFramebufferAttachmentParameterivEXT");
	CODE:
	{
		glGetFramebufferAttachmentParameterivEXT(target,attachment,pname,params);
        }

void
glGenerateMipmapEXT(target)
	GLenum target
	INIT:
		loadProc(glGenerateMipmapEXT,"glGenerateMipmapEXT");
	CODE:
	{
		glGenerateMipmapEXT(target);
        }

#endif


#ifdef GL_ARB_vertex_buffer_object

void
glBindBufferARB(target,buffer)
	GLenum target
	GLuint buffer
	INIT:
		loadProc(glBindBufferARB,"glBindBufferARB");
	CODE:
	{
		glBindBufferARB(target,buffer);
	}

void
glDeleteBuffersARB_c(n,buffers)
	GLsizei	n
	void *	buffers
	INIT:
		loadProc(glDeleteBuffersARB,"glDeleteBuffersARB");
	CODE:
	{
		glDeleteBuffersARB(n,buffers);
	}

void
glDeleteBuffersARB_s(n,buffers)
	GLsizei n
	SV *	buffers
	INIT:
		loadProc(glDeleteBuffersARB,"glDeleteBuffersARB");
	CODE:
	{
		void * buffers_s = EL(buffers, sizeof(GLuint)*n);
		glDeleteBuffersARB(n,buffers_s);
	}

void
glDeleteBuffersARB_p(...)
	INIT:
		loadProc(glDeleteBuffersARB,"glDeleteBuffersARB");
	CODE:
	{
		if (items) {
			GLuint * list = malloc(sizeof(GLuint) * items);
			int i;

			for (i=0;i<items;i++)
				list[i] = SvIV(ST(i));

			glDeleteBuffersARB(items, list);
			free(list);
		}
	}

void
glGenBuffersARB_c(n,buffers)
	GLsizei n
	void *	buffers
	INIT:
		loadProc(glGenBuffersARB,"glGenBuffersARB");
	CODE:
	{
		glGenBuffersARB(n, buffers);
	}

void
glGenBuffersARB_s(n,buffers)
	GLsizei n
	SV *	buffers
	INIT:
		loadProc(glGenBuffersARB,"glGenBuffersARB");
	CODE:
	{
		void * buffers_s = EL(buffers, sizeof(GLuint)*n);
		glGenBuffersARB(n, buffers_s);
	}

void
glGenBuffersARB_p(n)
	GLsizei n
	INIT:
		loadProc(glGenBuffersARB,"glGenBuffersARB");
	PPCODE:
	if (n)
	{
		GLuint * buffers = malloc(sizeof(GLuint) * n);
		int i;

		glGenBuffersARB(n, buffers);

		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(buffers[i])));

		free(buffers);
	} 

GLboolean
glIsBufferARB(buffer)
	GLuint buffer
	INIT:
		loadProc(glIsBufferARB,"glIsBufferARB");
	CODE:
	{
		RETVAL = glIsBufferARB(buffer);
        }
	OUTPUT:
		RETVAL

void
glBufferDataARB_c(target,size,data,usage)
	GLenum	target
	GLsizei	size
	void *	data
	GLenum	usage
	INIT:
		loadProc(glBufferDataARB,"glBufferDataARB");
	CODE:
	{
		glBufferDataARB(target,size,data,usage);
	}

void
glBufferDataARB_s(target,size,data,usage)
	GLenum	target
	GLsizei	size
	SV *	data
	GLenum	usage
	INIT:
		loadProc(glBufferDataARB,"glBufferDataARB");
	CODE:
	{
		void * data_s = EL(data, size);
		glBufferDataARB(target,size,data_s,usage);
	}

void
glBufferDataARB_p(target,oga,usage)
	GLenum target
	OpenGL::Array oga
	GLenum usage
	INIT:
		loadProc(glBufferDataARB,"glBufferDataARB");
	CODE:
	{
		glBufferDataARB(target,oga->data_length,oga->data,usage);
	}

void
glBufferSubDataARB_c(target,offset,size,data)
	GLenum	target
	GLint	offset
	GLsizei	size
	void *	data
	INIT:
		loadProc(glBufferSubDataARB,"glBufferSubDataARB");
	CODE:
	{
		glBufferSubDataARB(target,offset,size,data);
	}

void
glBufferSubDataARB_s(target,offset,size,data)
	GLenum	target
	GLint	offset
	GLsizei	size
	SV *	data
	INIT:
		loadProc(glBufferSubDataARB,"glBufferSubDataARB");
	CODE:
	{
		void * data_s = EL(data, size);
		glBufferSubDataARB(target,offset,size,data);
	}

void
glBufferSubDataARB_p(target,offset,oga)
	GLenum	target
	GLint	offset
	OpenGL::Array oga
	INIT:
		loadProc(glBufferSubDataARB,"glBufferSubDataARB");
	CODE:
	{
		glBufferSubDataARB(target,offset*oga->total_types_width,oga->data_length,oga->data);
	}

void
glGetBufferSubDataARB_c(target,offset,size,data)
	GLenum	target
	GLint	offset
	GLsizei	size
	void *	data
	INIT:
		loadProc(glGetBufferSubDataARB,"glBufferSubDataARB");
	CODE:
		glGetBufferSubDataARB(target,offset,size,data);

void
glGetBufferSubDataARB_s(target,offset,size,data)
	GLenum	target
	GLint	offset
	GLsizei	size
	SV *	data
	INIT:
		loadProc(glGetBufferSubDataARB,"glBufferSubDataARB");
	CODE:
	{
		GLubyte * data_s = EL(data,size);
		glGetBufferSubDataARB(target,offset,size,data_s);
	}

OpenGL::Array
glGetBufferSubDataARB_p(target,offset,count,...)
	GLenum	target
	GLint	offset
	GLsizei	count
	INIT:
		loadProc(glGetBufferSubDataARB,"glGetBufferSubDataARB");
		loadProc(glGetBufferParameterivARB,"glGetBufferParameterivARB");
	CODE:
	{
		oga_struct * oga = malloc(sizeof(oga_struct));
		GLsizeiptrARB size;
		
		oga->item_count = count;
		oga->type_count = (items - 3);

                if (oga->type_count)
		{
			int i,j;

			oga->types = malloc(sizeof(GLenum) * oga->type_count);
			oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
			for(i=0,j=0;i<oga->type_count;i++) {
				oga->types[i] = SvIV(ST(i+3));
				oga->type_offset[i] = j;
				j += gl_type_size(oga->types[i]);
			}
			oga->total_types_width = j;
		}
		else
		{
			oga->type_count = 1;
			oga->types = malloc(sizeof(GLenum) * oga->type_count);
			oga->type_offset = malloc(sizeof(GLint) * oga->type_count);

			oga->types[0] = GL_UNSIGNED_BYTE;
			oga->type_offset[0] = 0;
			oga->total_types_width = gl_type_size(oga->types[0]);
		}
		if (!oga->total_types_width) croak("Unable to determine type sizes\n");

		glGetBufferParameterivARB(target,GL_BUFFER_SIZE_ARB,(GLint*)&size);
		size /= oga->total_types_width;
		if (offset > size) croak("Offset is greater than elements in buffer: %d\n",size);

		if ((offset+count) > size) count = size - offset;
		
		oga->data_length = oga->total_types_width * count;
		oga->data = malloc(oga->data_length);

		glGetBufferSubDataARB(target,offset*oga->total_types_width,
			oga->data_length,oga->data);

		oga->free_data = 1;
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

void *
glMapBufferARB_c(target,access)
	GLenum	target
	GLenum	access
	INIT:
		loadProc(glMapBufferARB,"glMapBufferARB");
	CODE:
		RETVAL = glMapBufferARB(target,access);
	OUTPUT:
		RETVAL

#define FIXME /* !!! Need to refactor with glGetBufferPointervARB_p */

OpenGL::Array
glMapBufferARB_p(target,access,...)
	GLenum	target
	GLenum	access
	INIT:
		loadProc(glMapBufferARB,"glMapBufferARB");
		loadProc(glGetBufferParameterivARB,"glGetBufferParameterivARB");
	CODE:
	{
		GLsizeiptrARB size;
		oga_struct * oga;
		int i,j;

		void * buffer =	glMapBufferARB(target,access);
		if (!buffer) croak("Unable to map buffer\n");

		glGetBufferParameterivARB(target,GL_BUFFER_SIZE_ARB,(GLint*)&size);
		if (!size) croak("Buffer has no size\n");

		oga = malloc(sizeof(oga_struct));

		oga->type_count = (items - 2);

                if (oga->type_count)
		{
			oga->types = malloc(sizeof(GLenum) * oga->type_count);
			oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
			for(i=0,j=0;i<oga->type_count;i++) {
				oga->types[i] = SvIV(ST(i+2));
				oga->type_offset[i] = j;
				j += gl_type_size(oga->types[i]);
			}
			oga->total_types_width = j;
		}
		else
		{
			oga->type_count = 1;
			oga->types = malloc(sizeof(GLenum) * oga->type_count);
			oga->type_offset = malloc(sizeof(GLint) * oga->type_count);

			oga->types[0] = GL_UNSIGNED_BYTE;
			oga->type_offset[0] = 0;
			oga->total_types_width = gl_type_size(oga->types[0]);
		}

		if (!oga->total_types_width) croak("Unable to determine type sizes\n");
		oga->item_count = size / oga->total_types_width;

		oga->data_length = oga->total_types_width * oga->item_count;
		
		oga->data = buffer;

		oga->free_data = 0;
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL

GLboolean
glUnmapBufferARB(target)
	GLenum	target
	INIT:
		loadProc(glUnmapBufferARB,"glUnmapBufferARB");
	CODE:
		RETVAL = glUnmapBufferARB(target);
	OUTPUT:
		RETVAL

void
glGetBufferParameterivARB_c(target,pname,params)
	GLenum	target
	GLenum	pname
	void *	params
	INIT:
		loadProc(glGetBufferParameterivARB,"glGetBufferParameterivARB");
	CODE:
		glGetBufferParameterivARB(target,pname,params);

void
glGetBufferParameterivARB_s(target,pname,params)
	GLenum	target
	GLenum	pname
	SV *	params
	INIT:
		loadProc(glGetBufferParameterivARB,"glGetBufferParameterivARB");
	CODE:
	{
		GLint * params_s = EL(params, sizeof(GLint)*1);
		glGetBufferParameterivARB(target,pname,params_s);
	}

void
glGetBufferParameterivARB_p(target,pname)
	GLenum	target
	GLenum	pname
	INIT:
		loadProc(glGetBufferParameterivARB,"glGetBufferParameterivARB");
	PPCODE:
	{
		GLint	ret;
		glGetBufferParameterivARB(target,pname,&ret);
		PUSHs(sv_2mortal(newSViv(ret)));
	}

void
glGetBufferPointervARB_c(target,pname,params)
	GLenum	target
	GLenum	pname
	void *	params
	INIT:
		loadProc(glGetBufferPointervARB,"glGetBufferPointervARB");
	CODE:
		glGetBufferPointervARB(target,pname,&params);

void
glGetBufferPointervARB_s(target,pname,params)
	GLenum	target
	GLenum	pname
	SV *	params
	INIT:
		loadProc(glGetBufferPointervARB,"glGetBufferPointervARB");
	CODE:
	{
		void ** params_s = EL(params, sizeof(void*));
		glGetBufferPointervARB(target,pname,params_s);
	}

OpenGL::Array
glGetBufferPointervARB_p(target,pname,...)
	GLenum	target
	GLenum	pname
	INIT:
		loadProc(glGetBufferPointervARB,"glGetBufferPointervARB");
		loadProc(glGetBufferParameterivARB,"glGetBufferParameterivARB");
	CODE:
	{
		GLsizeiptrARB size;
		oga_struct * oga;
		void * buffer;
		int i,j;

		glGetBufferPointervARB(target,pname,&buffer);
		if (!buffer) croak("Buffer is not mapped\n");

		glGetBufferParameterivARB(target,GL_BUFFER_SIZE_ARB,(GLint*)&size);
		if (!size) croak("Buffer has no size\n");

		oga = malloc(sizeof(oga_struct));

		oga->type_count = (items - 2);

                if (oga->type_count)
		{
			oga->types = malloc(sizeof(GLenum) * oga->type_count);
			oga->type_offset = malloc(sizeof(GLint) * oga->type_count);
			for(i=0,j=0;i<oga->type_count;i++) {
				oga->types[i] = SvIV(ST(i+2));
				oga->type_offset[i] = j;
				j += gl_type_size(oga->types[i]);
			}
			oga->total_types_width = j;
		}
		else
		{
			oga->type_count = 1;
			oga->types = malloc(sizeof(GLenum) * oga->type_count);
			oga->type_offset = malloc(sizeof(GLint) * oga->type_count);

			oga->types[0] = GL_UNSIGNED_BYTE;
			oga->type_offset[0] = 0;
			oga->total_types_width = gl_type_size(oga->types[0]);
		}

		if (!oga->total_types_width) croak("Unable to determine type sizes\n");
		oga->item_count = size / oga->total_types_width;
		
		oga->data_length = oga->total_types_width * oga->item_count;
		
		oga->data = buffer;

		oga->free_data = 0;
		
		RETVAL = oga;
	}
	OUTPUT:
		RETVAL


#endif


#ifdef GL_ARB_multitexture

void
glActiveTextureARB(texture)
	GLenum texture
	INIT:
		loadProc(glActiveTextureARB,"glActiveTextureARB");
	CODE:
		glActiveTextureARB(texture);

void
glClientActiveTextureARB(texture)
	GLenum texture
	INIT:
		loadProc(glClientActiveTextureARB,"glClientActiveTextureARB");
	CODE:
		glClientActiveTextureARB(texture);

void
glMultiTexCoord1dARB(target,s)
	GLenum target
	GLdouble s
	INIT:
		loadProc(glMultiTexCoord1dARB,"glMultiTexCoord1dARB");
	CODE:
		glMultiTexCoord1dARB(target,s);

void
glMultiTexCoord1dvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1dvARB,"glMultiTexCoord1dvARB");
	CODE:
		glMultiTexCoord1dvARB(target,v);

void
glMultiTexCoord1dvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1dvARB,"glMultiTexCoord1dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble));
		glMultiTexCoord1dvARB(target,v_s);
	}

void
glMultiTexCoord1dvARB_p(target,s)
	GLenum target
	GLdouble s
	INIT:
		loadProc(glMultiTexCoord1dvARB,"glMultiTexCoord1dvARB");
	CODE:
	{
		glMultiTexCoord1dvARB(target,&s);
	}

void
glMultiTexCoord1fARB(target,s)
	GLenum target
	GLfloat s
	INIT:
		loadProc(glMultiTexCoord1fARB,"glMultiTexCoord1fARB");
	CODE:
		glMultiTexCoord1fARB(target,s);

void
glMultiTexCoord1fvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1fvARB,"glMultiTexCoord1fvARB");
	CODE:
		glMultiTexCoord1fvARB(target,v);

void
glMultiTexCoord1fvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1fvARB,"glMultiTexCoord1fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat));
		glMultiTexCoord1fvARB(target,v_s);
	}

void
glMultiTexCoord1fvARB_p(target,s)
	GLenum target
	GLfloat s
	INIT:
		loadProc(glMultiTexCoord1fvARB,"glMultiTexCoord1fvARB");
	CODE:
	{
		glMultiTexCoord1fvARB(target,&s);
	}

void
glMultiTexCoord1iARB(target,s)
	GLenum target
	GLint s
	INIT:
		loadProc(glMultiTexCoord1iARB,"glMultiTexCoord1iARB");
	CODE:
		glMultiTexCoord1iARB(target,s);

void
glMultiTexCoord1ivARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1ivARB,"glMultiTexCoord1ivARB");
	CODE:
		glMultiTexCoord1ivARB(target,v);

void
glMultiTexCoord1ivARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1ivARB,"glMultiTexCoord1ivARB");
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint));
		glMultiTexCoord1ivARB(target,v_s);
	}

void
glMultiTexCoord1ivARB_p(target,s)
	GLenum target
	GLint s
	INIT:
		loadProc(glMultiTexCoord1ivARB,"glMultiTexCoord1ivARB");
	CODE:
	{
		glMultiTexCoord1ivARB(target,&s);
	}

void
glMultiTexCoord1sARB(target,s)
	GLenum target
	GLshort s
	INIT:
		loadProc(glMultiTexCoord1sARB,"glMultiTexCoord1sARB");
	CODE:
		glMultiTexCoord1sARB(target,s);

void
glMultiTexCoord1svARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1svARB,"glMultiTexCoord1svARB");
	CODE:
		glMultiTexCoord1svARB(target,v);

void
glMultiTexCoord1svARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord1svARB,"glMultiTexCoord1svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort));
		glMultiTexCoord1svARB(target,v_s);
	}

void
glMultiTexCoord1svARB_p(target,s)
	GLenum target
	GLshort s
	INIT:
		loadProc(glMultiTexCoord1svARB,"glMultiTexCoord1svARB");
	CODE:
	{
		glMultiTexCoord1svARB(target,&s);
	}

void
glMultiTexCoord2dARB(target,s,t)
	GLenum target
	GLdouble s
	GLdouble t
	INIT:
		loadProc(glMultiTexCoord2dARB,"glMultiTexCoord2dARB");
	CODE:
		glMultiTexCoord2dARB(target,s,t);

void
glMultiTexCoord2dvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2dvARB,"glMultiTexCoord2dvARB");
	CODE:
		glMultiTexCoord2dvARB(target,v);

void
glMultiTexCoord2dvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2dvARB,"glMultiTexCoord2dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble));
		glMultiTexCoord2dvARB(target,v_s);
	}

void
glMultiTexCoord2dvARB_p(target,s,t)
	GLenum target
	GLdouble s
	GLdouble t
	INIT:
		loadProc(glMultiTexCoord2dvARB,"glMultiTexCoord2dvARB");
	CODE:
	{
		GLdouble param[2];
		param[0] = s;
		param[1] = t;
		glMultiTexCoord2dvARB(target,param);
	}

void
glMultiTexCoord2fARB(target,s,t)
	GLenum target
	GLfloat s
	GLfloat t
	INIT:
		loadProc(glMultiTexCoord2fARB,"glMultiTexCoord2fARB");
	CODE:
		glMultiTexCoord2fARB(target,s,t);

void
glMultiTexCoord2fvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2fvARB,"glMultiTexCoord2fvARB");
	CODE:
		glMultiTexCoord2fvARB(target,v);

void
glMultiTexCoord2fvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2fvARB,"glMultiTexCoord2fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat));
		glMultiTexCoord2fvARB(target,v_s);
	}

void
glMultiTexCoord2fvARB_p(target,s,t)
	GLenum target
	GLfloat s
	GLfloat t
	INIT:
		loadProc(glMultiTexCoord2fvARB,"glMultiTexCoord2fvARB");
	CODE:
	{
		GLfloat param[2];
		param[0] = s;
		param[1] = t;
		glMultiTexCoord2fvARB(target,param);
	}

void
glMultiTexCoord2iARB(target,s,t)
	GLenum target
	GLint s
	GLint t
	INIT:
		loadProc(glMultiTexCoord2iARB,"glMultiTexCoord2iARB");
	CODE:
		glMultiTexCoord2iARB(target,s,t);

void
glMultiTexCoord2ivARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2ivARB,"glMultiTexCoord2ivARB");
	CODE:
		glMultiTexCoord2ivARB(target,v);

void
glMultiTexCoord2ivARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2ivARB,"glMultiTexCoord2ivARB");
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint));
		glMultiTexCoord2ivARB(target,v_s);
	}

void
glMultiTexCoord2ivARB_p(target,s,t)
	GLenum target
	GLint s
	GLint t
	INIT:
		loadProc(glMultiTexCoord2ivARB,"glMultiTexCoord2ivARB");
	CODE:
	{
		GLint param[2];
		param[0] = s;
		param[1] = t;
		glMultiTexCoord2ivARB(target,param);
	}

void
glMultiTexCoord2sARB(target,s,t)
	GLenum target
	GLshort s
	GLshort t
	INIT:
		loadProc(glMultiTexCoord2sARB,"glMultiTexCoord2sARB");
	CODE:
		glMultiTexCoord2sARB(target,s,t);

void
glMultiTexCoord2svARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2svARB,"glMultiTexCoord2svARB");
	CODE:
		glMultiTexCoord2svARB(target,v);

void
glMultiTexCoord2svARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord2svARB,"glMultiTexCoord2svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort));
		glMultiTexCoord2svARB(target,v_s);
	}

void
glMultiTexCoord2svARB_p(target,s,t)
	GLenum target
	GLshort s
	GLshort t
	INIT:
		loadProc(glMultiTexCoord2svARB,"glMultiTexCoord2svARB");
	CODE:
	{
		GLshort param[2];
		param[0] = s;
		param[1] = t;
		glMultiTexCoord2svARB(target,param);
	}

void
glMultiTexCoord3dARB(target,s,t,r)
	GLenum target
	GLdouble s
	GLdouble t
	GLdouble r
	INIT:
		loadProc(glMultiTexCoord3dARB,"glMultiTexCoord3dARB");
	CODE:
		glMultiTexCoord3dARB(target,s,t,r);

void
glMultiTexCoord3dvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3dvARB,"glMultiTexCoord3dvARB");
	CODE:
		glMultiTexCoord3dvARB(target,v);

void
glMultiTexCoord3dvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3dvARB,"glMultiTexCoord3dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble));
		glMultiTexCoord3dvARB(target,v_s);
	}

void
glMultiTexCoord3dvARB_p(target,s,t,r)
	GLenum target
	GLdouble s
	GLdouble t
	GLdouble r
	INIT:
		loadProc(glMultiTexCoord3dvARB,"glMultiTexCoord3dvARB");
	CODE:
	{
		GLdouble param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glMultiTexCoord3dvARB(target,param);
	}

void
glMultiTexCoord3fARB(target,s,t,r)
	GLenum target
	GLfloat s
	GLfloat t
	GLfloat r
	INIT:
		loadProc(glMultiTexCoord3fARB,"glMultiTexCoord3fARB");
	CODE:
		glMultiTexCoord3fARB(target,s,t,r);

void
glMultiTexCoord3fvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3fvARB,"glMultiTexCoord3fvARB");
	CODE:
		glMultiTexCoord3fvARB(target,v);

void
glMultiTexCoord3fvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3fvARB,"glMultiTexCoord3fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat));
		glMultiTexCoord3fvARB(target,v_s);
	}

void
glMultiTexCoord3fvARB_p(target,s,t,r)
	GLenum target
	GLfloat s
	GLfloat t
	GLfloat r
	INIT:
		loadProc(glMultiTexCoord3fvARB,"glMultiTexCoord3fvARB");
	CODE:
	{
		GLfloat param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glMultiTexCoord3fvARB(target,param);
	}

void
glMultiTexCoord3iARB(target,s,t,r)
	GLenum target
	GLint s
	GLint t
	GLint r
	INIT:
		loadProc(glMultiTexCoord3iARB,"glMultiTexCoord3iARB");
	CODE:
		glMultiTexCoord3iARB(target,s,t,r);

void
glMultiTexCoord3ivARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3ivARB,"glMultiTexCoord3ivARB");
	CODE:
		glMultiTexCoord3ivARB(target,v);

void
glMultiTexCoord3ivARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3ivARB,"glMultiTexCoord3ivARB");
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint));
		glMultiTexCoord3ivARB(target,v_s);
	}

void
glMultiTexCoord3ivARB_p(target,s,t,r)
	GLenum target
	GLint s
	GLint t
	GLint r
	INIT:
		loadProc(glMultiTexCoord3ivARB,"glMultiTexCoord3ivARB");
	CODE:
	{
		GLint param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glMultiTexCoord3ivARB(target,param);
	}

void
glMultiTexCoord3sARB(target,s,t,r)
	GLenum target
	GLshort s
	GLshort t
	GLshort r
	INIT:
		loadProc(glMultiTexCoord3sARB,"glMultiTexCoord3sARB");
	CODE:
		glMultiTexCoord3sARB(target,s,t,r);

void
glMultiTexCoord3svARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3svARB,"glMultiTexCoord3svARB");
	CODE:
		glMultiTexCoord3svARB(target,v);

void
glMultiTexCoord3svARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord3svARB,"glMultiTexCoord3svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort));
		glMultiTexCoord3svARB(target,v_s);
	}

void
glMultiTexCoord3svARB_p(target,s,t,r)
	GLenum target
	GLshort s
	GLshort t
	GLshort r
	INIT:
		loadProc(glMultiTexCoord3svARB,"glMultiTexCoord3svARB");
	CODE:
	{
		GLshort param[3];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		glMultiTexCoord3svARB(target,param);
	}

void
glMultiTexCoord4dARB(target,s,t,r,q)
	GLenum target
	GLdouble s
	GLdouble t
	GLdouble r
	GLdouble q
	INIT:
		loadProc(glMultiTexCoord4dARB,"glMultiTexCoord4dARB");
	CODE:
		glMultiTexCoord4dARB(target,s,t,r,q);

void
glMultiTexCoord4dvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4dvARB,"glMultiTexCoord4dvARB");
	CODE:
		glMultiTexCoord4dvARB(target,v);

void
glMultiTexCoord4dvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4dvARB,"glMultiTexCoord4dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble));
		glMultiTexCoord4dvARB(target,v_s);
	}

void
glMultiTexCoord4dvARB_p(target,s,t,r,q)
	GLenum target
	GLdouble s
	GLdouble t
	GLdouble r
	GLdouble q
	INIT:
		loadProc(glMultiTexCoord4dvARB,"glMultiTexCoord4dvARB");
	CODE:
	{
		GLdouble param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glMultiTexCoord4dvARB(target,param);
	}

void
glMultiTexCoord4fARB(target,s,t,r,q)
	GLenum target
	GLfloat s
	GLfloat t
	GLfloat r
	GLfloat q
	INIT:
		loadProc(glMultiTexCoord4fARB,"glMultiTexCoord4fARB");
	CODE:
		glMultiTexCoord4fARB(target,s,t,r,q);

void
glMultiTexCoord4fvARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4fvARB,"glMultiTexCoord4fvARB");
	CODE:
		glMultiTexCoord4fvARB(target,v);

void
glMultiTexCoord4fvARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4fvARB,"glMultiTexCoord4fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat));
		glMultiTexCoord4fvARB(target,v_s);
	}

void
glMultiTexCoord4fvARB_p(target,s,t,r,q)
	GLenum target
	GLfloat s
	GLfloat t
	GLfloat r
	GLfloat q
	INIT:
		loadProc(glMultiTexCoord4fvARB,"glMultiTexCoord4fvARB");
	CODE:
	{
		GLfloat param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glMultiTexCoord4fvARB(target,param);
	}

void
glMultiTexCoord4iARB(target,s,t,r,q)
	GLenum target
	GLint s
	GLint t
	GLint r
	GLint q
	INIT:
		loadProc(glMultiTexCoord4iARB,"glMultiTexCoord4iARB");
	CODE:
		glMultiTexCoord4iARB(target,s,t,r,q);

void
glMultiTexCoord4ivARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4ivARB,"glMultiTexCoord4ivARB");
	CODE:
		glMultiTexCoord4ivARB(target,v);

void
glMultiTexCoord4ivARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4ivARB,"glMultiTexCoord4ivARB");
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint));
		glMultiTexCoord4ivARB(target,v_s);
	}

void
glMultiTexCoord4ivARB_p(target,s,t,r,q)
	GLenum target
	GLint s
	GLint t
	GLint r
	GLint q
	INIT:
		loadProc(glMultiTexCoord4ivARB,"glMultiTexCoord4ivARB");
	CODE:
	{
		GLint param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glMultiTexCoord4ivARB(target,param);
	}

void
glMultiTexCoord4sARB(target,s,t,r,q)
	GLenum target
	GLshort s
	GLshort t
	GLshort r
	GLshort q
	INIT:
		loadProc(glMultiTexCoord4sARB,"glMultiTexCoord4sARB");
	CODE:
		glMultiTexCoord4sARB(target,s,t,r,q);

void
glMultiTexCoord4svARB_c(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4svARB,"glMultiTexCoord4svARB");
	CODE:
		glMultiTexCoord4svARB(target,v);

void
glMultiTexCoord4svARB_s(target,v)
	GLenum target
	void *v
	INIT:
		loadProc(glMultiTexCoord4svARB,"glMultiTexCoord4svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort));
		glMultiTexCoord4svARB(target,v_s);
	}

void
glMultiTexCoord4svARB_p(target,s,t,r,q)
	GLenum target
	GLshort s
	GLshort t
	GLshort r
	GLshort q
	INIT:
		loadProc(glMultiTexCoord4svARB,"glMultiTexCoord4svARB");
	CODE:
	{
		GLshort param[4];
		param[0] = s;
		param[1] = t;
		param[2] = r;
		param[3] = q;
		glMultiTexCoord4svARB(target,param);
	}

#endif



#ifdef GL_ARB_shader_objects

void
glDeleteObjectARB(obj)
	GLhandleARB	obj
	INIT:
		loadProc(glDeleteObjectARB,"glDeleteObjectARB");
	CODE:
	{
		glDeleteObjectARB(obj);
	}

GLhandleARB
glGetHandleARB(pname)
	GLenum	pname
	INIT:
		loadProc(glGetHandleARB,"glGetHandleARB");
	CODE:
	{
		RETVAL = glGetHandleARB(pname);
	}
	OUTPUT:
		RETVAL

void
glDetachObjectARB(containerObj, attachedObj)
	GLhandleARB containerObj
	GLhandleARB attachedObj
	INIT:
		loadProc(glDetachObjectARB,"glDetachObjectARB");
	CODE:
	{
		glDetachObjectARB(containerObj, attachedObj);
	}

GLhandleARB
glCreateShaderObjectARB(shaderType)
	GLenum shaderType
	INIT:
		loadProc(glCreateShaderObjectARB,"glCreateShaderObjectARB");
	CODE:
	{
		RETVAL = glCreateShaderObjectARB(shaderType);
	}
	OUTPUT:
		RETVAL

void
glShaderSourceARB_c(shaderObj, count, string, length)
	GLhandleARB shaderObj
	GLsizei count
	void	*string
	void	*length
	INIT:
		loadProc(glShaderSourceARB,"glShaderSourceARB");
	CODE:
	{
		glShaderSourceARB(shaderObj, count, string, length);
	}

void
glShaderSourceARB_p(shaderObj, ...)
	GLhandleARB shaderObj
	INIT:
		loadProc(glShaderSourceARB,"glShaderSourceARB");
	CODE:
	{
		int i;
		int count = items - 1;
		GLcharARB **string = malloc(sizeof(GLcharARB *) * count);
		GLint *length = malloc(sizeof(GLint) * count);

		for(i=0;i<count;i++) {
			string[i] = (GLcharARB *)SvPV(ST(i+1),PL_na);
			length[i] = strlen(string[i]);
		}

		glShaderSourceARB(shaderObj, count, (const GLcharARB**)string,
			(const GLint *)length);

		free(length);
                free(string);
	}

void
glCompileShaderARB(shaderObj)
	GLhandleARB shaderObj
	INIT:
		loadProc(glCompileShaderARB,"glCompileShaderARB");
	CODE:
	{
		glCompileShaderARB(shaderObj);
	}

GLhandleARB
glCreateProgramObjectARB()
	INIT:
		loadProc(glCreateProgramObjectARB,"glCreateProgramObjectARB");
	CODE:
	{
		RETVAL = glCreateProgramObjectARB();
	}
	OUTPUT:
		RETVAL

void
glAttachObjectARB(containerObj, obj)
	GLhandleARB containerObj
	GLhandleARB obj
	INIT:
		loadProc(glAttachObjectARB,"glAttachObjectARB");
	CODE:
	{
		glAttachObjectARB(containerObj, obj);
	}

void
glLinkProgramARB(programObj)
	GLhandleARB programObj
	INIT:
		loadProc(glLinkProgramARB,"glLinkProgramARB");
	CODE:
	{
		glLinkProgramARB(programObj);
	}

void
glUseProgramObjectARB(programObj)
	GLhandleARB programObj
	INIT:
		loadProc(glUseProgramObjectARB,"glUseProgramObjectARB");
	CODE:
	{
		glUseProgramObjectARB(programObj);
	}

void
glValidateProgramARB(programObj)
	GLhandleARB programObj
	INIT:
		loadProc(glValidateProgramARB,"glValidateProgramARB");
	CODE:
	{
		glValidateProgramARB(programObj);
	}

void
glUniform1fARB(location, v0)
	GLint location
	GLfloat v0
	INIT:
		loadProc(glUniform1fARB,"glUniform1fARB");
	CODE:
	{
		glUniform1fARB(location, v0);
	}

void
glUniform2fARB(location, v0, v1)
	GLint location
	GLfloat v0
	GLfloat v1
	INIT:
		loadProc(glUniform2fARB,"glUniform2fARB");
	CODE:
	{
		glUniform2fARB(location, v0, v1);
	}

void
glUniform3fARB(location, v0, v1, v2)
	GLint location
	GLfloat v0
	GLfloat v1
	GLfloat v2
	INIT:
		loadProc(glUniform3fARB,"glUniform3fARB");
	CODE:
	{
		glUniform3fARB(location, v0, v1, v2);
	}

void
glUniform4fARB(location, v0, v1, v2, v3)
	GLint location
	GLfloat v0
	GLfloat v1
	GLfloat v2
	GLfloat v3
	INIT:
		loadProc(glUniform4fARB,"glUniform4fARB");
	CODE:
	{
		glUniform4fARB(location, v0, v1, v2, v3);
	}

void
glUniform1iARB(location, v0)
	GLint location
	GLint v0
	INIT:
		loadProc(glUniform1iARB,"glUniform1iARB");
	CODE:
	{
		glUniform1iARB(location, v0);
	}

void
glUniform2iARB(location, v0, v1)
	GLint location
	GLint v0
	GLint v1
	INIT:
		loadProc(glUniform2iARB,"glUniform2iARB");
	CODE:
	{
		glUniform2iARB(location, v0, v1);
	}

void
glUniform3iARB(location, v0, v1, v2)
	GLint location
	GLint v0
	GLint v1
	GLint v2
	INIT:
		loadProc(glUniform3iARB,"glUniform3iARB");
	CODE:
	{
		glUniform3iARB(location, v0, v1, v2);
	}

void
glUniform4iARB(location, v0, v1, v2, v3)
	GLint location
	GLint v0
	GLint v1
	GLint v2
	GLint v3
	INIT:
		loadProc(glUniform4iARB,"glUniform4iARB");
	CODE:
	{
		glUniform4iARB(location, v0, v1, v2, v3);
	}

void
glUniform1fvARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform1fvARB,"glUniform1fvARB");
	CODE:
		glUniform1fvARB(location, count, value);

void
glUniform1fvARB_s(location, count, value)
	GLint	location
	GLsizei count
	SV	*value
	INIT:
		loadProc(glUniform1fvARB,"glUniform1fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniform1fvARB(location, count, value_s);
	}

void
glUniform1fvARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform1fvARB,"glUniform1fvARB");
	CODE:
	{
		int i;
		GLsizei count = items - 1;
		GLfloat *value = malloc(sizeof(GLfloat) * count);

		for(i=0;i<count;i++) {
			value[i] = SvNV(ST(i+1));
		}

		glUniform1fvARB(location, count, value);

		free(value);
	}

void
glUniform2fvARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform2fvARB,"glUniform2fvARB");
	CODE:
		glUniform2fvARB(location, count, value);

void
glUniform2fvARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform2fvARB,"glUniform2fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniform2fvARB(location, count, value_s);
	}

void
glUniform2fvARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform2fvARB,"glUniform2fvARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 1;
		GLsizei count = elements >> 1;
		GLfloat *value = malloc(sizeof(GLfloat) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvNV(ST(i+1));
		}

		glUniform2fvARB(location, count, value);

		free(value);
	}

void
glUniform3fvARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform3fvARB,"glUniform3fvARB");
	CODE:
		glUniform3fvARB(location, count, value);

void
glUniform3fvARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform3fvARB,"glUniform3fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniform3fvARB(location, count, value_s);
	}

void
glUniform3fvARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform3fvARB,"glUniform3fvARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 1;
		GLsizei count = elements / 3;
		GLfloat *value = malloc(sizeof(GLfloat) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvNV(ST(i+1));
		}

		glUniform3fvARB(location, count, value);

		free(value);
	}

void
glUniform4fvARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform4fvARB,"glUniform4fvARB");
	CODE:
		glUniform4fvARB(location, count, value);

void
glUniform4fvARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform4fvARB,"glUniform4fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniform4fvARB(location, count, value_s);
	}

void
glUniform4fvARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform4fvARB,"glUniform4fvARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 1;
		GLsizei count = elements >> 2;
		GLfloat *value = malloc(sizeof(GLfloat) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvNV(ST(i+1));
		}

		glUniform4fvARB(location, count, value);

		free(value);
	}

void
glUniform1ivARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform1ivARB,"glUniform1ivARB");
	CODE:
		glUniform1ivARB(location, count, value);

void
glUniform1ivARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform1ivARB,"glUniform1ivARB");
	CODE:
	{
		GLint * value_s = EL(value, sizeof(GLint));
		glUniform1ivARB(location, count, value_s);
	}

void
glUniform1ivARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform1ivARB,"glUniform1ivARB");
	CODE:
	{
		int i;
		GLsizei count = items - 1;
		GLint *value = malloc(sizeof(GLint) * count);

		for(i=0;i<count;i++) {
			value[i] = SvIV(ST(i+1));
		}

		glUniform1ivARB(location, count, value);

		free(value);
	}

void
glUniform2ivARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform2ivARB,"glUniform2ivARB");
	CODE:
		glUniform2ivARB(location, count, value);

void
glUniform2ivARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform2ivARB,"glUniform2ivARB");
	CODE:
	{
		GLint * value_s = EL(value, sizeof(GLint));
		glUniform2ivARB(location, count, value_s);
	}

void
glUniform2ivARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform2ivARB,"glUniform2ivARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 1;
		GLsizei count = elements >> 1;
		GLint *value = malloc(sizeof(GLint) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvIV(ST(i+1));
		}

		glUniform2ivARB(location, count, value);

		free(value);
	}

void
glUniform3ivARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform3ivARB,"glUniform3ivARB");
	CODE:
		glUniform3ivARB(location, count, value);

void
glUniform3ivARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform3ivARB,"glUniform3ivARB");
	CODE:
	{
		GLint * value_s = EL(value, sizeof(GLint));
		glUniform3ivARB(location, count, value_s);
	}

void
glUniform3ivARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform3ivARB,"glUniform3ivARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 1;
		GLsizei count = elements / 3;
		GLint *value = malloc(sizeof(GLint) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvIV(ST(i+1));
		}

		glUniform3ivARB(location, count, value);

		free(value);
	}

void
glUniform4ivARB_c(location, count, value)
	GLint	location
	GLsizei	count
	void	*value
	INIT:
		loadProc(glUniform4ivARB,"glUniform4ivARB");
	CODE:
		glUniform4ivARB(location, count, value);

void
glUniform4ivARB_s(location, count, value)
	GLint	location
	GLsizei	count
	SV	*value
	INIT:
		loadProc(glUniform4ivARB,"glUniformifvARB");
	CODE:
	{
		GLint * value_s = EL(value, sizeof(GLint));
		glUniform4ivARB(location, count, value_s);
	}

void
glUniform4ivARB_p(location, ...)
	GLint location
	INIT:
		loadProc(glUniform4ivARB,"glUniform4ivARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 1;
		GLsizei count = elements >> 2;
		GLint *value = malloc(sizeof(GLint) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvIV(ST(i+1));
		}

		glUniform4ivARB(location, count, value);

		free(value);
	}

void
glUniformMatrix2fvARB_c(location, count, transpose, value)
	GLint	location
	GLsizei	count
	GLboolean transpose
	void	*value
	INIT:
		loadProc(glUniformMatrix2fvARB,"glUniformMatrix2fvARB");
	CODE:
		glUniformMatrix2fvARB(location, count, transpose, value);

void
glUniformMatrix2fvARB_s(location, count, transpose, value)
	GLint	location
	GLsizei	count
	GLboolean transpose
	SV	*value
	INIT:
		loadProc(glUniformMatrix2fvARB,"glUniformMatrix2fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniformMatrix2fvARB(location, count, transpose, value_s);
	}

void
glUniformMatrix2fvARB_p(location, transpose, ...)
	GLint location
	GLboolean transpose
	INIT:
		loadProc(glUniformMatrix2fvARB,"glUniformMatrix2fvARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 2;
		GLsizei count = elements / 4;
		GLfloat *value = malloc(sizeof(GLfloat) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvNV(ST(i+2));
		}

		glUniformMatrix2fvARB(location, count, transpose, value);

		free(value);
	}

void
glUniformMatrix3fvARB_c(location, count, transpose, value)
	GLint	location
	GLsizei	count
	GLboolean transpose
	void	*value
	INIT:
		loadProc(glUniformMatrix3fvARB,"glUniformMatrix2fvARB");
	CODE:
		glUniformMatrix3fvARB(location, count, transpose, value);

void
glUniformMatrix3fvARB_s(location, count, transpose, value)
	GLint	location
	GLsizei	count
	GLboolean transpose
	SV	*value
	INIT:
		loadProc(glUniformMatrix3fvARB,"glUniformMatrix3fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniformMatrix3fvARB(location, count, transpose, value_s);
	}

void
glUniformMatrix3fvARB_p(location, transpose, ...)
	GLint location
	GLboolean transpose
	INIT:
		loadProc(glUniformMatrix3fvARB,"glUniformMatrix3fvARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 2;
		GLsizei count = elements / 9;
		GLfloat *value = malloc(sizeof(GLfloat) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvNV(ST(i+2));
		}

		glUniformMatrix3fvARB(location, count, transpose, value);

		free(value);
	}

void
glUniformMatrix4fvARB_c(location, count, transpose, value)
	GLint	location
	GLsizei	count
	GLboolean transpose
	void	*value
	INIT:
		loadProc(glUniformMatrix4fvARB,"glUniformMatrix4fvARB");
	CODE:
		glUniformMatrix4fvARB(location, count, transpose, value);

void
glUniformMatrix4fvARB_s(location, count, transpose, value)
	GLint	location
	GLsizei	count
	GLboolean transpose
	SV	*value
	INIT:
		loadProc(glUniformMatrix4fvARB,"glUniformMatrix4fvARB");
	CODE:
	{
		GLfloat * value_s = EL(value, sizeof(GLfloat));
		glUniformMatrix4fvARB(location, count, transpose, value_s);
	}

void
glUniformMatrix4fvARB_p(location, transpose, ...)
	GLint location
	GLboolean transpose
	INIT:
		loadProc(glUniformMatrix4fvARB,"glUniformMatrix4fvARB");
	CODE:
	{
		int i;
		GLsizei elements = items - 2;
		GLsizei count = elements / 16;
		GLfloat *value = malloc(sizeof(GLfloat) * elements);

		for(i=0;i<elements;i++) {
			value[i] = SvNV(ST(i+2));
		}

		glUniformMatrix4fvARB(location, count, transpose, value);

		free(value);
	}

void
glGetObjectParameterfvARB_c(obj,pname,params)
	GLhandleARB obj
	GLenum	pname
	void	*params
	INIT:
		loadProc(glGetObjectParameterfvARB,"glGetObjectParameterfvARB");
	CODE:
		glGetObjectParameterfvARB(obj,pname,params);

void
glGetObjectParameterfvARB_s(obj,pname,params)
	GLhandleARB obj
	GLenum	pname
	SV	*params
	INIT:
		loadProc(glGetObjectParameterfvARB,"glGetObjectParameterfvARB");
	CODE:
	{
		GLfloat * params_s = EL(params, sizeof(GLfloat));
		glGetObjectParameterfvARB(obj,pname,params_s);
	}

GLfloat
glGetObjectParameterfvARB_p(obj,pname)
	GLhandleARB obj
	GLenum pname
	INIT:
		loadProc(glGetObjectParameterfvARB,"glGetObjectParameterfvARB");
	CODE:
	{
		GLfloat	ret;
		glGetObjectParameterfvARB(obj,pname,&ret);
		RETVAL = ret;
	}
	OUTPUT:
		RETVAL

void
glGetObjectParameterivARB_c(obj,pname,params)
	GLhandleARB obj
	GLenum	pname
	void	*params
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
	CODE:
		glGetObjectParameterivARB(obj,pname,params);

void
glGetObjectParameterivARB_s(obj,pname,params)
	GLhandleARB obj
	GLenum	pname
	SV	*params
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
	CODE:
	{
		GLint * params_s = EL(params, sizeof(GLint));
		glGetObjectParameterivARB(obj,pname,params_s);
	}

GLint
glGetObjectParameterivARB_p(obj,pname)
	GLhandleARB obj
	GLenum pname
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
	CODE:
	{
		GLint	ret;
		glGetObjectParameterivARB(obj,pname,&ret);
		RETVAL = ret;
	}
	OUTPUT:
		RETVAL

void
glGetInfoLogARB_c(obj, maxLength, length, infoLog)
	GLhandleARB obj
	GLsizei	maxLength
	void	*length
	void	*infoLog
	INIT:
		loadProc(glGetInfoLogARB,"glGetInfoLogARB");
	CODE:
		glGetInfoLogARB(obj, maxLength, length, infoLog);

SV *
glGetInfoLogARB_p(obj)
	GLhandleARB obj
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
		loadProc(glGetInfoLogARB,"glGetInfoLogARB");
	CODE:
	{
		GLint maxLength;
		glGetObjectParameterivARB(obj,GL_OBJECT_INFO_LOG_LENGTH_ARB,(GLvoid *)&maxLength);
		if (maxLength)
		{
			GLint length;
			GLcharARB * infoLog = malloc(maxLength+1);
			glGetInfoLogARB(obj,maxLength,&length,infoLog);
			infoLog[length] = 0;
			if (*infoLog)
				RETVAL = newSVpv(infoLog, 0);
			else
				RETVAL = newSVsv(&PL_sv_undef);

			free(infoLog);
		}
		else
		{
			RETVAL = newSVsv(&PL_sv_undef);
		}
	}
	OUTPUT:
		RETVAL

void
glGetAttachedObjectsARB_c(containerObj, maxCount, count, obj)
	GLhandleARB containerObj
	GLsizei	maxCount
	void	*count
	void	*obj
	INIT:
		loadProc(glGetAttachedObjectsARB,"glGetAttachedObjectsARB");
	CODE:
		glGetAttachedObjectsARB(containerObj, maxCount, count, obj);

void
glGetAttachedObjectsARB_s(containerObj, maxCount, count, obj)
	GLhandleARB containerObj
	GLsizei	maxCount
	void	*count
	SV	*obj
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
		loadProc(glGetAttachedObjectsARB,"glGetAttachedObjectsARB");
	CODE:
	{
		GLint len;
		glGetObjectParameterivARB(containerObj,GL_OBJECT_ATTACHED_OBJECTS_ARB,
			(GLvoid *)&len);
		if (len)
		{
			GLsizei * count_s = EL(count, sizeof(GLsizei));
			GLhandleARB * obj_s = EL(obj, sizeof(GLhandleARB)*len);
			glGetAttachedObjectsARB(containerObj, maxCount, count_s, obj_s);
		}
	}

void
glGetAttachedObjectsARB_p(containerObj)
	GLhandleARB containerObj
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
		loadProc(glGetAttachedObjectsARB,"glGetAttachedObjectsARB");
	PPCODE:
	{
		GLsizei maxCount;
		GLsizei count;
		GLhandleARB *obj;
		int i;

		glGetObjectParameterivARB(containerObj,GL_OBJECT_ATTACHED_OBJECTS_ARB,
			(GLvoid *)&maxCount);
		obj = malloc(sizeof(GLhandleARB)*maxCount);

		glGetAttachedObjectsARB(containerObj, maxCount, &count, obj);

		EXTEND(sp, count);
		for(i=0;i<count;i++)
			PUSHs(sv_2mortal(newSViv(obj[i])));

		free(obj);
	}

GLint
glGetUniformLocationARB_c(programObj, name)
	GLhandleARB programObj
	void	*name
	INIT:
		loadProc(glGetUniformLocationARB,"glGetUniformLocationARB");
	CODE:
		RETVAL = glGetUniformLocationARB(programObj, name);
	OUTPUT:
		RETVAL

GLint
glGetUniformLocationARB_p(programObj, ...)
	GLhandleARB programObj
	INIT:
		loadProc(glGetUniformLocationARB,"glGetUniformLocationARB");
	CODE:
	{
		GLcharARB *name = (GLcharARB *)SvPV(ST(1),PL_na);
		RETVAL = glGetUniformLocationARB(programObj, name);
	}
	OUTPUT:
		RETVAL

void
glGetActiveUniformARB_c(programObj, index, maxLength, length, size, type, name)
	GLhandleARB programObj
	GLuint	index
	GLsizei	maxLength
	void	*length
	void	*size
	void	*type
	void	*name
	INIT:
		loadProc(glGetActiveUniformARB,"glGetActiveUniformARB");
	CODE:
		glGetActiveUniformARB(programObj,index,maxLength,length,size,type,name);

void
glGetActiveUniformARB_s(programObj, index, maxLength, length, size, type, name)
	GLhandleARB programObj
	GLuint	index
	GLsizei	maxLength
	SV	*length
	SV	*size
	SV	*type
	SV	*name
	INIT:
		loadProc(glGetActiveUniformARB,"glGetActiveUniformARB");
	CODE:
	{
		GLsizei	  *length_s = EL(length, sizeof(GLsizei));
		GLint	  *size_s = EL(size, sizeof(GLint));
		GLenum	  *type_s = EL(type, sizeof(GLenum));
		GLcharARB *name_s = EL(name, sizeof(GLcharARB));
		glGetActiveUniformARB(programObj,index,maxLength,length_s,size_s,type_s,name_s);
	}

void
glGetActiveUniformARB_p(programObj, index)
	GLhandleARB programObj
	GLuint index
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
		loadProc(glGetActiveUniformARB,"glGetActiveUniformARB");
	PPCODE:
	{
		GLsizei maxLength;
		glGetObjectParameterivARB(programObj,GL_OBJECT_ACTIVE_UNIFORM_MAX_LENGTH_ARB,
			(GLvoid *)&maxLength);
		if (maxLength)
		{
			GLsizei length;
			GLint size;
			GLenum type;
			GLcharARB *name;

			name = malloc(maxLength+1);
			glGetActiveUniformARB(programObj,index,maxLength,
				&length,&size,&type,name);
			name[length] = 0;

			if (*name)
			{
				EXTEND(sp,3);
				PUSHs(sv_2mortal(newSVpv(name,0)));
				PUSHs(sv_2mortal(newSViv(type)));
				PUSHs(sv_2mortal(newSViv(size)));
			}
			else
			{
				EXTEND(sp,1);
				PUSHs(sv_2mortal(newSVsv(&PL_sv_undef)));
			}

			free(name);
		}
		else
		{
			EXTEND(sp,1);
			PUSHs(sv_2mortal(newSVsv(&PL_sv_undef)));
		}
	}

void
glGetUniformfvARB_c(programObj, location, params)
	GLhandleARB programObj
	GLint	location
	void	*params
	INIT:
		loadProc(glGetUniformfvARB,"glGetUniformfvARB");
	CODE:
		glGetUniformfvARB(programObj, location, params);

void
glGetUniformfvARB_p(programObj, location, count=1)
	GLhandleARB programObj
	GLint location
	int count
	INIT:
		loadProc(glGetUniformfvARB,"glGetUniformfvARB");
	CODE:
	{
		int i;
		GLfloat	*ret = malloc(sizeof(GLfloat)*count);
		glGetUniformfvARB(programObj, location, ret);

		for(i=0;i<count;i++)
			PUSHs(sv_2mortal(newSVnv(ret[i])));
	}

void
glGetUniformivARB_c(programObj, location, params)
	GLhandleARB programObj
	GLint	location
	void	*params
	INIT:
		loadProc(glGetUniformivARB,"glGetUniformivARB");
	CODE:
		glGetUniformivARB(programObj, location, params);

void
glGetUniformivARB_p(programObj, location, count=1)
	GLhandleARB programObj
	GLint	location
	int count
	INIT:
		loadProc(glGetUniformivARB,"glGetUniformivARB");
	CODE:
	{
		int i;
		GLint	*ret = malloc(sizeof(GLint)*count);
		glGetUniformivARB(programObj, location, ret);

		for(i=0;i<count;i++)
			PUSHs(sv_2mortal(newSViv(ret[i])));
	}

void
glGetShaderSourceARB_c(obj, maxLength, length, source)
	GLhandleARB obj
	GLsizei	maxLength
	void	*length
	void	*source
	INIT:
		loadProc(glGetShaderSourceARB,"glGetShaderSourceARB");
	CODE:
		glGetShaderSourceARB(obj, maxLength, length, source);

void
glGetShaderSourceARB_p(obj)
	GLhandleARB obj
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
		loadProc(glGetShaderSourceARB,"glGetShaderSourceARB");
	PPCODE:
	{
		GLsizei maxLength;
		glGetObjectParameterivARB(obj,GL_OBJECT_SHADER_SOURCE_LENGTH_ARB,
			(GLvoid *)&maxLength);

		EXTEND(sp,1);

		if (maxLength)
		{
			GLsizei length;
			GLcharARB *source;

			source = malloc(maxLength+1);
			glGetShaderSourceARB(obj,maxLength,&length,source);
			source[length] = 0;

			if (*source)
			{
				PUSHs(sv_2mortal(newSVpv(source,0)));
			}
			else
			{
				PUSHs(sv_2mortal(newSVsv(&PL_sv_undef)));
			}

			free(source);
		}
		else
		{
			PUSHs(sv_2mortal(newSVsv(&PL_sv_undef)));
		}
	}

#endif


#ifdef GL_ARB_vertex_program

void
glProgramStringARB_c(target,format,len,string)
	GLenum target
	GLenum format
	GLsizei len
	void * string
	INIT:
		loadProc(glProgramStringARB,"glProgramStringARB");
	CODE:
		glProgramStringARB(target,format,len,string);

void
glProgramStringARB_s(target,format,len,string)
	GLenum target
	GLenum format
	GLsizei len
	SV *	string
	INIT:
		loadProc(glProgramStringARB,"glProgramStringARB");
	CODE:
	{
		GLvoid * string_s = EL(string, len);
		glProgramStringARB(target,format,len,string_s);
	}

void
glProgramStringARB_p(target,string)
	GLenum target
	char * string
	INIT:
		loadProc(glProgramStringARB,"glProgramStringARB");
	CODE:
	{
		int len = strlen(string);
		glProgramStringARB(target,GL_PROGRAM_FORMAT_ASCII_ARB,len,string);
	}

void
glBindProgramARB(target,program)
	GLenum target
	GLuint program
	INIT:
		loadProc(glBindProgramARB,"glBindProgramARB");

void
glDeleteProgramsARB_c(n,programs)
	GLsizei n
	void *	programs
	INIT:
		loadProc(glDeleteProgramsARB,"glDeleteProgramsARB");
	CODE:
	{
		glDeleteProgramsARB(n,(GLuint*)programs);
	}

void
glDeleteProgramsARB_s(n,programs)
	GLsizei n
	SV *	programs
	INIT:
		loadProc(glDeleteProgramsARB,"glDeleteProgramsARB");
	CODE:
	{
		GLuint * programs_s = EL(programs, sizeof(GLuint)*n);
		glDeleteProgramsARB(n,programs_s);
	}

void
glDeleteProgramsARB_p(...)
	INIT:
		loadProc(glDeleteProgramsARB,"glDeleteProgramsARB");
	CODE:
	{
		if (items) {
			GLuint * list = malloc(sizeof(GLuint) * items);
			int i;

			for (i=0;i<items;i++)
				list[i] = SvIV(ST(i));

			glDeleteProgramsARB(items, list);
			free(list);
		}
	}

void
glGenProgramsARB_c(n,programs)
	GLsizei n
	void *	programs
	INIT:
		loadProc(glGenProgramsARB,"glGenProgramsARB");
	CODE:
	{
		glGenProgramsARB(n,(GLuint*)programs);
	}

void
glGenProgramsARB_s(n,programs)
	GLsizei n
	SV *	programs
	INIT:
		loadProc(glGenProgramsARB,"glGenProgramsARB");
	CODE:
	{
		GLuint * programs_s = EL(programs, sizeof(GLuint)*n);
		glGenProgramsARB(n, programs_s);
	}

void
glGenProgramsARB_p(n)
	GLsizei n
	INIT:
		loadProc(glGenProgramsARB,"glGenProgramsARB");
	PPCODE:
	if (n)
	{
		GLuint * programs = malloc(sizeof(GLuint) * n);
		int i;

		glGenProgramsARB(n, programs);

		EXTEND(sp, n);
		for(i=0;i<n;i++)
			PUSHs(sv_2mortal(newSViv(programs[i])));

		free(programs);
	} 

void
glProgramEnvParameter4dARB(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLdouble x
	GLdouble y
	GLdouble z
	GLdouble w
	INIT:
		loadProc(glProgramEnvParameter4dARB,"glProgramEnvParameter4dARB");

void
glProgramEnvParameter4dvARB_c(target,index,v)
	GLenum target
	GLuint index
	void *	v
	INIT:
		loadProc(glProgramEnvParameter4dvARB,"glProgramEnvParameter4dvARB");
	CODE:
		glProgramEnvParameter4dvARB(target,index,(GLdouble*)v);

void
glProgramEnvParameter4dvARB_s(target,index,v)
	GLenum target
	GLuint index
	SV *	v
	INIT:
		loadProc(glProgramEnvParameter4dvARB,"glProgramEnvParameter4dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glProgramEnvParameter4dvARB(target,index,v_s);
	}

void
glProgramEnvParameter4dvARB_p(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w
	INIT:
		loadProc(glProgramEnvParameter4dvARB,"glProgramEnvParameter4dvARB");
	CODE:
	{
		GLdouble param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glProgramEnvParameter4dvARB(target,index,param);
	}

void
glProgramEnvParameter4fARB(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLfloat x
	GLfloat y
	GLfloat z
	GLfloat w
	INIT:
		loadProc(glProgramEnvParameter4fARB,"glProgramEnvParameter4fARB");

void
glProgramEnvParameter4fvARB_c(target,index,v)
	GLenum target
	GLuint index
	void *	v
	INIT:
		loadProc(glProgramEnvParameter4fvARB,"glProgramEnvParameter4fvARB");
	CODE:
		glProgramEnvParameter4fvARB(target,index,(GLfloat*)v);

void
glProgramEnvParameter4fvARB_s(target,index,v)
	GLenum target
	GLuint index
	SV *	v
	INIT:
		loadProc(glProgramEnvParameter4fvARB,"glProgramEnvParameter4fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glProgramEnvParameter4fvARB(target,index,v_s);
	}

void
glProgramEnvParameter4fvARB_p(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w
	INIT:
		loadProc(glProgramEnvParameter4fvARB,"glProgramEnvParameter4fvARB");
	CODE:
	{
		GLfloat param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glProgramEnvParameter4fvARB(target,index,param);
	}

void
glProgramLocalParameter4dARB(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLdouble x
	GLdouble y
	GLdouble z
	GLdouble w
	INIT:
		loadProc(glProgramLocalParameter4dARB,"glProgramLocalParameter4dARB");

void
glProgramLocalParameter4dvARB_c(target,index,v)
	GLenum target
	GLuint index
	void *	v
	INIT:
		loadProc(glProgramLocalParameter4dvARB,"glProgramLocalParameter4dvARB");
	CODE:
		glProgramLocalParameter4dvARB(target,index,(GLdouble*)v);

void
glProgramLocalParameter4dvARB_s(target,index,v)
	GLenum target
	GLuint index
	SV *	v
	INIT:
		loadProc(glProgramLocalParameter4dvARB,"glProgramLocalParameter4dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glProgramLocalParameter4dvARB(target,index,v_s);
	}

void
glProgramLocalParameter4dvARB_p(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w
	INIT:
		loadProc(glProgramLocalParameter4dvARB,"glProgramLocalParameter4dvARB");
	CODE:
	{
		GLdouble param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glProgramLocalParameter4dvARB(target,index,param);
	}

void
glProgramLocalParameter4fARB(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLfloat x
	GLfloat y
	GLfloat z
	GLfloat w
	INIT:
		loadProc(glProgramLocalParameter4fARB,"glProgramLocalParameter4fARB");

void
glProgramLocalParameter4fvARB_c(target,index,v)
	GLenum target
	GLuint index
	void *	v
	INIT:
		loadProc(glProgramLocalParameter4fvARB,"glProgramLocalParameter4fvARB");
	CODE:
		glProgramLocalParameter4fvARB(target,index,(GLfloat*)v);

void
glProgramLocalParameter4fvARB_s(target,index,v)
	GLenum target
	GLuint index
	SV *	v
	INIT:
		loadProc(glProgramLocalParameter4fvARB,"glProgramLocalParameter4fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glProgramLocalParameter4fvARB(target,index,v_s);
	}

void
glProgramLocalParameter4fvARB_p(target,index,x,y,z,w)
	GLenum target
	GLuint index
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w
	INIT:
		loadProc(glProgramLocalParameter4fvARB,"glProgramLocalParameter4fvARB");
	CODE:
	{
		GLfloat param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glProgramLocalParameter4fvARB(target,index,param);
	}

void
glGetProgramEnvParameterdvARB_c(target,index,params)
	GLenum	target
	GLint	index
	void *	params
	INIT:
		loadProc(glGetProgramEnvParameterdvARB,"glGetProgramEnvParameterdvARB");
	CODE:
		glGetProgramEnvParameterdvARB(target,index,(GLdouble*)params);

void
glGetProgramEnvParameterdvARB_s(target,index,params)
	GLenum	target
	GLint	index
	SV *	params
	INIT:
		loadProc(glGetProgramEnvParameterdvARB,"glGetProgramEnvParameterdvARB");
	CODE:
	{
		GLdouble * params_s = EL(params, sizeof(GLdouble) * 4);
		glGetProgramEnvParameterdvARB(target,index,params_s);
	}

void
glGetProgramEnvParameterdvARB_p(target,index)
	GLenum	target
	GLint	index
	INIT:
		loadProc(glGetProgramEnvParameterdvARB,"glGetProgramEnvParameterdvARB");
	PPCODE:
	{
		GLdouble params[4];
		glGetProgramEnvParameterdvARB(target,index,params);

		EXTEND(sp, 4);
		PUSHs(sv_2mortal(newSVnv(params[0])));
		PUSHs(sv_2mortal(newSVnv(params[1])));
		PUSHs(sv_2mortal(newSVnv(params[2])));
		PUSHs(sv_2mortal(newSVnv(params[3])));
	}

void
glGetProgramEnvParameterfvARB_c(target,index,params)
	GLenum	target
	GLint	index
	void *	params
	INIT:
		loadProc(glGetProgramEnvParameterfvARB,"glGetProgramEnvParameterfvARB");
	CODE:
		glGetProgramEnvParameterfvARB(target,index,(GLfloat*)params);

void
glGetProgramEnvParameterfvARB_s(target,index,params)
	GLenum	target
	GLint	index
	SV *	params
	INIT:
		loadProc(glGetProgramEnvParameterfvARB,"glGetProgramEnvParameterfvARB");
	CODE:
	{
		GLfloat * params_s = EL(params, sizeof(GLfloat) * 4);
		glGetProgramEnvParameterfvARB(target,index,params_s);
	}

void
glGetProgramEnvParameterfvARB_p(target,index)
	GLenum	target
	GLint	index
	INIT:
		loadProc(glGetProgramEnvParameterfvARB,"glGetProgramEnvParameterfvARB");
	PPCODE:
	{
		GLfloat params[4];
		glGetProgramEnvParameterfvARB(target,index,params);

		EXTEND(sp, 4);
		PUSHs(sv_2mortal(newSVnv(params[0])));
		PUSHs(sv_2mortal(newSVnv(params[1])));
		PUSHs(sv_2mortal(newSVnv(params[2])));
		PUSHs(sv_2mortal(newSVnv(params[3])));
	}

void
glGetProgramLocalParameterdvARB_c(target,index,params)
	GLenum	target
	GLint	index
	void *	params
	INIT:
		loadProc(glGetProgramLocalParameterdvARB,"glGetProgramLocalParameterdvARB");
	CODE:
		glGetProgramLocalParameterdvARB(target,index,(GLdouble*)params);

void
glGetProgramLocalParameterdvARB_s(target,index,params)
	GLenum	target
	GLint	index
	SV *	params
	INIT:
		loadProc(glGetProgramLocalParameterdvARB,"glGetProgramLocalParameterdvARB");
	CODE:
	{
		GLdouble * params_s = EL(params, sizeof(GLdouble) * 4);
		glGetProgramLocalParameterdvARB(target,index,params_s);
	}

void
glGetProgramLocalParameterdvARB_p(target,index)
	GLenum	target
	GLint	index
	INIT:
		loadProc(glGetProgramLocalParameterdvARB,"glGetProgramLocalParameterdvARB");
	PPCODE:
	{
		GLdouble params[4];
		glGetProgramLocalParameterdvARB(target,index,params);

		EXTEND(sp, 4);
		PUSHs(sv_2mortal(newSVnv(params[0])));
		PUSHs(sv_2mortal(newSVnv(params[1])));
		PUSHs(sv_2mortal(newSVnv(params[2])));
		PUSHs(sv_2mortal(newSVnv(params[3])));
	}

void
glGetProgramLocalParameterfvARB_c(target,index,params)
	GLenum	target
	GLint	index
	void *	params
	INIT:
		loadProc(glGetProgramLocalParameterfvARB,"glGetProgramLocalParameterfvARB");
	CODE:
		glGetProgramLocalParameterfvARB(target,index,(GLfloat*)params);

void
glGetProgramLocalParameterfvARB_s(target,index,params)
	GLenum	target
	GLint	index
	SV *	params
	INIT:
		loadProc(glGetProgramLocalParameterfvARB,"glGetProgramLocalParameterfvARB");
	CODE:
	{
		GLfloat * params_s = EL(params, sizeof(GLfloat) * 4);
		glGetProgramLocalParameterfvARB(target,index,params_s);
	}

void
glGetProgramLocalParameterfvARB_p(target,index)
	GLenum	target
	GLint	index
	INIT:
		loadProc(glGetProgramLocalParameterfvARB,"glGetProgramLocalParameterfvARB");
	PPCODE:
	{
		GLfloat params[4];
		glGetProgramLocalParameterfvARB(target,index,params);

		EXTEND(sp, 4);
		PUSHs(sv_2mortal(newSVnv(params[0])));
		PUSHs(sv_2mortal(newSVnv(params[1])));
		PUSHs(sv_2mortal(newSVnv(params[2])));
		PUSHs(sv_2mortal(newSVnv(params[3])));
	}

void
glGetProgramivARB_c(target,pname,params)
	GLenum	target
	GLenum	pname
	void *	params
	INIT:
		loadProc(glGetProgramivARB,"glGetProgramivARB");
	CODE:
		glGetProgramivARB(target,pname,params);

void
glGetProgramivARB_s(target,pname,params)
	GLenum	target
	GLenum	pname
	SV *	params
	INIT:
		loadProc(glGetProgramivARB,"glGetProgramivARB");
	CODE:
	{
		GLint * params_s = EL(params, sizeof(GLint)*gl_get_count(pname));
		glGetProgramivARB(target,pname,params_s);
	}

GLuint
glGetProgramivARB_p(target,pname)
	GLenum	target
	GLenum	pname
	INIT:
		loadProc(glGetProgramivARB,"glGetProgramivARB");
	CODE:
	{
		GLuint param;
		glGetProgramivARB(target,pname,(void *)&param);
		RETVAL = param;
	}
	OUTPUT:
		RETVAL

void
glGetProgramStringARB_c(target,pname,string)
	GLenum	target
	GLenum	pname
	void *	string
	INIT:
		loadProc(glGetProgramStringARB,"glGetProgramStringARB");
	CODE:
		glGetProgramStringARB(target,pname,string);

void
glGetProgramStringARB_s(target,pname,string)
	GLenum	target
	GLenum	pname
	SV *	string
	INIT:
		loadProc(glGetProgramivARB,"glGetProgramivARB");
		loadProc(glGetProgramStringARB,"glGetProgramStringARB");
	CODE:
	{
		GLint len;
		glGetProgramivARB(target,GL_PROGRAM_LENGTH_ARB,(GLvoid *)&len);
		if (len)
		{
			GLubyte * string_s = EL(string, sizeof(GLubyte)*len);
			glGetProgramStringARB(target,pname,string_s);
		}
	}

SV *
glGetProgramStringARB_p(target,pname=GL_PROGRAM_STRING_ARB)
	GLenum	target
	GLenum	pname
	INIT:
		loadProc(glGetProgramivARB,"glGetProgramivARB");
		loadProc(glGetProgramStringARB,"glGetProgramStringARB");
	CODE:
	{
		GLint len;
		glGetProgramivARB(target,GL_PROGRAM_LENGTH_ARB,(GLvoid *)&len);
		if (len)
		{
			char * string = malloc(len+1);
			glGetProgramStringARB(target,pname,(GLubyte*)string);
			string[len] = 0;
			if (*string)
				RETVAL = newSVpv(string, 0);
			else
				RETVAL = newSVsv(&PL_sv_undef);

			free(string);
		}
		else
		{
			RETVAL = newSVsv(&PL_sv_undef);
		}
	}
	OUTPUT:
		RETVAL

GLboolean
glIsProgramARB(program)
	GLuint	program
	INIT:
		loadProc(glIsProgramARB,"glIsProgramARB");
	CODE:
	{
		RETVAL = glIsProgramARB(program);
	}
	OUTPUT:
		RETVAL

#endif


#if defined(GL_ARB_vertex_program) || defined(GL_ARB_vertex_shader)

void
glVertexAttrib1dARB(index,x)
	GLuint index
	GLdouble x
	INIT:
		loadProc(glVertexAttrib1dARB,"glVertexAttrib1dARB");

void
glVertexAttrib1dvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib1dvARB,"glVertexAttrib1dvARB");
	CODE:
		glVertexAttrib1dvARB(index,(GLdouble*)v);

void
glVertexAttrib1dvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib1dvARB,"glVertexAttrib1dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*1);
		glVertexAttrib1dvARB(index,v_s);
	}

void
glVertexAttrib1dvARB_p(index,x)
	GLuint index
	GLdouble	x
	INIT:
		loadProc(glVertexAttrib1dvARB,"glVertexAttrib1dvARB");
	CODE:
	{
		GLdouble param[1];
		param[0] = x;
		glVertexAttrib1dvARB(index,param);
	}

void
glVertexAttrib1fARB(index,x)
	GLuint index
	GLfloat x
	INIT:
		loadProc(glVertexAttrib1fARB,"glVertexAttrib1fARB");

void
glVertexAttrib1sARB(index,x)
	GLuint index
	GLshort x
	INIT:
		loadProc(glVertexAttrib1s,"glVertexAttrib1s");

void
glVertexAttrib1svARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib1svARB,"glVertexAttrib1svARB");
	CODE:
		glVertexAttrib1svARB(index,(GLshort*)v);

void
glVertexAttrib1svARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib1svARB,"glVertexAttrib1svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*1);
		glVertexAttrib1svARB(index,v_s);
	}

void
glVertexAttrib1svARB_p(index,x)
	GLuint index
	GLshort	x
	INIT:
		loadProc(glVertexAttrib1svARB,"glVertexAttrib1svARB");
	CODE:
	{
		GLshort param[1];
		param[0] = x;
		glVertexAttrib1svARB(index,param);
	}

void
glVertexAttrib2dARB(index,x,y)
	GLuint index
	GLdouble x
	GLdouble y
	INIT:
		loadProc(glVertexAttrib2dARB,"glVertexAttrib2dARB");

void
glVertexAttrib2dvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib2dvARB,"glVertexAttrib2dvARB");
	CODE:
		glVertexAttrib2dvARB(index,(GLdouble*)v);

void
glVertexAttrib2dvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib2dvARB,"glVertexAttrib2dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*2);
		glVertexAttrib2dvARB(index,v_s);
	}

void
glVertexAttrib2dvARB_p(index,x,y)
	GLuint index
	GLdouble	x
	GLdouble	y
	INIT:
		loadProc(glVertexAttrib2dvARB,"glVertexAttrib2dvARB");
	CODE:
	{
		GLdouble param[2];
		param[0] = x;
		param[1] = y;
		glVertexAttrib2dvARB(index,param);
	}

void
glVertexAttrib2fARB(index,x,y)
	GLuint index
	GLfloat x
	GLfloat y
	INIT:
		loadProc(glVertexAttrib2fARB,"glVertexAttrib2fARB");

void
glVertexAttrib2sARB(index,x,y)
	GLuint index
	GLshort x
	GLshort y
	INIT:
		loadProc(glVertexAttrib2sARB,"glVertexAttrib2sARB");

void
glVertexAttrib2svARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib2svARB,"glVertexAttrib2svARB");
	CODE:
		glVertexAttrib2svARB(index,(GLshort*)v);

void
glVertexAttrib2svARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib2svARB,"glVertexAttrib2svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*2);
		glVertexAttrib2svARB(index,v_s);
	}

void
glVertexAttrib2svARB_p(index,x,y)
	GLuint index
	GLshort	x
	GLshort	y
	INIT:
		loadProc(glVertexAttrib2svARB,"glVertexAttrib2svARB");
	CODE:
	{
		GLshort param[2];
		param[0] = x;
		param[1] = y;
		glVertexAttrib2svARB(index,param);
	}

void
glVertexAttrib3dARB(index,x,y,z)
	GLuint index
	GLdouble x
	GLdouble y
	GLdouble z
	INIT:
		loadProc(glVertexAttrib3dARB,"glVertexAttrib3dARB");

void
glVertexAttrib3dvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib3dvARB,"glVertexAttrib3dvARB");
	CODE:
		glVertexAttrib3dvARB(index,(GLdouble*)v);

void
glVertexAttrib3dvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib3dvARB,"glVertexAttrib3dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*3);
		glVertexAttrib3dvARB(index,v_s);
	}

void
glVertexAttrib3dvARB_p(index,x,y,z)
	GLuint index
	GLdouble	x
	GLdouble	y
	GLdouble	z
	INIT:
		loadProc(glVertexAttrib3dvARB,"glVertexAttrib3dvARB");
	CODE:
	{
		GLdouble param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertexAttrib3dvARB(index,param);
	}

void
glVertexAttrib3fARB(index,x,y,z)
	GLuint index
	GLfloat x
	GLfloat y
	GLfloat z
	INIT:
		loadProc(glVertexAttrib3fARB,"glVertexAttrib3fARB");

void
glVertexAttrib3fvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib3fvARB,"glVertexAttrib3fvARB");
	CODE:
		glVertexAttrib3fvARB(index,(GLfloat*)v);

void
glVertexAttrib3fvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib3fvARB,"glVertexAttrib3fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*3);
		glVertexAttrib3fvARB(index,v_s);
	}

void
glVertexAttrib3fvARB_p(index,x,y,z)
	GLuint index
	GLfloat	x
	GLfloat	y
	GLfloat	z
	INIT:
		loadProc(glVertexAttrib3fvARB,"glVertexAttrib3fvARB");
	CODE:
	{
		GLfloat param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertexAttrib3fvARB(index,param);
	}

void
glVertexAttrib3sARB(index,x,y,z)
	GLuint index
	GLshort x
	GLshort y
	GLshort z
	INIT:
		loadProc(glVertexAttrib3sARB,"glVertexAttrib3sARB");

void
glVertexAttrib3svARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib3svARB,"glVertexAttrib3svARB");
	CODE:
		glVertexAttrib3svARB(index,(GLshort*)v);

void
glVertexAttrib3svARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib3svARB,"glVertexAttrib3svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*3);
		glVertexAttrib3svARB(index,v_s);
	}

void
glVertexAttrib3svARB_p(index,x,y,z)
	GLuint index
	GLshort	x
	GLshort	y
	GLshort	z
	INIT:
		loadProc(glVertexAttrib3svARB,"glVertexAttrib3svARB");
	CODE:
	{
		GLshort param[3];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		glVertexAttrib3svARB(index,param);
	}

void
glVertexAttrib4NbvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4NbvARB,"glVertexAttrib4NbvARB");
	CODE:
		glVertexAttrib4NbvARB(index,(GLbyte*)v);

void
glVertexAttrib4NbvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4NbvARB,"glVertexAttrib4NbvARB");
	CODE:
	{
		GLbyte * v_s = EL(v, sizeof(GLbyte)*4);
		glVertexAttrib4NbvARB(index,v_s);
	}

void
glVertexAttrib4NbvARB_p(index,x,y,z,w)
	GLuint index
	GLbyte	x
	GLbyte	y
	GLbyte	z
	GLbyte	w
	INIT:
		loadProc(glVertexAttrib4NbvARB,"glVertexAttrib4NbvARB");
	CODE:
	{
		GLbyte param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4NbvARB(index,param);
	}

void
glVertexAttrib4NivARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4NivARB,"glVertexAttrib4NivARB");
	CODE:
		glVertexAttrib4NivARB(index,(GLint*)v);

void
glVertexAttrib4NivARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4NivARB,"glVertexAttrib4NivARB");
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*4);
		glVertexAttrib4NivARB(index,v_s);
	}

void
glVertexAttrib4NivARB_p(index,x,y,z,w)
	GLuint index
	GLint	x
	GLint	y
	GLint	z
	GLint	w
	INIT:
		loadProc(glVertexAttrib4NivARB,"glVertexAttrib4NivARB");
	CODE:
	{
		GLint param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4NivARB(index,param);
	}

void
glVertexAttrib4NsvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4NsvARB,"glVertexAttrib4NsvARB");
	CODE:
		glVertexAttrib4NsvARB(index,(GLshort*)v);

void
glVertexAttrib4NsvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4NsvARB,"glVertexAttrib4NsvARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*4);
		glVertexAttrib4NsvARB(index,v_s);
	}

void
glVertexAttrib4NsvARB_p(index,x,y,z,w)
	GLuint index
	GLshort	x
	GLshort	y
	GLshort	z
	GLshort	w
	INIT:
		loadProc(glVertexAttrib4NsvARB,"glVertexAttrib4NsvARB");
	CODE:
	{
		GLshort param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4NsvARB(index,param);
	}

void
glVertexAttrib4NubARB(index,x,y,z,w)
	GLuint index
	GLubyte x
	GLubyte y
	GLubyte z
	GLubyte w
	INIT:
		loadProc(glVertexAttrib4NubARB,"glVertexAttrib4NubARB");

void
glVertexAttrib4NubvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4NubvARB,"glVertexAttrib4NubvARB");
	CODE:
		glVertexAttrib4NubvARB(index,(GLubyte*)v);

void
glVertexAttrib4NubvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4NubvARB,"glVertexAttrib4NubvARB");
	CODE:
	{
		GLubyte * v_s = EL(v, sizeof(GLubyte)*4);
		glVertexAttrib4NubvARB(index,v_s);
	}

void
glVertexAttrib4NubvARB_p(index,x,y,z,w)
	GLuint index
	GLubyte	x
	GLubyte	y
	GLubyte	z
	GLubyte	w
	INIT:
		loadProc(glVertexAttrib4NubvARB,"glVertexAttrib4NubvARB");
	CODE:
	{
		GLubyte param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4NubvARB(index,param);
	}

void
glVertexAttrib4NuivARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4NuivARB,"glVertexAttrib4NuivARB");
	CODE:
		glVertexAttrib4NuivARB(index,(GLuint*)v);

void
glVertexAttrib4NuivARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4NuivARB,"glVertexAttrib4NuivARB");
	CODE:
	{
		GLuint * v_s = EL(v, sizeof(GLuint)*4);
		glVertexAttrib4NuivARB(index,v_s);
	}

void
glVertexAttrib4NuivARB_p(index,x,y,z,w)
	GLuint index
	GLuint	x
	GLuint	y
	GLuint	z
	GLuint	w
	INIT:
		loadProc(glVertexAttrib4NuivARB,"glVertexAttrib4NuivARB");
	CODE:
	{
		GLuint param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4NuivARB(index,param);
	}

void
glVertexAttrib4NusvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4NusvARB,"glVertexAttrib4NusvARB");
	CODE:
		glVertexAttrib4NusvARB(index,(GLushort*)v);

void
glVertexAttrib4NusvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4NusvARB,"glVertexAttrib4NusvARB");
	CODE:
	{
		GLushort * v_s = EL(v, sizeof(GLushort)*4);
		glVertexAttrib4NusvARB(index,v_s);
	}

void
glVertexAttrib4NusvARB_p(index,x,y,z,w)
	GLuint index
	GLushort	x
	GLushort	y
	GLushort	z
	GLushort	w
	INIT:
		loadProc(glVertexAttrib4NusvARB,"glVertexAttrib4NusvARB");
	CODE:
	{
		GLushort param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4NusvARB(index,param);
	}

void
glVertexAttrib4bvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4bvARB,"glVertexAttrib4bvARB");
	CODE:
		glVertexAttrib4bvARB(index,(GLbyte*)v);

void
glVertexAttrib4bvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4bvARB,"glVertexAttrib4bvARB");
	CODE:
	{
		GLbyte * v_s = EL(v, sizeof(GLbyte)*4);
		glVertexAttrib4bvARB(index,v_s);
	}

void
glVertexAttrib4bvARB_p(index,x,y,z,w)
	GLuint index
	GLbyte	x
	GLbyte	y
	GLbyte	z
	GLbyte	w
	INIT:
		loadProc(glVertexAttrib4bvARB,"glVertexAttrib4bvARB");
	CODE:
	{
		GLbyte param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4bvARB(index,param);
	}

void
glVertexAttrib4dARB(index,x,y,z,w)
	GLuint index
	GLdouble x
	GLdouble y
	GLdouble z
	GLdouble w
	INIT:
		loadProc(glVertexAttrib4dARB,"glVertexAttrib4dARB");

void
glVertexAttrib4dvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4dvARB,"glVertexAttrib4dvARB");
	CODE:
		glVertexAttrib4dvARB(index,(GLdouble*)v);

void
glVertexAttrib4dvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4dvARB,"glVertexAttrib4dvARB");
	CODE:
	{
		GLdouble * v_s = EL(v, sizeof(GLdouble)*4);
		glVertexAttrib4dvARB(index,v_s);
	}

void
glVertexAttrib4dvARB_p(index,x,y,z,w)
	GLuint index
	GLdouble	x
	GLdouble	y
	GLdouble	z
	GLdouble	w
	INIT:
		loadProc(glVertexAttrib4dvARB,"glVertexAttrib4dvARB");
	CODE:
	{
		GLdouble param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4dvARB(index,param);
	}

void
glVertexAttrib4fARB(index,x,y,z,w)
	GLuint index
	GLfloat x
	GLfloat y
	GLfloat z
	GLfloat w
	INIT:
		loadProc(glVertexAttrib4fARB,"glVertexAttrib4fARB");

void
glVertexAttrib4fvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4fvARB,"glVertexAttrib4fvARB");
	CODE:
		glVertexAttrib4fvARB(index,(GLfloat*)v);

void
glVertexAttrib4fvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4fvARB,"glVertexAttrib4fvARB");
	CODE:
	{
		GLfloat * v_s = EL(v, sizeof(GLfloat)*4);
		glVertexAttrib4fvARB(index,v_s);
	}

void
glVertexAttrib4fvARB_p(index,x,y,z,w)
	GLuint index
	GLfloat	x
	GLfloat	y
	GLfloat	z
	GLfloat	w
	INIT:
		loadProc(glVertexAttrib4fvARB,"glVertexAttrib4fvARB");
	CODE:
	{
		GLfloat param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4fvARB(index,param);
	}

void
glVertexAttrib4ivARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4ivARB,"glVertexAttrib4ivARB");
	CODE:
		glVertexAttrib4ivARB(index,(GLint*)v);

void
glVertexAttrib4ivARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4ivARB,"glVertexAttrib4ivARB");
	CODE:
	{
		GLint * v_s = EL(v, sizeof(GLint)*4);
		glVertexAttrib4ivARB(index,v_s);
	}

void
glVertexAttrib4ivARB_p(index,x,y,z,w)
	GLuint index
	GLint	x
	GLint	y
	GLint	z
	GLint	w
	INIT:
		loadProc(glVertexAttrib4ivARB,"glVertexAttrib4ivARB");
	CODE:
	{
		GLint param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4ivARB(index,param);
	}

void
glVertexAttrib4sARB(index,x,y,z,w)
	GLuint index
	GLshort x
	GLshort y
	GLshort z
	GLshort w
	INIT:
		loadProc(glVertexAttrib4sARB,"glVertexAttrib4sARB");

void
glVertexAttrib4svARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4svARB,"glVertexAttrib4svARB");
	CODE:
		glVertexAttrib4svARB(index,(GLshort*)v);

void
glVertexAttrib4svARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4svARB,"glVertexAttrib4svARB");
	CODE:
	{
		GLshort * v_s = EL(v, sizeof(GLshort)*4);
		glVertexAttrib4svARB(index,v_s);
	}

void
glVertexAttrib4svARB_p(index,x,y,z,w)
	GLuint index
	GLshort	x
	GLshort	y
	GLshort	z
	GLshort	w
	INIT:
		loadProc(glVertexAttrib4svARB,"glVertexAttrib4svARB");
	CODE:
	{
		GLshort param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4svARB(index,param);
	}

void
glVertexAttrib4ubvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4ubvARB,"glVertexAttrib4ubvARB");
	CODE:
		glVertexAttrib4ubvARB(index,(GLubyte*)v);

void
glVertexAttrib4ubvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4ubvARB,"glVertexAttrib4ubvARB");
	CODE:
	{
		GLubyte * v_s = EL(v, sizeof(GLubyte)*4);
		glVertexAttrib4ubvARB(index,v_s);
	}

void
glVertexAttrib4ubvARB_p(index,x,y,z,w)
	GLuint index
	GLubyte	x
	GLubyte	y
	GLubyte	z
	GLubyte	w
	INIT:
		loadProc(glVertexAttrib4ubvARB,"glVertexAttrib4ubvARB");
	CODE:
	{
		GLubyte param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4ubvARB(index,param);
	}

void
glVertexAttrib4uivARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4uivARB,"glVertexAttrib4uivARB");
	CODE:
		glVertexAttrib4uivARB(index,(GLuint*)v);

void
glVertexAttrib4uivARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4uivARB,"glVertexAttrib4uivARB");
	CODE:
	{
		GLuint * v_s = EL(v, sizeof(GLuint)*4);
		glVertexAttrib4uivARB(index,v_s);
	}

void
glVertexAttrib4uivARB_p(index,x,y,z,w)
	GLuint index
	GLuint	x
	GLuint	y
	GLuint	z
	GLuint	w
	INIT:
		loadProc(glVertexAttrib4uivARB,"glVertexAttrib4uivARB");
	CODE:
	{
		GLuint param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4uivARB(index,param);
	}

void
glVertexAttrib4usvARB_c(index,v)
	GLuint index
	void *	v
	INIT:
		loadProc(glVertexAttrib4usvARB,"glVertexAttrib4usvARB");
	CODE:
		glVertexAttrib4usvARB(index,(GLushort*)v);

void
glVertexAttrib4usvARB_s(index,v)
	GLuint index
	SV *	v
	INIT:
		loadProc(glVertexAttrib4usvARB,"glVertexAttrib4usvARB");
	CODE:
	{
		GLushort * v_s = EL(v, sizeof(GLushort)*4);
		glVertexAttrib4usvARB(index,v_s);
	}

void
glVertexAttrib4usvARB_p(index,x,y,z,w)
	GLuint index
	GLushort	x
	GLushort	y
	GLushort	z
	GLushort	w
	INIT:
		loadProc(glVertexAttrib4usvARB,"glVertexAttrib4usvARB");
	CODE:
	{
		GLushort param[4];
		param[0] = x;
		param[1] = y;
		param[2] = z;
		param[3] = w;
		glVertexAttrib4usvARB(index,param);
	}

void
glVertexAttribPointerARB_c(index,size,type,normalized,stride,pointer)
	GLuint index
	GLint size
	GLenum type
	GLboolean normalized
	GLsizei stride
	void * pointer
	INIT:
		loadProc(glVertexAttribPointerARB,"glVertexAttribPointerARB");
	CODE:
		glVertexAttribPointerARB(index,size,type,
			normalized,stride,pointer);

void
glVertexAttribPointerARB_p(index,type,normalized,stride,...)
	GLuint index
	GLenum type
	GLboolean normalized
	GLsizei stride
	INIT:
		loadProc(glVertexAttribPointerARB,"glVertexAttribPointerARB");
	CODE:
	{
		GLuint count = items - 4;
		GLuint size = gl_type_size(type);
		void * pointer = malloc(count * size);

		SvItems(type,4,count,pointer);

		glVertexAttribPointerARB(index,count,type,
			normalized,stride,pointer);

		free(pointer);
	}

void
glEnableVertexAttribArrayARB(index)
	GLuint index
	INIT:
		loadProc(glEnableVertexAttribArrayARB,"glEnableVertexAttribArrayARB");

void
glDisableVertexAttribArrayARB(index)
	GLuint index
	INIT:
		loadProc(glDisableVertexAttribArrayARB,"glDisableVertexAttribArrayARB");

void
glGetVertexAttribdvARB_c(index,pname,params)
	GLuint	index
	GLenum	pname
	void *	params
	INIT:
		loadProc(glGetVertexAttribdvARB,"glGetVertexAttribdvARB");
	CODE:
		glGetVertexAttribdvARB(index,pname,(GLdouble*)params);

void
glGetVertexAttribdvARB_s(index,pname,params)
	GLuint	index
	GLenum	pname
	SV *	params
	INIT:
		loadProc(glGetVertexAttribdvARB,"glGetVertexAttribdvARB");
	CODE:
	{
		GLdouble * params_s = EL(params, sizeof(GLdouble) * 4);
		glGetVertexAttribdvARB(index,pname,params_s);
	}

GLdouble
glGetVertexAttribdvARB_p(index,pname)
	GLuint	index
	GLenum	pname
	INIT:
		loadProc(glGetVertexAttribdvARB,"glGetVertexAttribdvARB");
	CODE:
	{
		GLdouble param;
		glGetVertexAttribdvARB(index,pname,(void *)&param);
		RETVAL = param;
	}
	OUTPUT:
		RETVAL

void
glGetVertexAttribfvARB_c(index,pname,params)
	GLuint	index
	GLenum	pname
	void *	params
	INIT:
		loadProc(glGetVertexAttribfvARB,"glGetVertexAttribfvARB");
	CODE:
		glGetVertexAttribfvARB(index,pname,(GLfloat*)params);

void
glGetVertexAttribfvARB_s(index,pname,params)
	GLuint	index
	GLenum	pname
	SV *	params
	INIT:
		loadProc(glGetVertexAttribfvARB,"glGetVertexAttribfvARB");
	CODE:
	{
		GLfloat * params_s = EL(params, sizeof(GLfloat) * 4);
		glGetVertexAttribfvARB(index,pname,params_s);
	}

GLfloat
glGetVertexAttribfvARB_p(index,pname)
	GLuint	index
	GLenum	pname
	INIT:
		loadProc(glGetVertexAttribfvARB,"glGetVertexAttribfvARB");
	CODE:
	{
		GLfloat param;
		glGetVertexAttribfvARB(index,pname,(void *)&param);
		RETVAL = param;
	}
	OUTPUT:
		RETVAL

void
glGetVertexAttribivARB_c(index,pname,params)
	GLuint	index
	GLenum	pname
	void *	params
	INIT:
		loadProc(glGetVertexAttribivARB,"glGetVertexAttribivARB");
	CODE:
		glGetVertexAttribivARB(index,pname,(GLint*)params);

void
glGetVertexAttribivARB_s(index,pname,params)
	GLuint	index
	GLenum	pname
	SV *	params
	INIT:
		loadProc(glGetVertexAttribivARB,"glGetVertexAttribivARB");
	CODE:
	{
		GLint * params_s = EL(params, sizeof(GLint) * 4);
		glGetVertexAttribivARB(index,pname,params_s);
	}

GLuint
glGetVertexAttribivARB_p(index,pname)
	GLuint	index
	GLenum	pname
	INIT:
		loadProc(glGetVertexAttribivARB,"glGetVertexAttribivARB");
	CODE:
	{
		GLuint param;
		glGetVertexAttribivARB(index,pname,(void *)&param);
		RETVAL = param;
	}
	OUTPUT:
		RETVAL

void
glGetVertexAttribPointervARB_c(index,pname,pointer)
	GLuint	index
	GLenum	pname
	void *	pointer
	INIT:
		loadProc(glGetVertexAttribPointervARB,"glGetVertexAttribPointervARB");
	CODE:
		glGetVertexAttribPointervARB(index,pname,pointer);

void
glGetVertexAttribPointervARB_p(index,pname)
	GLuint	index
	GLenum	pname
	INIT:
		loadProc(glGetVertexAttribPointervARB,"glGetVertexAttribPointervARB");
		loadProc(glGetVertexAttribivARB,"glGetVertexAttribivARB");
	PPCODE:
	{
		void * pointer;
		GLuint i,count,type;

		glGetVertexAttribPointervARB(index,pname,&pointer);

		glGetVertexAttribivARB(index,GL_VERTEX_ATTRIB_ARRAY_SIZE_ARB,(void *)&count);
		glGetVertexAttribivARB(index,GL_VERTEX_ATTRIB_ARRAY_TYPE_ARB,(void *)&type);

		EXTEND(sp, count);

		switch (type)
		{
#ifdef GL_VERSION_1_2
			case GL_UNSIGNED_BYTE_3_3_2:
			case GL_UNSIGNED_BYTE_2_3_3_REV:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLubyte*)pointer)[i])));
				}
				break;
			case GL_UNSIGNED_SHORT_5_6_5:
			case GL_UNSIGNED_SHORT_5_6_5_REV:
			case GL_UNSIGNED_SHORT_4_4_4_4:
			case GL_UNSIGNED_SHORT_4_4_4_4_REV:
			case GL_UNSIGNED_SHORT_5_5_5_1:
			case GL_UNSIGNED_SHORT_1_5_5_5_REV:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLushort*)pointer)[i])));
				}
				break;
			case GL_UNSIGNED_INT_8_8_8_8:
			case GL_UNSIGNED_INT_8_8_8_8_REV:
			case GL_UNSIGNED_INT_10_10_10_2:
			case GL_UNSIGNED_INT_2_10_10_10_REV:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLuint*)pointer)[i])));
				}
				break;
#endif
			case GL_UNSIGNED_BYTE:
			case GL_BITMAP:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLubyte*)pointer)[i])));
				}
				break;
			case GL_BYTE:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLbyte*)pointer)[i])));
				}
				break;
			case GL_UNSIGNED_SHORT:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLushort*)pointer)[i])));
				}
				break;
			case GL_SHORT:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLushort*)pointer)[i])));
				}
				break;
			case GL_UNSIGNED_INT:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLuint*)pointer)[i])));
				}
				break;
			case GL_INT:
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSViv(((GLint*)pointer)[i])));
				}
				break;
			case GL_FLOAT: 
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSVnv(((GLfloat*)pointer)[i])));
				}
				break;
			case GL_DOUBLE: 
				for (i=0;i<count;i++)
				{
				  PUSHs(sv_2mortal(newSVnv(((GLdouble*)pointer)[i])));
				}
				break;
			default:
				croak("unknown type");
		}
	}

#endif


#ifdef GL_ARB_vertex_shader

void
glBindAttribLocationARB(programObj, index, name)
	GLhandleARB programObj
	GLuint index
	void *name
	INIT:
		loadProc(glBindAttribLocationARB,"glBindAttribLocationARB");
	CODE:
		glBindAttribLocationARB(programObj,index,name);

void
glGetActiveAttribARB_c(programObj, index, maxLength, length, size, type, name)
	GLhandleARB programObj
	GLuint	index
	GLsizei	maxLength
	void	*length
	void	*size
	void	*type
	void	*name
	INIT:
		loadProc(glGetActiveAttribARB,"glGetActiveAttribARB");
	CODE:
		glGetActiveAttribARB(programObj,index,maxLength,length,size,type,name);

void
glGetActiveAttribARB_s(programObj, index, maxLength, length, size, type, name)
	GLhandleARB programObj
	GLuint	index
	GLsizei	maxLength
	SV	*length
	SV	*size
	SV	*type
	SV	*name
	INIT:
		loadProc(glGetActiveAttribARB,"glGetActiveAttribARB");
	CODE:
	{
		GLsizei	  *length_s = EL(length, sizeof(GLsizei));
		GLint	  *size_s = EL(size, sizeof(GLint));
		GLenum	  *type_s = EL(type, sizeof(GLenum));
		GLcharARB *name_s = EL(name, sizeof(GLcharARB));
		glGetActiveAttribARB(programObj,index,maxLength,length_s,size_s,type_s,name_s);
	}

void
glGetActiveAttribARB_p(programObj, index)
	GLhandleARB programObj
	GLuint index
	INIT:
		loadProc(glGetObjectParameterivARB,"glGetObjectParameterivARB");
		loadProc(glGetActiveAttribARB,"glGetActiveAttribARB");
	PPCODE:
	{
		GLsizei maxLength;
		glGetObjectParameterivARB(programObj,GL_OBJECT_ACTIVE_ATTRIBUTES_ARB,
			(GLvoid *)&maxLength);
		if (maxLength)
		{
			GLsizei length;
			GLint size;
			GLenum type;
			GLcharARB *name;

			name = malloc(maxLength+1);
			glGetActiveAttribARB(programObj,index,maxLength,
				&length,&size,&type,name);
			name[length] = 0;

			if (*name)
			{
				EXTEND(sp,3);
				PUSHs(sv_2mortal(newSVpv(name,0)));
				PUSHs(sv_2mortal(newSViv(type)));
				PUSHs(sv_2mortal(newSViv(size)));
			}
			else
			{
				EXTEND(sp,1);
				PUSHs(sv_2mortal(newSVsv(&PL_sv_undef)));
			}

			free(name);
		}
		else
		{
			EXTEND(sp,1);
			PUSHs(sv_2mortal(newSVsv(&PL_sv_undef)));
		}
	}

GLint
glGetAttribLocationARB_c(programObj, name)
	GLhandleARB programObj
	void	*name
	INIT:
		loadProc(glGetAttribLocationARB,"glGetAttribLocationARB");
	CODE:
		RETVAL = glGetAttribLocationARB(programObj, name);
	OUTPUT:
		RETVAL

GLint
glGetAttribLocationARB_p(programObj, ...)
	GLhandleARB programObj
	INIT:
		loadProc(glGetAttribLocationARB,"glGetAttribLocationARB");
	CODE:
	{
		GLcharARB *name = (GLcharARB *)SvPV(ST(1),PL_na);
		RETVAL = glGetAttribLocationARB(programObj, name);
	}
	OUTPUT:
		RETVAL

#endif



#endif /* HAVE_GL */

##################### GLU #########################

#ifdef HAVE_GLU

void
gluBeginCurve(nurb)
	GLUnurbsObj *	nurb

void
gluEndCurve(nurb)
	GLUnurbsObj *	nurb

void
gluBeginPolygon(tess)
	PGLUtess *	tess
	CODE:
	gluBeginPolygon(tess->triangulator);

void
gluEndPolygon(tess)
	PGLUtess *	tess
	CODE:
	gluEndPolygon(tess->triangulator);

void
gluBeginSurface(nurb)
	GLUnurbsObj *	nurb

void
gluEndSurface(nurb)
	GLUnurbsObj *	nurb

void
gluBeginTrim(nurb)
	GLUnurbsObj *	nurb

void
gluEndTrim(nurb)
	GLUnurbsObj *	nurb

GLint
gluBuild1DMipmaps_c(target, internalformat, width, format, type, data)
	GLenum	target
	GLuint	internalformat
	GLsizei	width
	GLenum	format
	GLenum	type
	void *	data
	CODE:
	{
		RETVAL=gluBuild1DMipmaps(target, internalformat,
			width, format, type, data);
	}
	OUTPUT:
	  RETVAL

GLint
gluBuild1DMipmaps_s(target, internalformat, width, format, type, data)
	GLenum	target
	GLuint	internalformat
	GLsizei	width
	GLenum	format
	GLenum	type
	SV *	data
	CODE:
	{
	GLvoid * ptr = ELI(data, width, 1, format, type, gl_pixelbuffer_unpack);
	RETVAL=gluBuild1DMipmaps(target, internalformat, width, format, type, ptr);
	}
	OUTPUT:
	  RETVAL

GLint
gluBuild2DMipmaps_c(target, internalformat, width, height, format, type, data)
	GLenum	target
	GLuint	internalformat
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	void *	data
	CODE:
	{
		RETVAL=gluBuild2DMipmaps(target, internalformat,
			width, height, format, type, data);
	}
	OUTPUT:
	  RETVAL

GLint
gluBuild2DMipmaps_s(target, internalformat, width, height, format, type, data)
	GLenum	target
	GLuint	internalformat
	GLsizei	width
	GLsizei	height
	GLenum	format
	GLenum	type
	SV *	data
	CODE:
	{
	GLvoid * ptr = ELI(data, width, height, format, type, gl_pixelbuffer_unpack);
	RETVAL=gluBuild2DMipmaps(target, internalformat, width, height, format, type, ptr);
	}
	OUTPUT:
	  RETVAL

void
gluCylinder(quad, base, top, height, slices, stacks)
	GLUquadricObj *	quad
	GLdouble	base
	GLdouble	top
	GLdouble	height
	GLint	slices
	GLint	stacks

void
gluDeleteNurbsRenderer(nurb)
	GLUnurbsObj *	nurb

void
gluDeleteQuadric(quad)
	GLUquadricObj *	quad

void
gluDeleteTess(tess)
	PGLUtess *	tess
	CODE:
	{
		if (tess->triangulator)
			gluDeleteTess(tess->triangulator);
#ifdef GLU_VERSION_1_2
		if (tess->polygon_data_av)
			SvREFCNT_dec(tess->polygon_data_av);
		if (tess->begin_callback)
			SvREFCNT_dec(tess->begin_callback);
		if (tess->edgeFlag_callback)
			SvREFCNT_dec(tess->edgeFlag_callback);
		if (tess->vertex_callback)
			SvREFCNT_dec(tess->vertex_callback);
		if (tess->end_callback)
			SvREFCNT_dec(tess->end_callback);
		if (tess->error_callback)
			SvREFCNT_dec(tess->error_callback);
		if (tess->combine_callback)
			SvREFCNT_dec(tess->combine_callback);
		if (tess->vertex_datas)
			SvREFCNT_dec(tess->vertex_datas);
#endif
		free(tess);
	}

void
gluDisk(quad, inner, outer, slices, loops)
	GLUquadricObj *	quad
	GLdouble	inner
	GLdouble	outer
	GLint	slices
	GLint	loops

char *
gluErrorString(error)
	GLenum	error
	CODE:
	RETVAL = (char*)gluErrorString(error);
	OUTPUT:
	RETVAL

GLfloat
gluGetNurbsProperty_p(nurb, property)
	GLUnurbsObj *	nurb
	GLenum	property
	CODE:
	{
		GLfloat param;
		gluGetNurbsProperty(nurb, property, &param);
		RETVAL = param;
	}
	OUTPUT:
	RETVAL
	
void
gluNurbsProperty(nurb, property, value)
	GLUnurbsObj *	nurb
	GLenum	property
	GLfloat value

#ifdef GLU_VERSION_1_1

char *
gluGetString(name)
	GLenum	name
	CODE:
	RETVAL = (char*)gluGetString(name);
	OUTPUT:
	RETVAL

#endif


void
gluLoadSamplingMatrices_p(nurb, m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12,m13,m14,m15,m16, o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11,o12,o13,o14,o15,o16, v1,v2,v3,v4)
	GLUnurbsObj *	nurb
	CODE:
	{
		GLfloat m[16], p[16];
		GLint v[4];
		int i;
		for (i=0;i<16;i++)
			m[i] = SvIV(ST(i+1));
		for (i=0;i<16;i++)
			p[i] = SvIV(ST(i+1+16));
		for (i=0;i<4;i++)
			v[i] = SvIV(ST(i+1+16+16));
		gluLoadSamplingMatrices(nurb, m, p, v);
	}

void
gluLookAt(eyeX, eyeY, eyeZ, centerX, centerY, centerZ, upX, upY, upZ)
	GLdouble	eyeX
	GLdouble	eyeY
	GLdouble	eyeZ
	GLdouble	centerX
	GLdouble	centerY
	GLdouble	centerZ
	GLdouble	upX
	GLdouble	upY
	GLdouble	upZ

GLUnurbsObj *
gluNewNurbsRenderer()

GLUquadricObj *
gluNewQuadric()

PGLUtess *
gluNewTess()
	CODE:
	{
		RETVAL = calloc(sizeof(PGLUtess), 1);
		RETVAL->triangulator = gluNewTess();
	}
	OUTPUT:
	RETVAL

void
gluNextContour(tess, type)
	PGLUtess *	tess
	GLenum	type
	CODE:
	gluNextContour(tess->triangulator, type);

void
gluNurbsCurve_c(nurb, nknots, knot, stride, ctlarray, order, type)
	GLUnurbsObj *	nurb
	GLint	nknots
	void *	knot
	GLint	stride
	void *	ctlarray
	GLint	order
	GLenum	type
	CODE:
	gluNurbsCurve(nurb, nknots, knot, stride, ctlarray, order, type);

void
gluNurbsSurface_c(nurb, sknot_count, sknot, tknot_count, tknot, s_stride, t_stride, ctrlarray, sorder, torder, type)
	GLUnurbsObj *	nurb
	GLint	sknot_count
	void *	sknot
	GLint	tknot_count
	void *	tknot
	GLint	s_stride
	GLint	t_stride
	void *	ctrlarray
	GLint	sorder
	GLint	torder
	GLenum	type
	CODE:
	gluNurbsSurface(nurb, sknot_count, sknot, tknot_count, tknot, s_stride, t_stride, ctrlarray, sorder, torder, type);

void
gluOrtho2D(left, right, bottom, top)
	GLdouble	left
	GLdouble	right
	GLdouble	bottom
	GLdouble	top

void
gluPartialDisk(quad, inner, outer, slices, loops, start, sweep)
	GLUquadricObj*	quad
	GLdouble	inner
	GLdouble	outer
	GLint	slices
	GLint	loops
	GLdouble	start
	GLdouble	sweep

void
gluPerspective(fovy, aspect, zNear, zFar)
	GLdouble	fovy
	GLdouble	aspect
	GLdouble	zNear
	GLdouble	zFar

void
gluPickMatrix_p(x, y, delX, delY, m1,m2,m3,m4)
	GLdouble	x
	GLdouble	y
	GLdouble	delX
	GLdouble	delY
	CODE:
	{
		GLint m[4];
		int i;
		for (i=0;i<4;i++)
			m[i] = SvIV(ST(i+4));
		gluPickMatrix(x, y, delX, delY, &m[0]);
	}

void
gluProject_p(objx, objy, objz, m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12,m13,m14,m15,m16, o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11,o12,o13,o14,o15,o16, v1,v2,v3,v4)
	GLdouble	objx
	GLdouble	objy
	GLdouble	objz
	PPCODE:
	{
		GLdouble m[16], p[16], winx, winy, winz;
		GLint v[4];
		int i;
		for (i=0;i<16;i++)
			m[i] = SvIV(ST(i+3));
		for (i=0;i<16;i++)
			p[i] = SvIV(ST(i+3+16));
		for (i=0;i<4;i++)
			v[i] = SvIV(ST(i+3+16+16));
		i = gluProject(objx, objy, objz, m, p, v, &winx, &winy, &winz);
		if (i) {
			EXTEND(sp, 3);
			PUSHs(sv_2mortal(newSVnv(winx)));
			PUSHs(sv_2mortal(newSVnv(winy)));
			PUSHs(sv_2mortal(newSVnv(winz)));
		}
	}

void
gluPwlCurve_c(nurb, count, data, stride, type)
	GLUnurbsObj *	nurb
	GLint	count
	void *	data
	GLint	stride
	GLenum	type
	CODE:
	gluPwlCurve(nurb, count, data, stride, type);


void
gluQuadricDrawStyle(quad, draw)
	GLUquadricObj *	quad
	GLenum	draw

void
gluQuadricNormals(quad, normal)
	GLUquadricObj *	quad
	GLenum	normal

void
gluQuadricOrientation(quad, orientation)
	GLUquadricObj *	quad
	GLenum	orientation

void
gluQuadricTexture(quad, texture)
	GLUquadricObj *	quad
	GLboolean	texture

GLint
gluScaleImage_s(format, wIn, hIn, typeIn, dataIn, wOut, hOut, typeOut, dataOut)
	GLenum	format
	GLsizei	wIn
	GLsizei	hIn
	GLenum	typeIn
	SV *	dataIn
	GLsizei	wOut
	GLsizei	hOut
	GLenum	typeOut
	SV *	dataOut
	CODE:
	{
		GLvoid * inptr, * outptr;
		STRLEN discard;
		ELI(dataIn, wIn, hIn, format, typeIn, gl_pixelbuffer_unpack);
		ELI(dataOut, wOut, hOut, format, typeOut, gl_pixelbuffer_pack);
		inptr = SvPV(dataIn, discard);
		outptr = SvPV(dataOut, discard);
		RETVAL = gluScaleImage(format, wIn, hIn, typeIn, inptr, wOut, hOut, typeOut, outptr);
	}
	OUTPUT:
	RETVAL

void
gluSphere(quad, radius, slices, stacks)
	GLUquadricObj *	quad
	GLdouble	radius
	GLint	slices
	GLint	stacks

#ifdef GLU_VERSION_1_2

GLdouble
gluGetTessProperty_p(tess, property)
	PGLUtess *	tess
	GLenum	property
	CODE:
	{
		GLdouble param;
		gluGetTessProperty(tess->triangulator, property, &param);
		RETVAL = param;
	}
	OUTPUT:
	RETVAL

#void
#gluNurbsCallback_p(nurb, which, handler, ...)

#void
#gluNurbsCallbackDataEXT

#void
#gluQuadricCallback

void
gluTessBeginCountour(tess)
	PGLUtess *	tess
	CODE:
	gluTessBeginContour(tess->triangulator);

void
gluTessEndContour(tess)
	PGLUtess *	tess
	CODE:
	gluTessEndContour(tess->triangulator);

void
gluTessBeginPolygon(tess, ...)
	PGLUtess *	tess
	CODE:
	{
		if (tess->polygon_data_av) {
			SvREFCNT_dec(tess->polygon_data_av);
			tess->polygon_data_av = 0;
		}
		if (items > 1) {
			tess->polygon_data_av = newAV();
			PackCallbackST(tess->polygon_data_av, 1);
		}
		gluTessBeginPolygon(tess->triangulator, tess);
	}

void
gluTessEndPolygon(tess)
	PGLUtess *	tess
	CODE:
	{
		if (tess->polygon_data_av) {
			SvREFCNT_dec(tess->polygon_data_av);
			tess->polygon_data_av = 0;
		}
	}

void
gluTessNormal(tess, valueX, valueY, valueZ)
	PGLUtess *	tess
	GLdouble	valueX
	GLdouble	valueY
	GLdouble	valueZ
	CODE:
	gluTessNormal(tess->triangulator, valueX, valueY, valueZ);

void
gluTessProperty(tess, which, data)
	PGLUtess *	tess
	GLenum	which
	GLdouble	data
	CODE:
	gluTessProperty(tess->triangulator, which, data);

void
gluTessCallback(tess, which, ...)
	PGLUtess *	tess
	GLenum	which
	CODE:
	{
		switch (which) {
		case GLU_TESS_BEGIN:
		case GLU_TESS_BEGIN_DATA:
			if (tess->begin_callback) {
				SvREFCNT_dec(tess->begin_callback);
				tess->begin_callback = 0;
			}
			break;
		case GLU_TESS_END:
		case GLU_TESS_END_DATA:
			if (tess->end_callback) {
				SvREFCNT_dec(tess->end_callback);
				tess->end_callback = 0;
			}
			break;
		}
		
		if ((items > 3) && !SvOK(ST(2))) {
			AV * callback = newAV();
			PackCallbackST(callback, 2);

			switch (which) {
			case GLU_TESS_BEGIN:
			case GLU_TESS_BEGIN_DATA:
				tess->begin_callback = callback;
				gluTessCallback(tess->triangulator, which, (void (CALLBACK*)()) _s_marshal_glu_t_callback_begin);
				break;
			case GLU_TESS_END:
			case GLU_TESS_END_DATA:
				tess->end_callback = callback;
				gluTessCallback(tess->triangulator, which, (void (CALLBACK*)()) _s_marshal_glu_t_callback_end);
				break;
			}
		}
	}
	

#endif

void
gluTessVertex(tess, x, y, z, ...)
	PGLUtess *	tess
	GLdouble	x
	GLdouble	y
	GLdouble	z
	CODE:
	{
		AV * data = 0;
		GLdouble v[3];
		v[0] = x;
		v[1] = y;
		v[2] = z;

		if (items > 4) {
			data = newAV();
			PackCallbackST(data, 4);
			
			if (!tess->vertex_datas)
				tess->vertex_datas = newAV();
			
			av_push(tess->vertex_datas, newRV_inc((SV*)data));
			SvREFCNT_dec(data);
		}

		gluTessVertex(tess->triangulator, &v[0], (void*)data);
	}

void
gluUnProject_p(winx, winy, winz, m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12,m13,m14,m15,m16, o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11,o12,o13,o14,o15,o16, v1,v2,v3,v4)
	GLdouble	winx
	GLdouble	winy
	GLdouble	winz
	PPCODE:
	{
		GLdouble m[16], p[16], objx, objy, objz;
		GLint v[4];
		int i;
		for (i=0;i<16;i++)
			m[i] = SvIV(ST(i+3));
		for (i=0;i<16;i++)
			p[i] = SvIV(ST(i+3+16));
		for (i=0;i<4;i++)
			v[i] = SvIV(ST(i+3+16+16));
		i = gluUnProject(winx, winy, winz, m, p, v, &objx, &objy, &objz);
		if (i) {
			EXTEND(sp, 3);
			PUSHs(sv_2mortal(newSVnv(objx)));
			PUSHs(sv_2mortal(newSVnv(objy)));
			PUSHs(sv_2mortal(newSVnv(objz)));
		}
	}

#endif

############################## GLUT #########################

#ifdef GLUT_API_VERSION

# GLUT

void
glutInit()
	CODE:
	{
	int argc;
	char ** argv;
	AV * ARGV;
	SV * ARGV0;
	int i;

			argv  = 0;
			ARGV = perl_get_av("ARGV", FALSE);
			ARGV0 = perl_get_sv("0", FALSE);
			
			argc = av_len(ARGV)+2;
			if (argc) {
				argv = malloc(sizeof(char*)*argc);
				argv[0] = SvPV(ARGV0, PL_na);
				for(i=0;i<=av_len(ARGV);i++)
					argv[i+1] = SvPV(*av_fetch(ARGV, i, 0), PL_na);
			}
			
			i = argc;
			glutInit(&argc, argv);

			while(argc<i--)
				av_shift(ARGV);
			
			if (argv)
				free(argv);
	}

void
glutInitWindowSize(width, height)
	int	width
	int	height

void
glutInitWindowPosition(x, y)
	int	x
	int	y

void
glutInitDisplayMode(mode)
	int	mode


void
glutMainLoop()


int
glutCreateWindow(name)
	char *	name
	CODE:
	RETVAL = glutCreateWindow(name);
	destroy_glut_win_handlers(RETVAL);
	OUTPUT:
	RETVAL

int
glutCreateSubWindow(win, x, y, width, height)
	int	win
	int	x
	int	y
	int	width
	int	height
	CODE:
	RETVAL = glutCreateSubWindow(win, x, y, width, height);
	destroy_glut_win_handlers(RETVAL);
	OUTPUT:
	RETVAL

void
glutSetWindow(win)
	int	win

int
glutGetWindow()

void
glutDestroyWindow(win)
	int	win
	CODE:
	glutDestroyWindow(win);
	destroy_glut_win_handlers(win);

void
glutPostRedisplay()

void
glutSwapBuffers()

void
glutPositionWindow(x, y)
	int	x
	int	y

void
glutReshapeWindow(width, height)
	int	width
	int	height

#if GLUT_API_VERSION >= 3

void
glutFullScreen()

#endif

void
glutPopWindow()

void
glutPushWindow()

void
glutShowWindow()

void
glutHideWindow()

void
glutIconifyWindow()

void
glutSetWindowTitle(title)
	char *	title

void
glutSetIconTitle(title)
	char *	title

#if GLUT_API_VERSION >= 3

void
glutSetCursor(cursor)
	int	cursor

#endif

# Overlays


#if GLUT_API_VERSION >= 3

void
glutEstablishOverlay()

void
glutUseLayer(layer)
	GLenum	layer

void
glutRemoveOverlay()

void
glutPostOverlayRedisplay()

void
glutShowOverlay()

void
glutHideOverlay()

#endif

# Menus

int
glutCreateMenu(handler=0, ...)
	SV *	handler
	CODE:
	{
		if (!handler || !SvOK(handler)) {
			croak("A handler must be specified");
		} else {
			AV * handler_data = newAV();
		
			PackCallbackST(handler_data, 0);

			RETVAL = glutCreateMenu(generic_glut_menu_handler);
			
			if (!glut_menu_handlers)
				glut_menu_handlers = newAV();
			
			av_store(glut_menu_handlers, RETVAL, newRV_inc((SV*)handler_data));
			
			SvREFCNT_dec(handler_data);
			
		}
	}
	OUTPUT:
	RETVAL

void
glutSetMenu(menu)
	int	menu

int
glutGetMenu()

void
glutDestroyMenu(menu)
	int	menu
	CODE:
	{
		glutDestroyMenu(menu);
		av_store(glut_menu_handlers, menu, newSVsv(&PL_sv_undef));
	}

void
glutAddMenuEntry(name, value)
	char *	name
	int	value

void
glutAddSubMenu(name, menu)
	char *	name
	int	menu

void
glutChangeToMenuEntry(entry, name, value)
	int	entry
	char *	name
	int	value

void
glutChangeToSubMenu(entry, name, menu)
	int	entry
	char *	name
	int	menu

void
glutRemoveMenuItem(entry)
	int	entry


void
glutAttachMenu(button)
	int	button


void
glutDetachMenu(button)
	int	button

# Callbacks

void
glutDisplayFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs_nullfail(Display, ("Display function must be specified"))

#if GLUT_API_VERSION >= 3

void
glutOverlayDisplayFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(OverlayDisplay)

#endif

void
glutReshapeFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Reshape)

void
glutKeyboardFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Keyboard)

void
glutMouseFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Mouse)

void
glutMotionFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Motion)

void
glutPassiveMotionFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(PassiveMotion)

void
glutVisibilityFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Visibility)

# OS/2 PM implementation calls itself v2, but does not support these functions
# It is very hard to test for this, so we check for some other omission...

#if !defined(GL_SRC_ALPHA_SATURATE) || defined(GL_CONSTANT_COLOR)

void
glutEntryFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Entry)

#endif

#if GLUT_API_VERSION >= 2

void
glutSpecialFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Special)

# OS/2 PM implementation calls itself v2, but does not support these functions
# It is very hard to test for this, so we check for some other omission...

#  if !defined(GL_SRC_ALPHA_SATURATE) || defined(GL_CONSTANT_COLOR)

void
glutSpaceballMotionFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(SpaceballMotion)

void
glutSpaceballRotateFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(SpaceballRotate)

void
glutSpaceballButtonFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(SpaceballButton)

void
glutButtonBoxFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(ButtonBox)

void
glutDialsFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(Dials)

void
glutTabletMotionFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(TabletMotion)

void
glutTabletButtonFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_gwh_xs(TabletButton)

#  endif

#endif

#if GLUT_API_VERSION >= 3

void
glutMenuStatusFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_ggh_xs(MenuStatus)

#endif

void
glutMenuStateFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_ggh_xs(MenuState)

void
glutIdleFunc(handler=0, ...)
	SV *	handler
	CODE:
	decl_ggh_xs(Idle)

void
glutTimerFunc(msecs, handler=0, ...)
	unsigned int	msecs
	SV *	handler
	CODE:
	{
		if (!handler || !SvOK(handler)) {
			croak("A handler must be specified");
		} else {
			AV * handler_data = newAV();
		
			PackCallbackST(handler_data, 1);
			
			glutTimerFunc(msecs, generic_glut_timer_handler, (int)handler_data);
		}
	ENSURE_callback_thread;}


# Colors

void
glutSetColor(cell, red, green, blue)
	int	cell
	GLdouble	red
	GLdouble	green
	GLdouble	blue

GLfloat
glutGetColor(cell, component)
	int	cell
	int	component


void
glutCopyColormap(win)
	int	win

# State

int
glutGet(state)
	GLenum	state

#if GLUT_API_VERSION >= 3

int
glutLayerGet(info)
	GLenum	info

#endif

int
glutDeviceGet(info)
	GLenum	info

#if GLUT_API_VERSION >= 3

int
glutGetModifiers()

#endif

#if GLUT_API_VERSION >= 2

int
glutExtensionSupported(extension)
	char *	extension

#endif

# Font

void
glutBitmapCharacter(font, character)
	void *	font
	int	character

void
glutStrokeCharacter(font, character)
	void *	font
	int	character

# OS/2 PM implementation calls itself v2, but does not support these functions
# It is very hard to test for this, so we check for some other omission...

#if GLUT_API_VERSION >= 2 && (!defined(GL_SRC_ALPHA_SATURATE) || defined(GL_CONSTANT_COLOR))

int
glutBitmapWidth(font, character)
	void *	font
	int	character

int
glutStrokeWidth(font, character)
	void *	font
	int	character

#endif

# Solids

void
glutSolidSphere(radius, slices, stacks)
	GLdouble	radius
	GLint	slices
	GLint	stacks

void
glutWireSphere(radius, slices, stacks)
	GLdouble	radius
	GLint	slices
	GLint	stacks

void
glutSolidCube(size)
	GLdouble	size

void
glutWireCube(size)
	GLdouble	size

void
glutSolidCone(base, height, slices, stacks)
	GLdouble	base
	GLdouble	height
	GLint	slices
	GLint	stacks

void
glutWireCone(base, height, slices, stacks)
	GLdouble	base
	GLdouble	height
	GLint	slices
	GLint	stacks

void
glutSolidTorus(innerRadius, outerRadius, nsides, rings)
	GLdouble	innerRadius
	GLdouble	outerRadius
	GLint	nsides
	GLint	rings

void
glutWireTorus(innerRadius, outerRadius, nsides, rings)
	GLdouble	innerRadius
	GLdouble	outerRadius
	GLint	nsides
	GLint	rings

void
glutSolidDodecahedron()

void
glutWireDodecahedron()

void
glutSolidOctahedron()

void
glutWireOctahedron()

void
glutSolidTetrahedron()

void
glutWireTetrahedron()

void
glutSolidIcosahedron()

void
glutWireIcosahedron()

void
glutSolidTeapot(size)
	GLdouble	size

void
glutWireTeapot(size)
	GLdouble	size

#endif /* def GLUT_API_VERSION */


# /* The following material is directly copied from Stan Melax's original OpenGL-0.4 */

#ifdef __PM__

void
morphPM()

#endif

int
__had_dbuffer_hack()

#ifdef HAVE_GLpc			/* GLX or __PM__ */

GLXDrawable
glpcOpenWindow(x,y,w,h,pw,steal,event_mask, ...)
	int	x
	int	y
	int	w
	int	h
	int	pw
	int	steal
	long	event_mask
	CODE:
	{
	    XEvent event;
	    Window pwin=(Window)pw;
	    int *attributes = default_attributes + 1;
	    int *a_buf = NULL;

	    if(items>NUM_ARG){
	        int i;
	        a_buf = (int *)malloc((items-NUM_ARG+2)* sizeof(int));
		a_buf[0] = GLX_DOUBLEBUFFER; /* Preallocate */
		attributes = a_buf + 1;
	        for(i=NUM_ARG;i<items;i++) {
	            attributes[i-NUM_ARG]=SvIV(ST(i));
	        }
	        attributes[items-NUM_ARG]=None;
	    }
	    /* get a connection */
	    if (!dpy_open) {
		dpy = XOpenDisplay(0);
		dpy_open = 1;
	    }
	    if (!dpy)
		croak("No display!");

	    /* get an appropriate visual */
	    vi = glXChooseVisual(dpy, DefaultScreen(dpy),attributes);
	    if (!vi) { /* Might have happened that one does not
			* *need* DOUBLEBUFFER, but the display does
			* not provide SINGLEBUFFER; and the semantic
			* of GLX_DOUBLEBUFFER is that if it misses,
			* only SINGLEBUFFER visuals are selected.  */
			attributes--; /* GLX_DOUBLEBUFFER preallocated there */
		vi = glXChooseVisual(dpy, DefaultScreen(dpy),attributes); /* Retry */
		if (vi)
	    		DBUFFER_HACK = 1;
	    }
	    if (a_buf)
		free(a_buf);
	    if(!vi)
		croak("No visual!");

	    /* A blank line here will confuse xsubpp ;-) */
#ifdef HAVE_GLX
	    /* create a GLX context */
	    cx = glXCreateContext(dpy, vi, 0, GL_TRUE);
	    if(!cx)
		croak("No context\n");
	
	    /* create a color map */
	    cmap = XCreateColormap(dpy, RootWindow(dpy, vi->screen),
				   vi->visual, AllocNone);
	
	    /* create a window */
	    swa.colormap = cmap;
	    swa.border_pixel = 0;
	    swa.event_mask = event_mask;
#endif	/* defined HAVE_GLX */

	    if(!pwin){pwin=RootWindow(dpy, vi->screen);}
	    if (steal)
		win = nativeWindowId(dpy, pwin); /* What about depth/visual */
	    else
		win = XCreateWindow(dpy, pwin, 
				    x, y, w, h,
				    0, vi->depth, InputOutput, vi->visual,
				    CWBorderPixel|CWColormap|CWEventMask, &swa);
	    if(!win)
	        croak("No Window");
	    XMapWindow(dpy, win);
#ifndef HAVE_GLX
	    /* On OS/2: cannot create a context before mapping something... */
	    /* create a GLX context */
	    cx = glXCreateContext(dpy, vi, 0, GL_TRUE);
	    if(!cx)
		croak("No context!\n");

	    LastEventMask = event_mask;
#else	/* HAVE_GLX */
	    if((event_mask & StructureNotifyMask) && !steal) {
	        XIfEvent(dpy, &event, WaitForNotify, (char*)win);
	    }
#endif	/* HAVE_GLX */

	    /* connect the context to the window */
	    if (!glXMakeCurrent(dpy, win, cx))
	        croak("Non current");
	
	    /* clear the buffer */
	    glClearColor(0,0,0,1);
	    RETVAL = win;
	}

void *
glpDisplay()
	CODE:
	    /* get a connection */
	    if (!dpy_open) {
		dpy = XOpenDisplay(0);
		dpy_open = 1;
	    }
	    if (!dpy)
		croak("No display!");
	    RETVAL = dpy;

void
glpMoveResizeWindow(x, y, width, height, w=win, d=dpy)
    void* d
    GLXDrawable w
    int x
    int y
    unsigned int width
    unsigned int height

void
glpMoveWindow(x, y, w=win, d=dpy)
    void* d
    GLXDrawable w
    int x
    int y

void
glpResizeWindow(width, height, w=win, d=dpy)
    void* d
    GLXDrawable w
    unsigned int width
    unsigned int height

# If glpOpenWindow was used then glXSwapBuffers should be called
# without parameters (i.e. use the default parameters)

void
glXSwapBuffers(w=win,d=dpy)
	void *	d
	GLXDrawable	w
	CODE:
	{
	    glXSwapBuffers(d,w);
	}


int
XPending(d=dpy)
	void *	d
	CODE:
	{
		RETVAL = XPending(d);
	}
	OUTPUT:
	RETVAL

void
glpXNextEvent(d=dpy)
	void *	d
	PPCODE:
	{
		XEvent event;
		char buf[10];
		KeySym ks;
		XNextEvent(d,&event);
		switch(event.type) {
			case ConfigureNotify:
				EXTEND(sp,3);
				PUSHs(sv_2mortal(newSViv(event.type)));
				PUSHs(sv_2mortal(newSViv(event.xconfigure.width)));
				PUSHs(sv_2mortal(newSViv(event.xconfigure.height)));				
				break;
			case KeyPress:
			case KeyRelease:
				EXTEND(sp,2);
				PUSHs(sv_2mortal(newSViv(event.type)));
				XLookupString(&event.xkey,buf,sizeof(buf),&ks,0);
				buf[0]=(char)ks;buf[1]='\0';
				PUSHs(sv_2mortal(newSVpv(buf,1)));
				break;
			case ButtonPress:
			case ButtonRelease:
				EXTEND(sp,4);
				PUSHs(sv_2mortal(newSViv(event.type)));
				PUSHs(sv_2mortal(newSViv(event.xbutton.button)));
				PUSHs(sv_2mortal(newSViv(event.xbutton.x)));
				PUSHs(sv_2mortal(newSViv(event.xbutton.y)));
				break;
			case MotionNotify:
				EXTEND(sp,4);
				PUSHs(sv_2mortal(newSViv(event.type)));
				PUSHs(sv_2mortal(newSViv(event.xmotion.state)));
				PUSHs(sv_2mortal(newSViv(event.xmotion.x)));
				PUSHs(sv_2mortal(newSViv(event.xmotion.y)));
				break;
			case Expose:
			default:
				EXTEND(sp,1);
				PUSHs(sv_2mortal(newSViv(event.type)));
				break;
		}
	}

void
glpXQueryPointer(w=win,d=dpy)
	void *	d
	GLXDrawable	w
	PPCODE:
	{
		int x,y,rx,ry;
		Window r,c;
		unsigned int m;
		XQueryPointer(d,w,&r,&c,&rx,&ry,&x,&y,&m);
		EXTEND(sp,3);
		PUSHs(sv_2mortal(newSViv(x)));
		PUSHs(sv_2mortal(newSViv(y)));
		PUSHs(sv_2mortal(newSViv(m)));
	}

#endif


void
glpReadTex(file)
	char *	file
	CODE:
	{
	    GLsizei w,h;
	    int d,i;
	    char buf[250];
	    unsigned char *image;
	    FILE *fp;

	    fp=fopen(file,"r");
	    if(!fp)
	        croak("couldn't open file %s",file);
	    fgets(buf,250,fp);		/* P3 */
	    if (buf[0] != 'P' || buf[1] != '3')
	        croak("Format is not P3 in file %s",file);
	    fgets(buf,250,fp);
	    while (buf[0] == '#' && fgets(buf,250,fp))
		;			/* Empty */
	    if (2 != sscanf(buf,"%d%d",&w,&h))
	        croak("couldn't read image size from file %s",file);
	    if (1 != fscanf(fp,"%d",&d))
	        croak("couldn't read image depth from file %s",file);
	    if(d != 255)
	        croak("image depth != 255 in file %s unsupported",file);
	    if(w>10000 || h>10000)
	        croak("suspicious size w=%d d=%d in file %s", w, d, file);
	    New(1431, image, w*h*3, unsigned char);
	    for(i=0;i<w*h*3;i++) {
		int v;
	        if (1 != fscanf(fp,"%d",&v)) {
		    Safefree(image);
		    croak("Error reading number #%d of %d from file %s", i, w*h*3,file);
		}
	        image[i]=(unsigned char) v;
	    }
	    fclose(fp);
	    glTexImage2D(GL_TEXTURE_2D, 0, 3, w,h, 
	                 0, GL_RGB, GL_UNSIGNED_BYTE,image);
	}

BOOT:
  InitSys();
