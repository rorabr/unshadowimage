#!/usr/bin/perl -I.
#
# unshadow image - remove linear shadows in photographed images - RORA - BH - 2020-01-08

use Getopt::Long;
use Data::Dumper;
use Pod::Usage;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use JSON;
use IO::File;
use IPC::Open3;
use GD;
use Image::Magick;
use strict;

# defaults
my %args_defaults=(
      output => "",                     # specify output file, if "" generate other filename
      quality => 95,                    # quality for JPG write
      goal => 225,                      # white level to normalize final image (0:black - 255:white)
      analysis => "plane",              # use plane analyser - best so far
      planex => 128,                    # for plane analyser, size of the x grid
      planey => 128,                    # for plane analyser, size of the y grid
      #border => 0,                      # number of pixel to remove from all borders of the image
      detectborder => 20,               # pixels to add to the detected edge (to safeguard lost pixels)
      samples => 10,                    # number of samples from each border
      smooth => 20,                     # moving average smooth factor for the sample line
      chart => 0,                       # if 1, generate a line chart with the sample data
      chartwidth => 1920,               # chart width
      chartheight => 1080,              # chart height
      gnuplot => "/usr/bin/gnuplot",    # gnuplot binary
      save => "",                       # file to save shadow levels to
      load => "",                       # file to load shadow levels from
      help => 0,
      verbose => 0,
      #args_file => $ENV{HOME} . "/.unshadowimage",
    );
# parse command line
if (-f $args_defaults{args_file} && -r $args_defaults{args_file}) {
  my $h = decode_json(`cat $args_defaults{args_file}`);
  for my $k (keys %{$h}) {
    $args_defaults{$k} = $h->{$k} if (exists $args_defaults{$k});
  }
}
my @args_syntax=(qw/output|o:s quality|q:i goal|g:f analysis|a:s samples|s:s smooth:i chart|c chartwidth:i chartheight:i save:s load:s help|h debug+ verbose|v+/);
my $parser = Getopt::Long::Parser->new; $|=1;
if (! $parser->getoptions(\%args_defaults, @args_syntax) || $args_defaults{help}) {
  pod2usage(-exitval=>1, -verbose=>1);
}
my $self=bless({%args_defaults}, __PACKAGE__);
croak("invalid quality setting") if ($self->{quality}<1 || $self->{quality}>99);
for my $f (@ARGV) {
  $self->unshadow($f);
}

# unshadow an image
sub unshadow {
  my($self, $f)=@_;
  ($self->{dir}, $self->{filename}, $self->{ext}) = $f =~ /^(.*\/)?([^\.\/]+)\.([^\.\/]+)$/;
  my $img = GD::Image->new($f);
  print "$f loaded, " . $img->width . " by " . $img->height . " pixels containing " . $img->colorsTotal . " color indexes\n" if ($self->{verbose});
  my $analyser = $self->factory($self->{analysis}, "img" => $img, %{$self});
  if ($self->{load} ne "") {
    die("$0 error: $self->{load} file not found to load analyser data from") if (! -f $self->{load});
    $analyser->load($self->{load});
  } else {
    my $edge;
    if ($self->{samples} eq "detect") {
      my $edgedetect = Unshadow_EdgeDetect->new(%{$self}, "img" => $img);
      $edge = $edgedetect->detect; # return the drawing coords
    } elsif ($self->{samples} =~ /^\d+$/) {
      print "Using image edge with $self->{samples} lines/pixels from the borders\n" if ($self->{verbose});
      $edge = { x0 => $self->{samples}, y0 => $self->{samples}, x1 => $img->width - $self->{samples}, y1 => $img->height - $self->{samples} };
    } else {
      die("$0 error: invalid samples (either inform an integer or 'detect')");
    }
    $analyser->{edge} = $edge;
    $analyser->sample;
    if ($self->{save} ne "" && $self->{load} eq "") {
      $analyser->save($self->{save});
    }
  }
  $analyser->chart("$self->{dir}$self->{filename}_" . substr($self->{analysis}, 0, 1) . "_shadowmap.png") if ($self->{chart});
  my $new = GD::Image->new($img->width, $img->height, 1);
  $new->colorAllocate(255, 255, 255);
  $analyser->fix($new);
  my $n = $self->{output} ne "" ? $self->{output} : $self->{dir} . $self->{filename} . "_" . $self->{analysis} . ".jpg";
  my $h = IO::File->new($n, "w") || die("$0 error writing to $n: $!");
  $h->syswrite($new->jpeg($self->{quality}));
  $h->close;
  print "New image writen to $n\n";
}

