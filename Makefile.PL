# This thing creates the Makefile and stuff


# The files typemap OpenGL.pm and OpenGL.xs
# must exist when the Makefile is generated

`touch typemap`;
`touch OpenGL.pm`;
`touch OpenGL.xs`;

#  Generate the Makefile
use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME'	=> 'OpenGL',
    'VERSION'	=> '0.2',
    'LIBS'	=> '-lXext -lX11 -lGL -lGLU',    
    'DEFINE'	=> '',     # e.g., '-DHAVE_SOMETHING' 
    'INC'	=> '',     # e.g., '-I/usr/include/other' 
);

unlink "typemap"   || die "couldn't unlink (delete) typemap";
unlink "OpenGL.pm" || die "couldn't unlink (delete) OpenGL.pm";
unlink "OpenGL.xs" || die "couldn't unlink (delete) OpenGL.xs";

sub MY::postamble {
	'
typemap: typemap.gen gettypes generatefile
	perl ./generatefile $@

OpenGL.pm: OpenGL.pm.gen generatefile
	perl ./generatefile $@

OpenGL.xs: OpenGL.xs.gen getfunctions generatefile
	perl ./generatefile $@

';
}

# helpful trailer for installer:
print "\n";
print "Do a 'make' to create the module.\n";
print "Then test by trying some of the examples.\n";
print "Do a 'make install' to install the module.\n";
