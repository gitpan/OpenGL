extension=OpenGL

all:
	@echo Nothing to do, this was already built once

test:
	perl -Mblib examples/clip
	perl -Mblib examples/cube
	perl -Mblib examples/depth
	perl -Mblib examples/double
	perl -Mblib examples/fun
	perl -Mblib examples/glu_test
	perl -Mblib examples/light
	perl -Mblib examples/notes
	perl -Mblib examples/plane
	perl -Mblib examples/planets
	perl -Mblib examples/quest
	perl -Mblib examples/simple
	perl -Mblib examples/smooth
	perl -Mblib examples/texhack
	perl -Mblib examples/texture
	perl -Mblib examples/tk_demo
	perl -Mblib examples/try

install:
	perl -MExtUtils::Install -e install_default $(extension)

uninstall:
	perl do_uninst