# unshadow analysers factory
sub factory {
  my $self = shift;
  my $a = shift;
  if ($a eq "xborder") {
    return Unshadow_xborder->new(@_);
  } elsif ($a eq "yborder") {
    return Unshadow_yborder->new(@_);
  } elsif ($a eq "plane") {
    return Unshadow_plane->new(@_);
  }
  die("$0 error: unknown unshadow analyser \"$a\"");
}

1;

package Unshadow_base;

use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use Statistics::LineFit;
use Chart::Lines;
use GD;
use IPC::Open3;
use JSON;
use strict;

sub new {
  my $class=shift;
  bless({@_}, $class);
}

# Sample a line
sub sampleLine {
  my($self, $x0, $y0, $dx, $dy, $n)=@_;
  my $xi = $x0;
  my $yi = $y0;
  for (my $i = 0; $i < $n; $i++) {
    my $cindex = $self->{img}->getPixel($xi, $yi);
    my ($r, $g, $b) = $self->{img}->rgb($cindex);
    $self->{line}->[$i] += ($r + $g + $b);
    $xi += $dx;
    $yi += $dy;
  }
}

# Return the gray scale ranges (min, max) for any line
sub rangeLine {
  my($self, $x0, $y0, $dx, $dy, $n)=@_;
  $self->sampleLine($x0, $y0, $dx, $dy, $n);
  my $min = 1<<20;
  my $max = -1;
  for (my $i = 0; $i < $#{$self->{line}}; $i++) {
    if ($self->{line}->[$i] > $max) { $max = $self->{line}->[$i]; }
    elsif ($self->{line}->[$i] < $min) { $min = $self->{line}->[$i]; }
  }
  return($min, $max);
}

# Sample a group of lines than average the results
sub sampleLines {
  my($self, $origin, $dx, $dy, $n) = @_;
  print "Calculating pixel samples for $n lines\n" if ($self->{verbose});
  my $count = $#{$origin} + 1;
  my $p = 0;
  for (my $i = 0; $i < $count; $i++) {
    $self->sampleLine($origin->[$i]->{x}, $origin->[$i]->{y}, $dx, $dy, $n);
    $p += $n;
  }
  $count *= 3.0;
  $self->{min} = 1e20;
  $self->{max} = -1;
  for (my $i = 0; $i < $n; $i++) {
    $self->{line}->[$i] /= ($count);
    if ($self->{line}->[$i] < $self->{min}) { $self->{min} =  $self->{line}->[$i];}
    if ($self->{line}->[$i] > $self->{max}) { $self->{max} =  $self->{line}->[$i];}
    $self->{coord}->[$i] = ($dy == 0 ? $origin->[0]->{x} + $i : $origin->[0]->{y} + $i);
  }
  printf("%d pixels sampled, gray range: %.2f - %.2f\n", $p, $self->{min}, $self->{max}) if ($self->{verbose}); 
  $self->smooth2($n);
}

# Smooth out the sample line using the smooth factor
sub smooth {
  my($self, $n)=@_;
  my $w = $self->{smooth};
  my $mem;
  for (my $i = 0; $i < $w; $i ++) { $mem->[$i] = $self->{line}->[0]; }
  my $avg = $self->{line}->[0] * $w;
  my $k = 0;
  for (my $i = 0; $i < $n; $i ++) {
    $avg = $avg + $self->{line}->[$i] - $mem->[($i + $w - 1) % $w];
    $mem->[$i % $w] = $self->{line}->[$i];
    if ($k >= 0) {
      $self->{line2}->[$k] = $avg / $w;
    }
    $k ++;
  }
  while ($k < $n) {
    $avg = $avg + $self->{line}->[$n - 1] - $mem->[($k + $w - 1) % $w];
    $self->{line2}->[$k] = $avg / $w;
    $k ++;
  }
}

