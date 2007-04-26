#include <stdio.h>
#include "../include/GL/glut.h"

#define PROGRAM "glversion"

int main(int argc, char **argv)
{
  char *version = NULL;
  char *vendor = NULL;
  char *renderer = NULL;
  char *extensions = NULL;
  GLuint idWindow = 0;

  glutInit(&argc, argv);
  glutInitWindowSize(1,1);
  //glutInitDisplayMode(GLUT_DOUBLE | GLUT_RGBA | GLUT_DEPTH | GLUT_ALPHA);
  glutInitDisplayMode(GLUT_RGBA);
  idWindow = glutCreateWindow(PROGRAM);
  glutHideWindow();

  version =     (char*)glGetString(GL_VERSION);
  vendor =      (char*)glGetString(GL_VENDOR);
  renderer =    (char*)glGetString(GL_RENDERER);
  extensions =  (char*)glGetString(GL_EXTENSIONS);

  printf("VERSION=%s\nVENDOR=%s\nRENDERER=%s\nEXTENSIONS=%s\n",
    version,vendor,renderer,extensions);

  glutDestroyWindow(idWindow);
  return(0);
}
