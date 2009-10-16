#ifdef GLUT_API_VERSION
    if (!strncmp(name, "GLUT_", 5)) {
	i(GLUT_API_VERSION)
#ifdef GLUT_XLIB_IMPLEMENTATION
	i(GLUT_XLIB_IMPLEMENTATION)
#endif
	i(GLUT_RGB)
	i(GLUT_RGBA)
	i(GLUT_INDEX)
	i(GLUT_SINGLE)
	i(GLUT_DOUBLE)
	i(GLUT_ACCUM)
	i(GLUT_ALPHA)
	i(GLUT_DEPTH)
	i(GLUT_STENCIL)
#if GLUT_API_VERSION >= 2
	i(GLUT_MULTISAMPLE)
	i(GLUT_STEREO)
#endif
#if GLUT_API_VERSION >= 3
	i(GLUT_LUMINANCE)
#endif
	i(GLUT_LEFT_BUTTON)
	i(GLUT_MIDDLE_BUTTON)
	i(GLUT_RIGHT_BUTTON)
	i(GLUT_DOWN)
	i(GLUT_UP)
#if GLUT_API_VERSION >= 2
	i(GLUT_KEY_F1)
	i(GLUT_KEY_F2)
	i(GLUT_KEY_F3)
	i(GLUT_KEY_F4)
	i(GLUT_KEY_F5)
	i(GLUT_KEY_F6)
	i(GLUT_KEY_F7)
	i(GLUT_KEY_F8)
	i(GLUT_KEY_F9)
	i(GLUT_KEY_F10)
	i(GLUT_KEY_F11)
	i(GLUT_KEY_F12)
	i(GLUT_KEY_LEFT)
	i(GLUT_KEY_UP)
	i(GLUT_KEY_RIGHT)
	i(GLUT_KEY_DOWN)
	i(GLUT_KEY_PAGE_UP)
	i(GLUT_KEY_PAGE_DOWN)
	i(GLUT_KEY_HOME)
	i(GLUT_KEY_END)
	i(GLUT_KEY_INSERT)
#endif
	i(GLUT_LEFT)
	i(GLUT_ENTERED)
	i(GLUT_MENU_NOT_IN_USE)
	i(GLUT_MENU_IN_USE)
	i(GLUT_NOT_VISIBLE)
	i(GLUT_VISIBLE)
#if GLU_API_VERSION >= 4
	i(GLUT_HIDDEN)
	i(GLUT_FULLY_RETAINED)
	i(GLUT_PARTIALLY_RETAINED)
	i(GLUT_FULLY_COVERED)
#endif
	i(GLUT_RED)
	i(GLUT_GREEN)
	i(GLUT_BLUE)
#if GLUT_API_VERSION >= 3
	i(GLUT_NORMAL)
	i(GLUT_OVERLAY)
#endif
	p(GLUT_STROKE_ROMAN)
	p(GLUT_STROKE_MONO_ROMAN)
	p(GLUT_BITMAP_9_BY_15)
	p(GLUT_BITMAP_8_BY_13)
	p(GLUT_BITMAP_TIMES_ROMAN_10)
	p(GLUT_BITMAP_TIMES_ROMAN_24)
#if GLUT_API_VERSION >= 3
	p(GLUT_BITMAP_HELVETICA_10)
	p(GLUT_BITMAP_HELVETICA_12)
	p(GLUT_BITMAP_HELVETICA_18)
#endif
	i(GLUT_WINDOW_X)
	i(GLUT_WINDOW_Y)
	i(GLUT_WINDOW_WIDTH)
	i(GLUT_WINDOW_HEIGHT)
	i(GLUT_WINDOW_BUFFER_SIZE)
	i(GLUT_WINDOW_STENCIL_SIZE)
	i(GLUT_WINDOW_DEPTH_SIZE)
	i(GLUT_WINDOW_RED_SIZE)
	i(GLUT_WINDOW_GREEN_SIZE)
	i(GLUT_WINDOW_BLUE_SIZE)
	i(GLUT_WINDOW_ALPHA_SIZE)
	i(GLUT_WINDOW_ACCUM_RED_SIZE)
	i(GLUT_WINDOW_ACCUM_GREEN_SIZE)
	i(GLUT_WINDOW_ACCUM_BLUE_SIZE)
	i(GLUT_WINDOW_ACCUM_ALPHA_SIZE)
	i(GLUT_WINDOW_DOUBLEBUFFER)
	i(GLUT_WINDOW_RGBA)
	i(GLUT_WINDOW_PARENT)
	i(GLUT_WINDOW_NUM_CHILDREN)
	i(GLUT_WINDOW_COLORMAP_SIZE)
#if GLUT_API_VERSION >= 2
	i(GLUT_WINDOW_NUM_SAMPLES)
	i(GLUT_WINDOW_STEREO)
#endif
#if GLUT_API_VERSION >= 3
	i(GLUT_WINDOW_CURSOR)
#endif
	i(GLUT_SCREEN_WIDTH)
	i(GLUT_SCREEN_HEIGHT)
	i(GLUT_SCREEN_WIDTH_MM)
	i(GLUT_SCREEN_HEIGHT_MM)
	i(GLUT_MENU_NUM_ITEMS)
	i(GLUT_DISPLAY_MODE_POSSIBLE)
	i(GLUT_INIT_WINDOW_X)
	i(GLUT_INIT_WINDOW_Y)
	i(GLUT_INIT_WINDOW_WIDTH)
	i(GLUT_INIT_WINDOW_HEIGHT)
	i(GLUT_INIT_DISPLAY_MODE)
#if GLUT_API_VERSION >= 2
	i(GLUT_ELAPSED_TIME)
#endif
#if GLUT_API_VERSION >= 2
	i(GLUT_HAS_KEYBOARD)
	i(GLUT_HAS_MOUSE)
	i(GLUT_HAS_SPACEBALL)
	i(GLUT_HAS_DIAL_AND_BUTTON_BOX)
	i(GLUT_HAS_TABLET)
	i(GLUT_NUM_MOUSE_BUTTONS)
	i(GLUT_NUM_SPACEBALL_BUTTONS)
	i(GLUT_NUM_BUTTON_BOX_BUTTONS)
	i(GLUT_NUM_DIALS)
	i(GLUT_NUM_TABLET_BUTTONS)
#endif
#if GLUT_API_VERSION >= 3
	i(GLUT_OVERLAY_POSSIBLE)
	i(GLUT_LAYER_IN_USE)
	i(GLUT_HAS_OVERLAY)
	i(GLUT_TRANSPARENT_INDEX)
	i(GLUT_NORMAL_DAMAGED)
	i(GLUT_OVERLAY_DAMAGED)
#endif
		/* OS/2 PM implementation does not have these constants... */
#if !defined(GLUT_MIDDLE_BUTTON) || defined(GLUT_NORMAL)
	i(GLUT_NORMAL)
	i(GLUT_OVERLAY)
	i(GLUT_ACTIVE_SHIFT)
	i(GLUT_ACTIVE_CTRL)
	i(GLUT_ACTIVE_ALT)
	i(GLUT_CURSOR_RIGHT_ARROW)
	i(GLUT_CURSOR_LEFT_ARROW)
	i(GLUT_CURSOR_INFO)
	i(GLUT_CURSOR_DESTROY)
	i(GLUT_CURSOR_HELP)
	i(GLUT_CURSOR_CYCLE)
	i(GLUT_CURSOR_SPRAY)
	i(GLUT_CURSOR_WAIT)
	i(GLUT_CURSOR_TEXT)
	i(GLUT_CURSOR_CROSSHAIR)
	i(GLUT_CURSOR_UP_DOWN)
	i(GLUT_CURSOR_LEFT_RIGHT)
	i(GLUT_CURSOR_TOP_SIDE)
	i(GLUT_CURSOR_BOTTOM_SIDE)
	i(GLUT_CURSOR_LEFT_SIDE)
	i(GLUT_CURSOR_RIGHT_SIDE)
	i(GLUT_CURSOR_TOP_LEFT_CORNER)
	i(GLUT_CURSOR_TOP_RIGHT_CORNER)
	i(GLUT_CURSOR_BOTTOM_RIGHT_CORNER)
	i(GLUT_CURSOR_BOTTOM_LEFT_CORNER)
	i(GLUT_CURSOR_INHERIT)
	i(GLUT_CURSOR_NONE)
	i(GLUT_CURSOR_FULL_CROSSHAIR)
#endif
#if GLUT_API_VERSION >= 4
	i(GLUT_GAME_MODE_ACTIVE)
	i(GLUT_GAME_MODE_POSSIBLE)
	i(GLUT_GAME_MODE_WIDTH)
	i(GLUT_GAME_MODE_HEIGHT)
	i(GLUT_GAME_MODE_PIXEL_DEPTH)
	i(GLUT_GAME_MODE_REFRESH_RATE)
	i(GLUT_GAME_MODE_DISPLAY_CHANGED)
#endif
#ifdef HAVE_FREEEGLUT
	/* FreeGLUT Constants */
	i(GLUT_INIT_STATE)
	i(GLUT_WINDOW_FORMAT_ID)
	i(GLUT_ACTION_EXIT)
	i(GLUT_ACTION_GLUTMAINLOOP_RETURNS)
	i(GLUT_ACTION_CONTINUE_EXECUTION)
	i(GLUT_ACTION_ON_WINDOW_CLOSE)
#endif
	}
	else
#endif /* def GTK_API_VERSION */
