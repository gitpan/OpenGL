use ExtUtils::MakeMaker;
use ExtUtils::Liblist;
use Config;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

# ExtUtils::Liblist is broken
@findlib::ISA = qw(ExtUtils::Liblist);
sub findlib::lsdir { shift; grep /$_[0]/, <$_[1]>}
sub findlib::file_name_is_absolute { 1 } # Used for warnings only...

# Check OpenGL installation
my $DEFS = "";

my @check_libs = qw
{
  -lGL
  -lGLU
  -lglut
  -lopengl
  -lGLX
  -lglx
  -lglu
  -lGLUT
  -lOSMesa
  -lMesaGL
  -lMesaGLU
  -lMesaGLX
  -lMesaGLUT
};
my $found_libs = get_libs("@check_libs");
die "No OpenGL libs found\n" if (!$found_libs->{GL});

my $exc_file = 'gl_exclude.h';
unlink($exc_file) if (-e $exc_file);

# Only run this if GLUT is installed
if ($found_libs->{GLUT})
{
  my $glv_file = 'utils/glversion.txt';

  my $make_ver;
  if ($^O eq 'MSWin32')
  {
    $make_ver = '&nmake -f makefile.mak'
  }
  elsif ($^O eq 'darwin' && -d '/System/Library/Frameworks/OpenGL.framework')
  {
    $make_ver = ';make -f Makefile.macosx';
  }
  else
  {
    $make_ver = ';make';
  }
  my $stat = qx(cd utils $make_ver clean $make_ver);
  #print "$stat\n";

  die "Unable to open glext_procs.h\n" if (!open(GLEXT,"glext_procs.h"));
  my @lines = <GLEXT>;
  close(GLEXT);

  my $no_ext = {};
  foreach my $line (@lines)
  {
    next if ($line !~ m|\#ifndef NO_([^\s]+)|);
    my $ext = $1;
    next if ($ext =~ m|^GL_VERSION_|);
    $no_ext->{$ext}++;
  }

  my $gldata = {};
  if (open(GLDATA,$glv_file))
  {
    my @gldata = <GLDATA>;
    close(GLDATA);

    foreach my $line (@gldata)
    {
      $line =~ s|[\r\n]+||;
      my($key,$val) = split('=',$line);
      $gldata->{$key} = $val;
    }

    $DEFS = "-DHAVE_VER";
    #print "Have Version Data\n";
  }

  die "Unable to write to $exc_file\n" if (!open(GLEXC,">$exc_file"));
  if ($gldata->{VERSION} =~ m|^(\d\.\d+)|)
  {
    my $ver = $1;
    print GLEXC "#define NO_GL_VERSION_2_0\n" if ($ver < 2.0);
    print GLEXC "#define NO_GL_VERSION_1_5\n" if ($ver < 1.5);
    print GLEXC "#define NO_GL_VERSION_1_4\n" if ($ver < 1.4);
    print GLEXC "#define NO_GL_VERSION_1_3\n" if ($ver < 1.3);
    print GLEXC "#define NO_GL_VERSION_1_2\n" if ($ver < 1.2);
    print GLEXC "#define NO_GL_VERSION_1_1\n" if ($ver < 1.1);
  }

  foreach my $ext (split(' ',$gldata->{EXTENSIONS}))
  {
    next if (!$no_ext->{$ext});
    $no_ext->{$ext} = 0;
  }

  foreach my $ext (sort keys(%$no_ext))
  {
    next if (!$no_ext->{$ext});
    print GLEXC "#define NO_$ext\n";
  }
  close(GLEXC);
}


if ($^O eq 'MSWin32')      # for Win32
{
  $DEFS .= " -DHAVE_GL";   # Primary OpenGL system
  $DEFS .= " -DHAVE_GLU";  # GL Utility library
  $DEFS .= " -DHAVE_GLUT"; # Simple User interface Toolkit

  WriteMakefile(
    'NAME'		=> 'OpenGL',
    'VERSION_FROM'	=> 'OpenGL.pm',
    'DEFINE'		=> $DEFS,
    'XSPROTOARG' 	=> '-noprototypes',
    'OBJECT' 		=> '$(BASEEXT)$(OBJ_EXT) gl_util$(OBJ_EXT)',
    'LIBS' 		=> ["-lOPENGL32 -lGLU32 -lglut32",],
    'INC'		=> "",
    'OPTIMIZE'		=> "/O2gity /GDs",
    'PM' 		=> {'OpenGL.pm' => '$(INST_LIBDIR)/OpenGL.pm'},
    'dist' 		=> { COMPRESS=>"gzip", SUFFIX=>"gz" }
  );
}
elsif ($^O eq 'darwin' && -d '/System/Library/Frameworks/OpenGL.framework')      # for Mac OS X
{
  $DEFS .= " -DHAVE_GL";   # Primary OpenGL system
  $DEFS .= " -DHAVE_GLU";  # GL Utility library
  $DEFS .= " -DHAVE_GLUT"; # Simple User interface Toolkit

  WriteMakefile(
    'NAME'		=> 'OpenGL',
    'VERSION_FROM'	=> 'OpenGL.pm',
    'DEFINE'		=> $DEFS,
    'XSPROTOARG' 	=> '-noprototypes',
    'OBJECT' 		=> '$(BASEEXT)$(OBJ_EXT) gl_util$(OBJ_EXT)',
    'INC'		=> "",
    'PM' 		=> {'OpenGL.pm' => '$(INST_LIBDIR)/OpenGL.pm'},
    'dist' 		=> { COMPRESS=>"gzip", SUFFIX=>"gz" },
    dynamic_lib => { OTHERLDFLAGS => " -framework OpenGL -framework GLUT" },
  );
}
else # Everyone else
{
  # Extra library paths to search on
  $libdirs = '-L/usr/lib -L/usr/X11R6/lib -L/usr/local/lib -L/usr/openwin/lib'.
    ' -L/usr/lib/xorg/modules/extensions -L/usr/X11R6/lib/modules/extensions';

  # Extra include paths to search on
  $includes = '-I/usr/include -I/usr/X11R6/include -I/usr/local/include -I/usr/openwin/include';

  foreach my $def (keys %$found_libs)
  {
    $DEFS  .= " -DHAVE_$def";
  }
  $DEFS .= " -DGL_GLEXT_LEGACY";


  # On OS/2 build a PM version by default - override by X11 on the command line
  $x = grep /^X11$/, @ARGV;
  @ARGV = (grep !/^X11$/, @ARGV);

  #$nox = ($^O eq 'os2' and $l =~ /(^|\s)-lopengl\b/ and not $x);
  $nox = ($^O eq 'os2' and $found_libs->{GL} and not $x);

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
  #  $x = ($l =~ /(^|\s)-l(Mesa)GLX\b/);
    $x = $found_libs->{GLX};
    unless ($x) {	# quite often GLX is in -lGL...  Test for GL/glx.h instead...
      $out = cfile_text 'GL/glx.h';
	# The cpp would not let this macro through. Check for something else
	# that still exists after the cpp pass. a typedef, or type would work
      #$x = 1 if $out =~ /GLX_RGBA/;
      $x = 1 if $out =~ /GLXContext/;
      print STDERR "#\n### GLX not found (neither library, nor headers).\n#\n"
        unless $x;
    }
  }

  # Interface to X/Windows for OpenGL -- emulated on several non-X systems.
  $DEFS .= " -DHAVE_GLX" if $x && !$found_libs->{GLX};

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

  my @LIBS = ();
  foreach my $key (keys %$found_libs)
  {
    push(@LIBS,$found_libs->{$key});
  }
  push(@LIBS,qw(-lXext -lXmu -lXi -lICE -lXIE -lX11 -lm));
  push(@LIBS,$gcclib);

  WriteMakefile(
    'NAME'		=> 'OpenGL',
    'VERSION_FROM'	=> 'OpenGL.pm',
    'DEFINE'		=> $DEFS,
    'XSPROTOARG' 	=> '-noprototypes',
    'OBJECT' 		=> '$(BASEEXT)$(OBJ_EXT) gl_util$(OBJ_EXT)',
    'LIBS' 		=> "$libdirs @LIBS",
    'INC'		=> $includes,
    'PM'		=> {'OpenGL.pm' => '$(INST_LIBDIR)/OpenGL.pm'},
  );
}
exit 0;


