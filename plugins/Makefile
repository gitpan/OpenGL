#!smake
#
#  The Makefile for SGI's
#

include $(ROOT)/usr/include/make/commondefs

OPTIMIZER= -g

LCOPTS =  -DXP_UNIX -DPLUGIN_TRACE -nostdinc  -I. -I$(ROOT)/usr/include

LLDLIBS =  -L$(ROOT)/usr/lib -lXm -lXt -lX11 -lgen 

CFILES = npunix.c npshell.c 

SHAREDTARGET=libopenglplugin.so
STATICTARGET=libopenglplugin.a

LDIRT = $(STATICTARGET) $(SHAREDTARGET)


default all: $(SHAREDTARGET)
	@echo 'try "make test" to test it'

$(STATICTARGET): $(OBJECTS)
	$(AR) cruv $(STATICTARGET) $(OBJECTS)

$(SHAREDTARGET): $(STATICTARGET)
	$(CC) $(LDDSOOPTS) -o $(SHAREDTARGET) $(STATICTARGET) $(LDFLAGS)


include $(COMMONRULES)

test:
	NPX_PLUGIN_PATH=`pwd` netscape ./plugin.html


