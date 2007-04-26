#!nmake

CC=cl.exe
#CCFLAGS=/nologo /ML /W3 /D "WIN32" /D "_CONSOLE" /c 
CCFLAGS=/nologo /D "WIN32" /c 
LINK=link.exe
LDFLAGS=/nologo /subsystem:console /incremental:no /machine:I386 

all: glversion.txt

clean:
	-@erase glversion.txt"
	-@erase glversion.exe"
	-@erase glversion.obj"

glversion.txt: glversion.exe
	glversion > glversion.txt

glversion.exe: glversion.obj
	$(LINK) $(LDFLAGS) /out:"glversion.exe" glversion.obj

glversion.obj: glversion.c makefile.mak
	$(CC) $(CCFLAGS) glversion.c
