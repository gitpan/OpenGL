#!/usr/local/bin/perl
#
# This thing creates the Makefile and stuff
#

#  Generate the Makefile
use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME'	=> 'OpenGL',
    'VERSION'	=> '0.3',
    'LIBS'	=> '-lXext -lX11 -lGL -lGLU',    
    # 'LIBS'	=> '-L/usr/local/Mesa/lib -lXext -lX11 -lGL -lGLU',    
    'DEFINE'	=> '',     # e.g., '-DHAVE_SOMETHING' 
    'INC'	=> '',   
    # 'INC'	=> '-I/usr/local/Mesa/include',   
);

sub MY::postamble {
        '
clobber: clean
	/bin/rm -rf blib Makefile Makefile.old
';
}

# helpful trailer for installer:
print "\n";
print "Do a 'make' to create the module.\n";
print "Then test by trying some of the examples.\n";
print "Do a 'make install' to install the module.\n";

