use ExtUtils::MakeMaker;
use ExtUtils::Liblist;
use Config;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

# ExtUtils::Liblist is broken
@findlib::ISA = qw(ExtUtils::Liblist);
sub findlib::lsdir { shift; grep /$_[0]/, <$_[1]>}
sub findlib::file_name_is_absolute { 1 } # Used for warnings only...

# Extra library paths to search on
$libdirs = '-L/usr/X11R6/lib -L/usr/local/lib -L/usr/openwin/lib';
# Extra include paths to search on
$includes = '-I/usr/X11R6/include -I/usr/local/include -I/usr/openwin/include';

$pm_lib = (grep /^X11$/, @ARGV) ? '' : '-lopengl';

$libs = "-lGLU -lGLUT -lGLX $pm_lib -lMesaGLU -lMesaGLUT -lMesaGLX -lglut";

@libs = findlib->ext("$libdirs $libs");

$l = "@libs";		      # find anywhere...

$DEFS  = "-DHAVE_GL";         # Primary OpenGL system

# Mesa 3D version 3.4 needs this so that all extension constants (even
# obsolete ones) will be defined. Without this, about 13 or so won't be
# known. It can't hurt for other distributions, so we won't even check.

$DEFS .= " -DGL_GLEXT_LEGACY";

# GL Utility library (on OS/2 built into -lopengl)
$DEFS .= " -DHAVE_GLU" if $l =~ /(^|\s)-l(\w*GLU|opengl)\b/;

# Simple User interface Toolkit
$DEFS .= " -DHAVE_GLUT" if $l =~ /(^|\s)-l\w*(GLUT|glut)\b/;

# On OS/2 build a PM version by default - override by X11 on the command line
$x = grep /^X11$/, @ARGV;
@ARGV = (grep !/^X11$/, @ARGV);

$nox = ($^O eq 'os2' and $l =~ /(^|\s)-lopengl\b/ and not $x);

sub cfile_text {
  my $filename = shift;

  # Use $Config{cpprun}, instead of $Config{cpp}. cpp is simply set to
  # 'cpp' after Configure has run, which is not useful, since it lives
  # in /lib/ on many systems, which is normally not on the path.  This
  # is documented, but silly behaviour.  $Config{cpprun} is what is
  # documented to be set to a cpp that will take stuff on stdin

  my $cmd = "echo '\#include \"$filename\"' | $Config{cpprun} $includes $Config{cppflags} $Config{cppminus} 2>&1";
  `$cmd`;
}


unless ($nox) {
  $x = ($l =~ /(^|\s)-l(Mesa)GLX\b/);
  unless ($x) {	# quite often GLX is in -lGL...  Test for GL/glx.h instead...
    $out = cfile_text 'GL/glx.h';
	# The cpp would not let this macro through. Check for something else
	# that still exists after the cpp pass. a typedef, or type would work
    #$x = 1 if $out =~ /GLX_RGBA/;
    $x = 1 if $out =~ /GLXContext/;
    print STDERR "#\n### GLX not found (neigher library, nor headers).\n#\n"
      unless $x;
  }
}

# Interface to X/Windows for OpenGL -- emulated on several non-X systems.
$DEFS .= " -DHAVE_GLX" if $x;

$DEFS .= ' -DOS2_GL_DISABLE_MISSING_EXT -DAPIENTRY= -D__PM__'
  if $^O eq 'os2' and not $x;

# Should be deduced automatically, but how?!
$no_lgcc = (grep /^NO_LGCC$/, @ARGV);
@ARGV = grep !/^NO_LGCC$/, @ARGV;

$gcclib = '';
unless ($no_lgcc) {
  # This may be a gcc compiler in disguise. Should check for gccversion
  # as well.
  #if (not defined $Config{gcc}) {
  if ($Config{cc} ne 'gcc' && !$Config{gccversion}) {
    $gccout = `gcc -v 2>&1`;
    if ($gccout =~ /specs from (.*)/) {	# gcc present
      ($gcclibdir = $1) =~ s,\bspecs\s*$,,;
      $gcclib = "-L$gcclibdir -lgcc";
      print STDERR <<EOP;
#
### Non-gcc compiler, and gcc is present.
### Adding -lgcc as a dependency: your OpenGL libraries may be gcc-compiled.
### Use NO_LGCC command-line option to disable this.
#
EOP
    }
  }
}

@LIBS = split ' ', qq($libs -lGL -lMesaGL
	   -lXext -lXmu -lXi -lICE -lXIE -lX11 -lm $gcclib);

WriteMakefile(
    'NAME'	=> 'OpenGL',
    'VERSION_FROM'	=> 'OpenGL.pm',
    'DEFINE'	=> $DEFS,
	'XSPROTOARG' => '-noprototypes',
	'OBJECT' => '$(BASEEXT)$(OBJ_EXT) gl_util$(OBJ_EXT)',
	'LIBS' => "$libdirs @LIBS",
	'INC' => $includes,
	'PM' => {'OpenGL.pm' => '$(INST_LIBDIR)/OpenGL.pm'},
);