sub smooth2 {
  my($self, $n)=@_;
  my $h = int($self->{smooth} / 2);
  for (my $i = 0; $i < $n; $i ++) {
    my $sum = 0;
    my $q = 0;
    for (my $j = $i - $h; $j < $i + $h; $j++) {
      if ($j >=0 && $j < $n) {
        $sum += $self->{line}->[$j];
        $q++;
      }
    }
    $self->{line2}->[$i] = $sum / $q;
  }
}

# Average gray level of neighboring pixels at $x,$y diamond-radius $r
sub averagePixel {
  my($self, $x, $y, $r, $edge)=@_;
  my $q = 0;
  my $n = 0;
  my $w = $self->{img}->width;
  my $h = $self->{img}->height;
  for (my $xi = -$r; $xi <= $r; $xi ++) {
    for (my $yi = -$r; $yi <= $r; $yi ++) {
      if ($x + $xi >= 0 && $x + $xi < $w && $y + $yi >= 0 && $y + $yi < $h && abs($xi) + abs($yi) <= $r && ! ($x >= $edge->{x0} && $y >= $edge->{y0} && $x <= $edge->{x1} && $y <= $edge->{y1})) {
        my $c = $self->{img}->getPixel($x + $xi, $y + $yi);
        my ($r, $g, $b) = $self->{img}->rgb($c);
        $q += ($r + $g + $b) / 3;
        $n ++;
      }
    }
  }
  return($q / $n);
}

# Generate a line chart of the line sample data
sub chart {
  my($self, $f)=@_;
  my $colors={grid_lines=>"gray"};
  my $graph={title=>"Pixel samples", legend=>"none", precision=>1, x_grid_lines=>"true", y_grid_lines=>"true", skip_x_ticks=>int($self->{img}->width / ($self->{chartwidth} / 60)), colors=>$colors};
  my $obj = Chart::Lines->new ($self->{chartwidth}, $self->{chartheight});
  $obj->set(%{$graph});
  my $data=[$self->{coord}, $self->{line}, $self->{line2}];
  $obj->png($f, $data);
}

# Fix shadow in one line
sub fixLine {
  my($self, $f, $x0, $y0, $dx, $dy, $n, $new)=@_;
  my $xi = $x0;
  my $yi = $y0;
  for (my $i = 0; $i < $n; $i ++) {
    my $cindex = $self->{img}->getPixel($xi, $yi);
    my ($r, $g, $b) = $self->{img}->rgb($cindex);
    $r = int($r * $f); $r > 255 ? $r = 255 : 0;
    $g = int($g * $f); $g > 255 ? $g = 255 : 0;
    $b = int($b * $f); $b > 255 ? $b = 255 : 0;
    my $newc = $new->colorExact($r, $g, $b);
    if ($newc == -1) {
      $newc = $new->colorAllocate($r, $g, $b);
    }
    $new->setPixel($xi, $yi, $newc);
    $xi += $dx;
    $yi += $dy;
  }
}

# Fix shadow using the smothed sampled curve
sub fixLines {
  my($self, $dir, $new)=@_;
  print "Fixing shadows in the $dir orientation\n" if ($self->{verbose});
  if ($dir eq "x") { # left-right orientation
    for (my $i = 0; $i < $self->{img}->width; $i ++) {
      my $f = $self->{goal} / $self->{line2}->[$i];
      $self->fixLine($f, $i, 0, 0, 1, $self->{img}->height, $new);
    }
  } else { # top-down orientation
    for (my $i = 0; $i < $self->{img}->height; $i ++) {
      my $f = $self->{goal} / $self->{line2}->[$i];
      $self->fixLine($f, 0, $i, 1, 0, $self->{img}->width, $new);
    }
  }
}

# Save analyser data
sub save {
  my($self, $f)=@_;
  my $d = {data => $self->{data}, edge => $self->{edge}, minz => $self->{minz}, maxz => $self->{maxz}};
  my $h = IO::File->new($f, "w") || die("$0 error writing to $f: $!");
  $h->syswrite(encode_json($d));
  $h->close;
  print "Shadow gray levels and edge info saved to $f\n" if ($self->{verbose});
}

# Load analyser data
sub load {
  my($self, $f)=@_;
  my $h = IO::File->new($f, "r") || die("$0 error reading from $f: $!");
  my $buf;
  $h->sysread($buf, -s $f);
  $h->close;
  my $d = decode_json($buf);
  $self->{data} = $d->{data};
  $self->{minz} = $d->{minz};
  $self->{maxz} = $d->{maxz};
  $self->{edge} = $d->{edge};
}

