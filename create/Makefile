#
#  Makefile for generating important files 
#

PERL=/usr/local/bin/perl

default:  typemap OpenGL.pm OpenGL.xs

typemap: typemap.gen gettypes generatefile
	$(PERL) ./generatefile $@

OpenGL.pm: OpenGL.pm.gen generatefile
	$(PERL) ./generatefile $@

OpenGL.xs: OpenGL.xs.gen getfunctions generatefile
	$(PERL) ./generatefile $@

clobber:
	/bin/rm typemap OpenGL.pm OpenGL.xs

use:  default
	/bin/mv -f typemap OpenGL.pm OpenGL.xs ..

