package AjaxMapMaker;

# Written by Lambert Lum (emceelam@warpmail.net)

use strict;
use Imager;
use Image::Info qw(image_info dim);
use Template;
use Readonly;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use File::Find qw(find);
use File::Copy qw(move copy);
use Params::Validate qw(validate ARRAYREF);
use Math::Round qw(round);

Readonly my $tile_size => 256;
Readonly my $mini_map_max_width  => 200;
Readonly my $mini_map_max_height => 200;
Readonly my $mini_map_name => "mini_map.png";

sub new {
  my ($class_name, $source_file) = @_;

  my ($base_name, $file_ext) = $source_file =~ m{(?:.*/)?(.*)\.([^.]+)$};
  $base_name = lc $base_name;
  $base_name =~ s/[^a-z0-9.\-]/_/g;
  $file_ext = lc $file_ext;
  my $tiles_subdir = "tiles";
  my $self = {
    pdf_name => $source_file,
    source_file_name => $source_file,
    source_file_ext  => $file_ext,
    target_file_ext => ($file_ext eq 'pdf' ? 'png' : $file_ext),
    base_dir => $base_name,
    base_name => $base_name,
    rendered_dir => "$base_name/rendered",
    tiles_dir => "$base_name/$tiles_subdir",
    tiles_subdir => $tiles_subdir,
  };
  return bless $self, $class_name;
}

sub pdf_to_png {
  my $self = shift;
  my $base_dir = $self->{base_dir};
  my $file_base = $self->{base_name};
  my $rendered_dir = $self->{rendered_dir};
  my $pdf_name = $self->{pdf_name};
  my $scales = $self->{scales} || [1, 1.5, 2, 3];
  my $error;
  my $info;
  $self->{target_file_ext} = 'png';

  my @image_file_names;

  # render at different resolutions
  # at scale 100%, monitor resolution is 72dpi
  foreach my $scale (@$scales) {
    my $dpi = round($scale * 72);
    system ("nice gs -q -dSAFER -dBATCH -dNOPAUSE " .
              "-sDEVICE=png16m -dUseCropBox -dMaxBitmap=300000000 " .
              "-dFirstPage=1 -dLastPage=1 -r$dpi " .
              "-dTextAlphaBits=4 -dGraphicsAlphaBits=4 -dDOINTERPOLATE " .
              "-sOutputFile=$rendered_dir/$file_base.png $pdf_name");
    $info = image_info ("$rendered_dir/$file_base.png");
    if ($error = $info->{error}) {
      die "Can't parse image info: $error\n";
    }
    my ($width, $height) = dim ($info);
    my $percent_scale = sprintf "%03d", $scale * 100;
    my $dest_file_name =
      "w${width}_h${height}_scale${percent_scale}.png";
    rename "$rendered_dir/$file_base.png", "$rendered_dir/$dest_file_name";
    print "rendered $dest_file_name\n";
    push @image_file_names, $dest_file_name;
  }

  return @image_file_names;
}

sub create_mini_map {
  my ($self, $file_name) = @_;
  my $rendered_dir = $self->{rendered_dir};
  my $img = Imager->new();
  $img->read (file => "$rendered_dir/$file_name")
    || die "Could not read $rendered_dir/$file_name: " . $img->errstr . "\n";
  my $scaled_img = $img->scale (
                     xpixels => $mini_map_max_width, 
                     ypixels => $mini_map_max_height,
                     type=>'min');
  $scaled_img->write (file => "$rendered_dir/$mini_map_name")
    || die "Could not write mini map: " . $img->errstr . "\n"
}

sub tile_image {
  my ($self, $file_name, $z)  = @_;

  my $rendered_dir = $self->{rendered_dir};
  my $tiles_dir = $self->{tiles_dir};
  my $base_name = $self->{base_name};
  my $file_ext = $self->{target_file_ext};
  my ($img_width, $img_height) =
    $file_name =~ m/w(\d+)_h(\d+)_scale(\d+)\.(?:png|gif|jpg)$/;
  print "$base_name, $img_width, $img_height\n";
  my $img = Imager->new;
  $img->read (file => "$rendered_dir/$file_name")
    || die "Could not read $rendered_dir/$file_name: " . $img->errstr;

  my $tile_cnt = 0;
  my $max_y = $img_height / $tile_size;
  my $max_x = $img_width  / $tile_size;
  for   (my $y=0; $y < $max_y; $y++) {
    for (my $x=0; $x < $max_x;  $x++) {
      my $tile_img = $img->crop (
                       left => $x * $tile_size, top => $y * $tile_size,
                       width=> $tile_size, height => $tile_size);
      my $tile_name =
        "$tiles_dir/x$x" . "y$y" ."z$z" . ".$file_ext";
      $tile_img->write (file => $tile_name)
        || die "Cannot write tile $tile_name: ". $tile_img->errstr();
      $tile_cnt++;
    }
    print "Finished row $y. Tiles written so far: $tile_cnt\n"
      if ($y & 0x1) == 0;   # even rows only
  }
  print "Total tiles written: $tile_cnt\n";
}