# run something and return stdout
sub runprocess {
  my $self=shift;
  my $input=shift;
  my $pid=open3(my $wh, my $rh, undef, @_);
  my $out;
  print $wh $input;
  close($wh);
  while (my $line=<$rh>) {
    $line=~s/[\r\n]*$//gs;
    push @{$out},(&ctrl($line));
  }
  close($rh);
  waitpid($pid,0);
  return($out);
}

sub ctrl {
  my($s)=@_;
  $s=~s/([\0-\x1f\x7e-\xff])/"(".unpack("H2",$1).")"/gse;
  return($s);
}

1;

package Unshadow_xborder;

# Remove shadows in the left-right orientation

use base 'Unshadow_base';
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use GD;
use strict;

# Sample horizontal lines
sub sample {
  my($self)=@_;
  my $origin = [];
  # sample lines from the top
  for (my $i = 0; $i < $self->{samples}; $i++) {
    push @{$origin}, ({x => 0, y => $i});
  }
  # sample lines from the bottom
  for (my $i = 0; $i < $self->{samples}; $i++) {
    push @{$origin}, ({x => 0, y => $self->{img}->height - $i - 1});
  }
  $self->sampleLines($origin, 1, 0, $self->{img}->width);
}

# Fix shadow using the smothed sampled curve
sub fix {
  my($self, $new)=@_;
  $self->fixLines("x", $new);
}

1;

package Unshadow_yborder;

# Remove shadows in the top-down orientation

use base 'Unshadow_base';
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use GD;
use strict;

# Sample vertical lines
sub sample {
  my($self)=@_;
  my $origin = [];
  # sample lines from the left
  for (my $i = 0; $i < $self->{samples}; $i++) {
    push @{$origin}, ({x => $i, y => 0});
  }
  # sample lines from the right
  for (my $i = 0; $i < $self->{samples}; $i++) {
    push @{$origin}, ({x => $self->{img}->width - $i - 1, y => 0});
  }
  $self->sampleLines($origin, 0, 1, $self->{img}->height);
}

# Fix shadow using the smothed sampled curve
sub fix {
  my($self, $new)=@_;
  $self->fixLines("y", $new);
}

1;

package Unshadow_EdgeDetect;

use base 'Unshadow_base';
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use GD;
use Image::Magick;
use strict;

sub new {
  my $class=shift;
  bless(Unshadow_base->new(edgeThreshold => 4, @_), $class);
}

# Detect image edge comparing gray value to the threshold, return the drawing coords x0, y0 - x1, y1
sub detect {
  my($self)=@_;
  my $image = Image::Magick->new;
  my $n = $image->BlobToImage($self->{img}->png);
  die("no image imported by Image::Magick->BlobToImage()") if ($n < 1);
  $image->CannyEdge("0x1+10\%+30\%");
  if ($self->{debug}) {
    $image->Write("$self->{dir}$self->{filename}_edgedetect.png");
  }
  $self->{img} = GD::Image->new($image->ImageToBlob());
  my($min, $max);
  my $y0 = -1;
  do {
    $y0 ++;
    $self->{line} = [];
    ($min, $max) = $self->rangeLine(0, $y0, 1, 0, $self->{img}->width);
  } while ($y0 < $self->{img}->height && $max < $self->{edgeThreshold});
  my $y1 = $self->{img}->height;
  do {
    $y1 --;
    $self->{line} = [];
    ($min, $max) = $self->rangeLine(0, $y1, 1, 0, $self->{img}->width);
  } while ($y1 > $y0 && $max < $self->{edgeThreshold});
  my $x0 = -1;
  do {
    $x0 ++;
    $self->{line} = [];
    ($min, $max) = $self->rangeLine($x0, $y0, 0, 1, $y1 - $y0 + 1);
  } while ($x0 < $y1 && $max < $self->{edgeThreshold});
  my $x1 = $self->{img}->width;
  do {
    $x1 --;
    $self->{line} = [];
    ($min, $max) = $self->rangeLine($x1, $y0, 0, 1, $y1 - $y0 + 1);
  } while ($x1 > $x0 && $max < $self->{edgeThreshold});
  $x0 = $x0 - $self->{detectborder} < 0 ? 0 : $x0 - $self->{detectborder};
  $y0 = $y0 - $self->{detectborder} < 0 ? 0 : $y0 - $self->{detectborder};
  $x1 = $x1 + $self->{detectborder} >= $self->{img}->width ? $self->{img}->width : $x1 + $self->{detectborder};
  $y1 = $y1 + $self->{detectborder} >= $self->{img}->height ? $self->{img}->height : $y1 + $self->{detectborder};
  print "Edge detected: top 0-$y0 bottom $y1-" . $self->{img}->height . " left 0-$x0 right $x1-" . $self->{img}->width . ", image at $x0,$y0-$x1,$y1\n" if ($self->{verbose});
  return({x0 => $x0, y0 => $y0, x1 => $x1, y1 => $y1});
}

