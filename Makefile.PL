use ExtUtils::MakeMaker;
use ExtUtils::Liblist;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.


# If your system does not have any of these packages, please commment
# out the appropriate line.

$DEFS  = "-DHAVE_GL";         # Primary OpenGL system
$DEFS .= " -DHAVE_GLU";       # GL Utility library
$DEFS .= " -DHAVE_GLUT";      # Simple User interface Toolkit
$DEFS .= " -DHAVE_GLX";       # Interface to X/Windows for OpenGL --
                              # emulated on several non-X systems.

@LIBS = qw(-L/usr/X11R6/lib -L/usr/local/lib -lGL -lGLU -lGLUT -lGLX 
-lMesaGL -lMesaGLU -lMesaGLUT -lMesaGLX -lglut -lXext -lXmu -lXi -lICE -lXIE -lX11);

WriteMakefile(
    'NAME'	=> 'OpenGL',
    'VERSION_FROM'	=> 'OpenGL.pm',
    'DEFINE'	=> $DEFS,
	'XSPROTOARG' => '-noprototypes',
	'OBJECT' => '$(BASEEXT)$(OBJ_EXT) gl_util$(OBJ_EXT)',
	'LIBS' => join(' ', @LIBS),
	'PM' => {'OpenGL.pm' => '$(INST_LIBDIR)/OpenGL.pm'},
	'dist' => { COMPRESS=>"gzip", SUFFIX=>"gz" }
);
