# unshadowimage.pl

This program uses three different algorithms to try to remove shadows in art photography.
All algorithms analyses the gray scale value from the image's borders to build a map and
equalize the white level on the whole image. Therefore, the image must have a white
background and a white border big enough.

The algorithms are xborder, yborder and plane. The first two are simple and build a one
direction shadow map, either vertical (yborder) or horizontal (xborder). They work if the
shadow is directional. This usually occurs when the photograph was taken with light
comming from on direction and is uniform on the other direction. The plane algorithm is
more complex (and slower) and build a shadow map comparing all gray scale levels on the
borders around the image. The shadow map is a 128 by 128 grid containing the average
white level around each point.

To work, unshadowimage must be informed the image's white border size by `--samples=N` or
by detecting automatically using a the CannyEdge detection algorithm from ImageMagick
perl library. The CannyEdge detection is used with the default settings: `0x1+10%+30%`.

The goal is to remove unwanted shadows from artwork photography and try to fix the image
to a flat white balance background (border). Unfortunatelly even with good lighting,
very suttle shadows can ocur then photographing paper or white canvas.

## License

This software is distributed under the MIT license. Please read
LICENSE for information on the software availability and distribution.

## Dependencies

unshadowimage.pl has the following dependencies:

* [ImageMagick's perl library and command line convert utility](http://www.imagemagick.org/script/perl-magick.php)

* [GD perl library](https://metacpan.org/pod/GD)

* [JSON perl library](https://metacpan.org/pod/JSON)

* [IPC::Open3 library](https://metacpan.org/pod/IPC::Open3)

* [Gnuplot (only for the 3D surface chart)](http://www.gnuplot.info/documentation.html)

## Pre-requisites

To work, unshadowimage.pl must have the following pre-requisites:

* Image with a white background

* Image croped without margins except the white border around the subject

* A big enough border around the image's contents to analyse the shadow. I suggest
at least 50 pixels all around (top, bottom, left and right).

## Command line arguments

  --analysis algorithm  
  -a=algorithm  

      Specify the algorithm used to build the shadow map and fix the image. Options
      are xborder, yborder or plane. Default is plane.
  
  --output file  
  -o=file

      Filename to write the image output to. If not specified, write to
      filename_algorithm.jpg. Default is not specified.

  --quality N  
  -q=N

      Set the JPEG output quality for the result. Default is 95.

  --goal N  
  -g=N

      The white level aimed for the unshadow treatment (0-255). A value of 255 is
      total white. Default is 255. 

  --samples detect|N  
  -s=detect|N

      Number of sample lines to use on the image border to build the shadow map.
      The greater the number, the better the shadow map. But N should not be greater
      than the white border around the image's content or value from image's content
      will be considered white and skew off the shadow map. If 'detect' is used,
      the program will use ImageMagick's perl library to detect the image's edge
      automatically. In this case, using a safe border is recommended. Default is
      10, but this value is very low.

  --smooth N

      Value to average and smooth out the shadow map when using xborder or yborder
      to avoid sudden changes to the gray levels of the output. Default is 20.

  --chart

      If set, a PNG chart will be written as filename_alg_shadowmap.png where alg
      is the first letter of the algorithm used (x, y or p). For x or y borders,
      the chart is a single line showing the shadow's profile. For plane the chart
      is a 3D surface plot showing the shadow samples over the border and interpolated
      over the image's contents. Useful to see of the interpolation will work.

  --chartwidth N

      Chart width in pixels, Default is 1920.
  
  --chartheight N

      Chart height in pixels, Default is 1080.
  
  --save file

      Save the edge and shadow information to a file. The saved file can be loaded
      later to use the same setting on different images. Default is not save.

  --load file

      Load the edge and shadow information from a file. The information must have
      been writen earlier by unshadowimage.pl. Default is not load.

  --verbose

      Verbose mode, show messages.

  --help

      Show this help.

## Examples

Original photographed drawing used on the following examples:

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing.jpg" alt="drawing.jpg" width="800" border="1"/>

### Example using yborder

`unshadowimage.pl --analysis=yborder --goal=225 --samples=90 --smooth=35 --chart -v drawing.jpg`

> Use the yborder algorithm on drawing.jpg using a 90 pixels wide border around the image
> to reduce shadows in the vertical direction.
> Write the vertical shadow profile chart to `drawing_y_shadowmap.png`:

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_y_shadowmap.png" alt="Vertical shadow profile" width="800"/>

> The result is save in `drawing_yborder.jpg`:

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_yborder.jpg" alt="YBorder result" width="800" border="1"/>

### Example using xborder

`unshadowimage.pl --analysis=xborder --goal=225 --samples=90 --smooth=35 --chart -v drawing.jpg`

> Use the xborder algorithm on drawing.jpg using a 90 pixels wide border around the image
> to reduce shadows in the horizontal direction.

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_x_shadowmap.png" alt="Horizontal shadow profile" width="800"/>

> Write the horizontal shadow profile chart to drawing_x_shadowmap.png (above).

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_xborder.jpg" alt="XBorder result" width="800" border="1"/>

> The result is save in `drawing_yborder.jpg` (above).

### Example using plane

`unshadowimage.pl --analysis=plane --goal=225 --samples=detect --chart -v --debug drawing.jpg`

> Use the plane algorithm on drawing.jpg using an automatically detected border (edge)
> to reduce shadows using a 2D plane interpolating the image pixels using a saddle
> function combined with the white levels of the image's edge pixels. Write the 2D
> shadow map to `drawing_p_shadowmap.png`:

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_p_shadowmap.png" alt="Plane shadow profile" width="800"/>

> Because the `--debug` argument was specified, the edge detection result image will
> be saved to `drawing_edgedetect.png`:

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_edgedetect.png" alt="Edge detect result" width="800"/>

> Write the result to `drawing_plane.jpg`:

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/drawing_plane.jpg" alt="Plane result" width="800" border="1"/>

## 2D Interpolation

The plane algorithm fist builds a shadow map using the pixels in the white border edge
of the image (either by detecting it or by using the samples argument). When using
detection is recommended to use a safe border of at least 20 pixels, maybe more if the
border is big enough.

<img src="https://raw.githubusercontent.com/rorabr/unshadowimage/master/images/saddle_func.png" alt="Saddle Function" width="800"/>

After building the map, a interpolation is used to "guess" the gray scale value of the
shadow map over the image's contents. This has to be done by interpolation because the
actual pixels cannot be used to compare brightness level to the white background. The
best way I could come up with was to use a warped saddle function (x² - y²). This
functions returns the ratio between the x and y linear interpolation.

### Gnuplot source of the saddle chart above

    set title "Saddle Function"
    set terminal pngcairo enhanced font "arial,10" fontscale 1.0 size 1024, 768
    set grid
    set output "images/saddle_func.png"
    set style data lines
    set datafile missing "?"
    set isosample 32
    set xrange [-1:1]
    set yrange [-1:1]
    set xyplane at -0.5
    min(a,b) = a < b ? a : b
    max(a,b) = a > b ? a : b
    splot min(max((x**2 - y**2) * 1.2, -0.5), 0.5) with lines notitle

## Chart

The chart is a tool to check how the shadows will be fixed. The charts for the x and y
border algorithms show the profile that will be used to change the white balance on the
line or column of the image.

The plane chart shows the actual white level on the image.

In both cases the correction is applied by multiplying the R, G and B components by
goal / level, where goal is an argument and level is the white level at that image
point (line, column or grid).

## Save and Load information

The `--load` and `--save` arguments can be used to save the shadow information
to a file to be used later on another image. This can be usefull to process
a different image using the same shadow profile. The information is save in JSON
format without compressing.

By using the saved profile an image without any border can be processed based on
the shadow profile obtained by photographing a white paper. But is important to
note that all the photo configurations must be kept exactly the same. Cameras that
compensate white ballance, speed and apperture automatically won't work. Check if
your camera has a manual mode. Also lighting has to be the same. If natural light
is used, the time and cloud coverage must be the same.

## Bugs and Style

This program does not conform to my level of requirement I usually follow. But in this
case I had to finish it in a few days to correct images for an art photografy session.
There are some lame implementation and low performance loops that I decided not to
change because it worked fast enough for what I needed. There are not a lot of argument
and boundary checks, so keep options to a normal and modest level. Sorry... maybe I'll
refactory it later.

This program works better with B&W images.

## TODO

* Improve the code

* Create a better 2D internpolation algorithm

* Implement a color balance

* Create a grid size argument to change the grid size

## Author

unshadowimage.pl was written by Rodrigo Antunes, [rorabr@github](https://github.com/rorabr/unshadowimage), [https://rora.com.br](https://rora.com.br)