1;

package Unshadow_plane;

use base 'Unshadow_base';
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use JSON;
use GD;
use IO::File;
use Image::Magick;
use strict;

# Build the 2d shadow plane map by sampling points outside the edge
sub build {
  my($self)=@_;
  my $qx = $self->{img}->width / ($self->{planex} - 1);
  my $qy = $self->{img}->height / ($self->{planey} - 1);
  my $qr = int($qx / 2);
  my $minz = 1e20;
  my $maxz = -1;
  for (my $j = 0; $j < $self->{planey}; $j ++) {
    for (my $i = 0; $i < $self->{planex}; $i ++) {
      my $x = int($i * $qx);
      my $y = int($j * $qy);
      if (! ($x >= $self->{edge}->{x0} && $x <= $self->{edge}->{x1} && $y >= $self->{edge}->{y0} && $y <= $self->{edge}->{y1})) {
        my $v = $self->averagePixel($x, $y, $qr, $self->{edge});
        if ($v > $maxz) { $maxz = $v; } elsif ($v < $minz) { $minz = $v; }
        $self->{data}->[$j]->[$i] = $v;
      } else {
        $self->{data}->[$j]->[$i] = -1;
      }
    }
  }
  $self->{minz} = $minz;
  $self->{maxz} = $maxz;
  printf("Shadow grid $self->{planex} by $self->{planey} built from original image, gray scale range %.1f to %.1f\n", $self->{minz}, $self->{maxz}) if ($self->{verbose});
}

# Interpolate the 2d shadow plane to include the image part
sub interpolate {
  my($self)=@_;
  # find drawing borders
  my($mx0, $my0, $mx1, $my1);
  for (my $y = 0; $y <= $#{$self->{data}}; $y ++) {
    for (my $x = 0; $x <= $#{$self->{data}->[$y]}; $x ++) {
      if ($self->{data}->[$y]->[$x] == -1) {
        if (! defined $mx0 || $x < $mx0) { $mx0 = $x; }
        if (! defined $my0 || $y < $my0) { $my0 = $y; }
        if (! defined $mx1 || $x > $mx1) { $mx1 = $x; }
        if (! defined $my1 || $y > $my1) { $my1 = $y; }
      }
    }
  }
  # interpolate missing values
  my $dx = $mx1 - $mx0;
  my $dy = $my1 - $my0;
  my $midx = $dx / 2;
  my $midy = $dy / 2;
  my $warp = 1.2;
  my $n = 0;
  for (my $y = $my0; $y <= $my1; $y ++) {
    for (my $x = $mx0; $x <= $mx1; $x ++) {
      my $zx0 = $self->{data}->[$y]->[$mx0 - 1];
      my $zx1 = $self->{data}->[$y]->[$mx1 + 1];
      my $zy0 = $self->{data}->[$my0 - 1]->[$x];
      my $zy1 = $self->{data}->[$my1 + 1]->[$x];
      my $ratio = ((($x - $mx0 - $midx) / $midx) ** 2 - (($y - $my0 - $midy) / $midy) ** 2) * $warp;
      $ratio = ($ratio > 0.5 ? 0.5 : ($ratio < -0.5 ? -0.5 : $ratio)) + 0.5;
      my $zx = $zx0 * (1 - (($x - $mx0) / $dx)) + $zx1 * (($x - $mx0) / $dx);
      my $zy = $zy0 * (1 - (($y - $my0) / $dy)) + $zy1 * (($y - $my0) / $dy);
      my $z = $zx * $ratio + $zy * (1 - $ratio);
      $self->{data}->[$y]->[$x] = $z;
      $n++;
    }
  }
  print "$n points interpolated using saddle surface warped by $warp\n" if ($self->{verbose});
}