sub generate_javascript {
  my ($self, @file_names) = @_;
  my $pdf_name = $self->{pdf_name};
  my $rendered_dir = $self->{rendered_dir};
  my $base_dir = $self->{base_dir};
  my $error;
  my @dimensions;
  my $info;

  foreach my $file_name (@file_names) {
    my ($width, $height, $scale) =
      $file_name =~ m/w(\d+)_h(\d+)_scale(\d+)\.(?:jpg|png|gif)$/;
    push @dimensions, { width => $width, height => $height, scale => $scale };
  }
  $info = image_info("$rendered_dir/$mini_map_name");
  my ($mini_map_width, $mini_map_height) = dim($info);

  my $tt = Template->new ();
  $tt->process(
        'index.html.tt',
        {
          file_base => $self->{base_name},
          tiles_subdir => $self->{tiles_subdir},
          tile_size => $tile_size,
          tile_file_ext => $self->{target_file_ext},
          dimensions => \@dimensions,
          view_port_width  => 500,
          view_port_height => 400,
          mini_map_width  => $mini_map_width,
          mini_map_height => $mini_map_height,
        },
        "$base_dir/index.html"
  ) || die $tt->error(), "\n";
}

sub zip_files {
  my ($self) = @_;
  my $base_dir = $self->{base_dir};
  my $base_name = $self->{base_name};
  my $zip = Archive::Zip->new();

  if (-e "$base_dir/$base_name.zip")
  {
    move "$base_dir/$base_name.zip", '.';
  }
  find ( {
    wanted => sub { $File::Find::dir !~ m/rendered$/ &&
                      $zip->addFileOrDirectory($_) },
    no_chdir => 1
  }, $base_dir);
  $zip->addFile("$base_dir/rendered/mini_map.png");
  unless ($zip->writeToFileNamed("$base_name.zip") == AZ_OK)
  {
    die "$base_name.zip write error";
  }
  move "$base_name.zip", $base_dir;
}

# scale a raster image, save the scaled images
# and return the list of scaled raster images
sub scale_raster_image {
  my $self = shift;
  my $scales = $self->{scales} || [0.25, 0.5, 0.75, 1];
  my $source_file = $self->{source_file_name};
  my $rendered_dir = $self->{rendered_dir};
  my $base_name = $self->{base_name};
  my $file_ext = $self->{target_file_ext};
  my @file_names;
  my ($width, $height);
  my $scale;
  my $dest_file_name;

  my $img = Imager->new;
  $img->read (file => $source_file) 
    || die "scale_raster_image:" . $img->errstr() . "\n";

  foreach $scale (@$scales) {
    my $scaled_img = $img->scale(scalefactor => $scale);
    ($width, $height) = ($scaled_img->getwidth(), $scaled_img->getheight());
    $dest_file_name = "w${width}_h${height}_scale"
      . sprintf ("%03d", $scale * 100) . ".$file_ext";

    if ($scale == 1) {
      print "Copied $dest_file_name\n";
      copy $source_file, "$rendered_dir/$dest_file_name"
        || die "unable to write $dest_file_name\n";
    }
    else {
      print "Rendered $dest_file_name\n";
      $scaled_img->write (file => "$rendered_dir/$dest_file_name")
        or die $scaled_img->errstr;
    }
    push @file_names, $dest_file_name;
  }

  return @file_names;
}

=head2 generate

When called, generate will coordinate the creation of the files neccessary
to create an AJAX map

=head3 scales

List ref of scaling factors. 100% scale factor is 1. 50% is 0.5.
So on and so on

=cut
sub generate {
  my $self = shift;
  my @file_names;
  my %p = validate ( @_, {
                        scales => {
                          type => ARRAYREF,
                          optional => 1
                        },
                      });
  $self->{scales} = $p{scales};

  mkdir $self->{base_dir} || die "Could not create base_dir\n";
  mkdir $self->{rendered_dir} || die "Could not create rendered_dir\n";
  mkdir $self->{tiles_dir} || die "Could not create tiles_dir\n";

  if ($self->{source_file_name} =~ m/\.pdf$/) {
    @file_names = $self->pdf_to_png ();
  }
  else {
    @file_names = $self->scale_raster_image ();
  }
  foreach my $i (0 .. $#file_names) {
    $self->tile_image ($file_names[$i], $i);
  }
  $self->create_mini_map ($file_names[-1]);   # Last one is typically largest
  $self->generate_javascript (@file_names);
  $self->zip_files ();
}

1;