sub get_libs
{
  my($libs) = @_;
  my $found = {};

  if ($^O eq 'MSWin32')
  {
    my $paths = $ENV{PATH};
    $paths =~ s|\\|/|g;
    my @paths = split(';\s*',$paths);

    my $libs = {GL=>'opengl32.dll',GLU=>'glu32.dll',GLUT=>'glut32.dll'};
    foreach my $key (keys %$libs)
    {
      foreach my $path (@paths)
      {
        $path =~ s|/$||;
        my $lib = $libs->{$key};
        next if (!-e "$path/$lib");
        $found->{$key} = $lib;
        last;
      }
    }
    return $found;
  }

  if ($^O eq 'darwin' && -d '/System/Library/Frameworks/OpenGL.framework')
  {
    my $libs =
    {
      GL => 'OpenGL.framework',
      GLU => 'AGL.framework',
      GLUT => 'GLUT.framework',
    };
    
    return $libs;
  }

  my @libs = findlib->ext($libs);
  $libs = "@libs ";

  # Look for GL
  if ($libs =~ m|(-l[\w]*gl[x]?)\s|i)
  {
    $found->{GL} = $1;
  }

  # Look for GLU
  if ($libs =~ m|(-l[\w]*glu)\s|i)
  {
    $found->{GLU} = $1;
  }

  # Look for GLUT
  if ($libs =~ m|(-l[\w]*glut)\s|i)
  {
    $found->{GLUT} = $1;
  }

  # Look for GLX
  if ($libs =~ m|(-l[\w]*glx)\s|i)
  {
    $found->{GLX} = $1;
  }

  # Look for MESA
  if ($libs =~ m|(-l[\w]*mesa[glx]*)|i)
  {
    $found->{MESA} = $1;
    $found->{GL} = $1 if (!$found->{GL});
  }

  return $found;
}