# Sample points from the edge and then interpolate the shadow over the drawing
sub sample {
  my($self)=@_;
  die("$0 error: edge not specified for plane analyser\n") if (! defined $self->{edge});
  $self->build;
  $self->interpolate;
}

# Plot a 2d surface chart using gnuplot of the shadow levels (receives edge detected image)
# source: http://gnuplot.sourceforge.net/demo/surface1.html
sub chart {
  my($self, $f)=@_;
  die("$0 error: gnuplot not found for surface chart") if (! -x $self->{gnuplot});
  my $minz = $self->{minz};
  my $maxz = $self->{maxz};
  my $grid = "";
  my $idata = "";
  my $qx = $self->{img}->width / $#{$self->{data}->[0]};
  my $qy = $self->{img}->height / $#{$self->{data}};
  for (my $y = 0; $y <= $#{$self->{data}}; $y++) {
    for (my $x = 0; $x <= $#{$self->{data}->[$y]}; $x++) {
      if ($x * $qx >= $self->{edge}->{x0} && $x * $qx <= $self->{edge}->{x1} && $y * $qy >= $self->{edge}->{y0} && $y * $qy <= $self->{edge}->{y1}) {
        $grid .= "?       ";
        $idata .= sprintf("%7.3f ", $self->{data}->[$y]->[$x]);
      } else {
        $grid .= sprintf("%7.3f ", $self->{data}->[$y]->[$x]);
        $idata .= "?       ";
      }
    }
    $grid .= "\n";
    $idata .= "\n";
  }
  my $gnuplot =<<EOM;
set title "Shadow levels of detected edge"
set terminal pngcairo enhanced font "arial,10" fontscale 1.0 size $self->{chartwidth}, $self->{chartheight}
set grid
set output "$f"
set style data lines
set datafile missing "?"
\$grid << EOD
$grid
EOD
\$idata << EOD
$idata
EOD
#set zrange [$minz:$maxz] noreverse nowriteback
set xyplane at $minz
splot '\$grid' matrix with lines notitle, '\$idata' matrix with lines notitle
EOM
  if ($self->{debug}) {
    my $h = IO::File->new("$f.gnuplot", "w");
    $h->syswrite($gnuplot);
    $h->close;
  }
  my $out = $self->runprocess($gnuplot, $self->{gnuplot});
  if ($self->{debug}) {
    for my $line (@{$out}) {
      print "gnuplot> $line\n";
    }
  }
  print "Shadow gray level surface plot writen to $f\n" if ($self->{verbose});
}

# Fix the image shadows using the shadow data and interpolated using bi-linear interpolationo
sub fix {
  my($self, $new)=@_;
  my $qx = $self->{img}->width / ($self->{planex} - 1);
  my $qy = $self->{img}->height / ($self->{planey} - 1);
  for (my $y = 0; $y < $self->{img}->height; $y++) {
    for (my $x = 0; $x < $self->{img}->width; $x++) {
      my $px = int($x / $qx);
      my $py = int($y / $qy);
      my $shadow = $self->bilinear($x - ($px * $qx), $y - ($py * $qy), $qx, $qy, $self->{data}->[$py]->[$px], $self->{data}->[$py]->[$px+1], $self->{data}->[$py+1]->[$px], $self->{data}->[$py+1]->[$px+1]);
      my $f = $self->{goal} / $shadow;
      my $cindex = $self->{img}->getPixel($x, $y);
      my ($r, $g, $b) = $self->{img}->rgb($cindex);
      $r = int($r * $f); $r > 255 ? $r = 255 : 0;
      $g = int($g * $f); $g > 255 ? $g = 255 : 0;
      $b = int($b * $f); $b > 255 ? $b = 255 : 0;
      my $newc = $new->colorExact($r, $g, $b);
      if ($newc == -1) {
        $newc = $new->colorAllocate($r, $g, $b);
      }
      $new->setPixel($x, $y, $newc);
    }
  }
}

