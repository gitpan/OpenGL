#!/usr/bin/perl -w

use strict;
use OpenGL qw(:all);

use PDL;
use PDL::Constants qw(PI);
     $PDL::BIGPDL = 1;

my $pending = 0;

#--- init demo data
my $tsl      = 60000; # time slices;
my $channels =  10; # channels to plot

my $time_points  = pdl( sequence( $tsl ) /1000 )->float();
my $f0   = 2; # Hz
my $data = pdl( zeroes($channels,$time_points->dim(-1) ) )->float();

    print"---> START init demo data\n";
    print"     Channels: $channels\n";
    print"     TSLs    : $tsl\n";

my $t00 = time;

my $f    = pdl( sequence($channels) ) +1 * $f0;
  # $data.= (sin( $time_points * $f->transpose *2* PI) )->transpose;
    $data.= (sin( $time_points * $f->transpose * PI) + cos( $time_points
*  $f->transpose * rand(100) * PI ) )->transpose;

    $t00 = time() - $t00;
    print"---> DONE init demo data: $t00\n";


#---------------------------------------------------------#
#---- update_plot_pdl_to_vbo     -------------------------#
#---  copy pdl data to opengl vertex buffer
#---  generates a sub plot for each channel #---------------------------------------------------------#
sub update_plot_pdl_to_vbo{
my ($x,$y) = @_;

    return if ( $pending );
    $pending = 1;
my $t00 = time;

#--- init data for vertex buffer obj
my $data_4_vbo             = pdl( zeroes(2,$data->dim(-1) ) )->float();
my $data_4_vbo_timepoints  = $data_4_vbo->slice("(0),:");
my $data_4_vbo_signal      = $data_4_vbo->slice("(1),:");
    $data_4_vbo_timepoints .= $time_points;
my $data_vbo               = $data_4_vbo->flat;

my $float_size = 4;

    glClear(GL_COLOR_BUFFER_BIT);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glColor3f(0.0,0.0,1.0);

#--- create OGL verts buffer
    glDisableClientState(GL_VERTEX_ARRAY);

my $VertexObjID = glGenBuffersARB_p(1);
    glBindBufferARB(GL_ARRAY_BUFFER_ARB,$VertexObjID);

my $ogl_array = OpenGL::Array->new_scalar(GL_FLOAT,
$data_vbo->get_dataref,$data_vbo->dim(0)*$float_size);
    glBufferDataARB_p(GL_ARRAY_BUFFER_ARB,$ogl_array,GL_DYNAMIC_DRAW_ARB);
    $ogl_array->bind($VertexObjID);
    glVertexPointer_p(2,$ogl_array);
    glEnableClientState(GL_VERTEX_ARRAY);

#---start sub plots
my $w = glutGet( GLUT_WINDOW_WIDTH );
my $h = glutGet( GLUT_WINDOW_HEIGHT );

my $w0 = 10;
my $w1 = $w-10;

my $h0 = 0;
my $dh = int( $h / $data->dim(0) );
my $h1 = $dh;

my $xmin = $time_points->min;
my $xmax = $time_points->max;
my $ymin = $data->min * 1.2;
my $ymax = $data->max * 1.2;


#--- copy data to VBO
    for ( my $i=0; $i < $data->dim(0); $i++ )
     {

#--- sub plot window
       setViewport($w0,$w1,$h0,$h1);
       setWindow($xmin,$xmax,$ymin,$ymax );

#--- draw zero line
       glLineWidth(1);
       glColor3f(1,1,1);

       glBegin(GL_LINES);
         glVertex2f($xmin,0.0);
         glVertex2f($xmax,0.0);
       glEnd();

#--- start drawing signal
       glLineWidth(2);
       glColor3f(rand(1), rand(1),1.0);# mix color for each signal

#--- copy pdl data to VBO thank's vividsnow !!!
       $data_4_vbo_signal .= $data->slice("($i),:");
       $ogl_array =
OpenGL::Array->new_scalar(GL_FLOAT,$data_vbo->get_dataref,$data_vbo->dim(0)*$float_size);

       glBufferSubDataARB_p(GL_ARRAY_BUFFER_ARB,0,$ogl_array);

       glDrawArrays(GL_LINE_STRIP,0,$data_4_vbo_timepoints->dim(-1)-1 );

       $h0 += $dh;
       $h1 += $dh + 1;

      } # for

   glBindBufferARB(GL_ARRAY_BUFFER_ARB, 0);
   glDisableClientState(GL_VERTEX_ARRAY);

   glFlush();
   glutSwapBuffers();

   $pending = undef;

   $t00 = time() - $t00;

   print" done  <update_plot_pdl_to_vbo> Time to update: $t00\n";

} # end of update_plot_pdl_to_vbo


#---------------------------------------------------------#
#---- setWindow                  -------------------------#
#---------------------------------------------------------#
sub setWindow{
my ($l,$r,$b,$t) = @_;
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  gluOrtho2D($l,$r,$b,$t);
} # end of setWindow

#---------------------------------------------------------#
#---- setViewport                -------------------------#
#---------------------------------------------------------#
sub setViewport{
my ($l,$r,$b,$t) = @_;
  glViewport($l,$b,$r-$l,$t-$b);
}# end of setViewport

#---------------------------------------------------------#
#---- myReshape                  -------------------------#
#---------------------------------------------------------#
sub myReshape{

my($w,$h) = @_;

return if (  $pending );

glViewport(0,0,$w,$h);
glMatrixMode(GL_PROJECTION);
glLoadIdentity();
gluOrtho2D(0.0,$w,0.0,$h);

} # end of reshape


#=== MAIN ===============================================
glClearColor(1.0,1.0,1.0,0.0);
glColor3f(0.0,0.0,1.0);
glLineWidth(2);

glutInit();

glutInitDisplayMode(GLUT_DOUBLE | GLUT_RGB | GLUT_ALPHA);

glutInitWindowSize(300,400);
glutInitWindowPosition(10,10);

my $IDwindow = glutCreateWindow("PDL OGL TEST"); glutDisplayFunc( sub{ update_plot_pdl_to_vbo(@_) } );

glutReshapeFunc( sub{ myReshape(@_) } );

glutMainLoop();