# Bi-linear interpolation between x0, y0 and x1, y1
# source: https://en.wikipedia.org/wiki/Bilinear_interpolation
# (x,y) coords (sx,sy) square size, (x0y0, x1y0, x0y1, x1y1) data in the 4 corners
sub bilinear {
  my($self, $x, $y, $sx, $sy, $x0y0, $x1y0, $x0y1, $x1y1)=@_;
  my $iy0 = ($sx - $x) / $sx * $x0y0 + $x / $sx * $x1y0;
  my $iy1 = ($sx - $x) / $sx * $x0y1 + $x / $sx * $x1y1;
  return(($sy - $y) / $sy * $iy0 + $y / $sy * $iy1);
}

# Fix shadow in one line
sub fixLine {
  my($self, $f, $x0, $y0, $dx, $dy, $n, $new)=@_;
  my $xi = $x0;
  my $yi = $y0;
  for (my $i = 0; $i < $n; $i ++) {
    my $cindex = $self->{img}->getPixel($xi, $yi);
    my ($r, $g, $b) = $self->{img}->rgb($cindex);
    $r = int($r * $f); $r > 255 ? $r = 255 : 0;
    $g = int($g * $f); $g > 255 ? $g = 255 : 0;
    $b = int($b * $f); $b > 255 ? $b = 255 : 0;
    my $newc = $new->colorExact($r, $g, $b);
    if ($newc == -1) {
      $newc = $new->colorAllocate($r, $g, $b);
    }
    $new->setPixel($xi, $yi, $newc);
    $xi += $dx;
    $yi += $dy;
  }
}

# Gnuplot script to generate the saddle_func.png image used on README.md:
#set title "Saddle Function"
#set terminal pngcairo enhanced font "arial,10" fontscale 1.0 size 1024, 768
#set grid
#set output "images/saddle_func.png"
#set style data lines
#set datafile missing "?"
#set isosample 32
#set xrange [-1:1]
#set yrange [-1:1]
#set xyplane at -0.5
#min(a,b) = a < b ? a : b
#max(a,b) = a > b ? a : b
#splot min(max((x**2 - y**2) * 1.2, -0.5), 0.5) with lines notitle

1;

__END__

=head1 NAME

unshadowimage.pl - Remove shadows from art photography images

=head1 SYNOPSIS

  unshadowimage.pl [--analysis|a=algorithm] [--output|o=file] [--quality|q=N] [--goal|g=N]
    [--samples|s=detect|N] [--smooth=N] [--chart] [--chartwidth=N] [--chartheight=N]
    [--debug] [--verbose] [--help] 

=head OPTIONS

Options:

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

=head1 DESCRIPTION

This program uses three different algorithms to try to remove shadows in art photography.
All algorithms analyses the gray scale value from the image's borders to build a map and
equalize the white level on the whole image. Therefore, the image must have a white
background and a white border big enough.

The algorithms are xborder, yborder and plane. The first two are simple and build a one
direction shadow map, either vertical (yborder) or horizontal (xborder). They work if the
shadow is directional. This usually occurs when the photograph was taken with light
comming from on direction and is uniform on the other direction. The plane algorithm is
more complex (and slower) and build a shadow map comparing all gray scale levels on the
borders around the image.

To work, unshadowimage must be informed the image's white border size by --samples=N or
by detecting automatically using a the CannyEdge detection algorithm from ImageMagick
perl library.

The goal is to remove unwanted shadows from artwork photography and try to fix the image
to a flat white balance background (border). Unfortunatelly even with good lighting,
very suttle shadows can ocur then photographing paper or white canvas.

=head1 EXAMPLE

unshadowimage.pl --analysis=plane --goal=225 --samples=800 --chart --verbose photo1.jpg

  Use the plane algorithm on photo1.jpg using a 800 pixels wide border around the image.
  Write a 2D surface plot to photo1_p_shadowmap.png and the result to photo1_plane.jpg.

=head1 DEPENDENCIES

unshadowimage.pl has the following dependencies:

* ImageMagick's perl library and command line convert utility

* GD perl library

* JSON perl library

* IPC::Open3 library

* Gnuplot (only for the 3D surface chart)

=head1 PRE-REQUISITES

To work, unshadowimage.pl must have the following pre-requisites:

* Image with a white background

* Image croped without margins except the white border around the subject

* A big enough border around the image's contents to analyse the shadow. I suggest
at least 50 pixels all around (top, bottom, left and right).

=head1 AUTHOR

unshadowimage.pl was written by Rodrigo Antunes, rorabr@github, https://rora.com.br

=cut
