#!/usr/bin/perl -w

use strict;
use Descartes::AjaxMapMaker qw($mini_map_max_width $mini_map_max_height
      $mini_map_name);
use Getopt::Long qw(:config gnu_getopt auto_help);
use Pod::Usage;
use Image::Info qw(image_type image_info dim);
use Template;
use Data::Dumper;
use Cwd qw(cwd);
use Text::Wrap qw(wrap);
use Storable qw(store retrieve);
use XML::Simple qw(XMLin);
use List::MoreUtils qw(firstval);
use Carp qw(croak);
use Math::Round qw(round);

pod2usage (-verbose => 1) if !@ARGV;

my $f_quiet = 0;
my @source_files;
my @directories;
my @non_existents;
my @problem_files;
my @rendered_files;
my %gen_parms;
$Data::Dumper::Indent = 1;

GetOptions (
  'quiet' => \$f_quiet,
  'scale:s' => \&scaling,
  '<>' =>
    sub {
      process_graphic_file (shift, \@source_files,
                           \@directories, \@non_existents,
                           \@problem_files, \@rendered_files);
    },
);

$gen_parms{f_quiet} = $f_quiet if $f_quiet;

SOURCE_FILE:
foreach my $source_file (@source_files) {
  print "Rendering $source_file\n";
  eval {
    Descartes::AjaxMapMaker->new($source_file)->generate(%gen_parms);
  };
  if ($@) {
    push @problem_files, {file => $source_file, error => $@};
    next SOURCE_FILE;
  }
  push @rendered_files, $source_file;
}

foreach my $dir (@directories) {
  make_gallery($dir, %gen_parms);
}

if (@rendered_files) {
  print "Rendered files\n";
  print map {"  $_\n"} @rendered_files;
  print "\n";
}
if (@non_existents) {
  print "Non-existent files\n";
  print map {"  $_\n"} @non_existents;
  print "\n";
}
if (@problem_files) {
  print "Problem files\n";
  foreach my $problem (@problem_files) {
    print "  " . $problem->{file} . ":\n";
    print wrap ("    ", "    ", $problem->{error}) . "\n";
  }
  print "\n";
}

=head1 make_gallery
Take one directory full of graphic files. Call generate on each graphic file.
Voila a gallery of google style maps.
=cut
sub make_gallery {
  my ($gallery_dir, @gen_parms) = @_;

  if (! opendir DIR, $gallery_dir)
  {
    push @problem_files, {
      file => $gallery_dir,
      error => "Could not open directory $gallery_dir\n",
    };
    return;
  }
  my @all_files = readdir DIR;
  closedir DIR;
  my $hiff_file = firstval { $_ eq 'gallery.hiff' } @all_files;
  my $hiff;
  if (!$hiff_file) {
    $hiff = create_default_hiff ($gallery_dir, \@all_files);
  }
  else {
    warn "Missing gallery.hiff\n" unless $hiff_file;
    $hiff = XMLin("$gallery_dir/$hiff_file",
                    KeyAttr => { item => 'dir' },
                    ForceArray => ['item']);
  }

  my @graphic_files = grep { m/jpeg|jpg|gif|tif|png|pdf$/i } @all_files;
  my $H_item = $hiff->{menu}{item};
  my @thumbs;
  GRAPHIC_FILE:
  foreach my $graphic_file (@graphic_files) {
    print "Rendering $gallery_dir/$graphic_file\n";
    my $map_maker =
      Descartes::AjaxMapMaker->new("$gallery_dir/$graphic_file", $gallery_dir);
    my $image_dir = $map_maker->generate(@gen_parms, f_zip => 0);
    my $generated_dir = "$gallery_dir/$image_dir";

    my $mini_map_file = "$generated_dir/rendered/$mini_map_name";
    my ($hi_res_file, $low_res_file, $scales)
        = get_all_res ("$generated_dir/rendered");
    my $scale_desc = join ', ', map { ($_ * 100) . '%' } @$scales;
    my $info = image_info ($mini_map_file);
    if (my $error = $info->{error}) {
       push @problem_files, {
         file => "$gallery_dir/$graphic_file",
         error => "Can't parse image info: $error",
       };
       next GRAPHIC_FILE;
    }
    push @rendered_files, "$gallery_dir/$graphic_file";
    my($mini_map_width, $mini_map_height) = dim($info);

    push @thumbs, {
      src => "$image_dir/rendered/$mini_map_name",
      full_view => "$image_dir/index.html",
      caption => $graphic_file,
      width => $mini_map_width,
      height => $mini_map_height,
    };

    # hiff augmentation
    my $item = $H_item->{$image_dir};
    $item->{thumb} = {
      src => "$image_dir/rendered/$mini_map_name",
      width => $mini_map_width,
      height => $mini_map_height,
    };
    $item->{multi_res}{file} = "$image_dir/index.html";
    $item->{multi_res}{scale_desc} = $scale_desc;
    $item->{low_res}{file} = "$image_dir/rendered/$low_res_file";
    $item->{low_res}{size}
      = round ((stat "$generated_dir/rendered/$low_res_file")[7] / 1024);
    $item->{hi_res}{file} = "$image_dir/rendered/$hi_res_file";
    $item->{hi_res}{size}
      = round ((stat "$generated_dir/rendered/$hi_res_file")[7] / 1024);
  }

  my $tt = Template->new ();
  $tt->process(
        'gallery_index.html.tt',
        {
          thumbs => \@thumbs,
          mini_map_max_width => $mini_map_max_width,
          mini_map_max_height => $mini_map_max_height,
          hiff => $hiff,
        },
        "$gallery_dir/index.html"
  );
}

sub scaling {
  my ($option, $scale_string) = @_;

  die "Scales '$scale_string' are supposed to be numbers\n" 
    if $scale_string !~ /\d/;
  $gen_parms{scales} = [ split /[\s,]+/, $scale_string ];
}

sub process_graphic_file {
  my ($source, $source_files, $directories, $non_existents, $problem_files)
    = @_;

  if (!-e $source) {
    push @$non_existents, $source;
    return;
  }
  if (-d $source) {
    push @$directories, $source;
    return;
  }

  if ($source !~ /\.pdf$/i) {
    my $type = image_type($source);
    if (my $error = $type->{error}) {
      push @$problem_files, {
        file => $source,
        error => "Can not determine file type: $error" 
      };
      return;
    }

    my $file_type = $type->{file_type};
    if ($file_type !~ m/GIF|PNG|JPEG|TIFF/) {
      push @$problem_files, {
        file => $source,
        error => "file type '$file_type': Not pdf, png, gif, tiff or jpg",
      };
      return;
    }
  }

  push @$source_files, $source;
}

sub create_default_hiff {
  my ($gallery_dir, $all_files) = @_;

  my $hiff = {
    name => "Gallery",
    desc => "Gallery description goes here",
    menu => {},
  };

  my %item;
  GALLERY_ITEM:
  for my $file_name (@$all_files) {
    my ($base_name, $file_ext);
    if (-d "$gallery_dir/$file_name") {
      next GALLERY_ITEM;
    }
    ($base_name, $file_ext)
      = Descartes::AjaxMapMaker::refine_file_name ($file_name);
    if (Descartes::AjaxMapMaker::is_image_file_ext($file_ext)) {
      $item{$base_name} = {
        name => $file_name,
        desc => "Description goes here",
      };
    }
  }
  $hiff->{menu}{item} = \%item;

  return $hiff;
}

sub get_all_res {
  my $rendered_dir = shift;

  opendir (my $DIR, $rendered_dir)
    || croak "Could not open $rendered_dir: $!";
  my @dir_files = readdir $DIR;
  closedir $DIR;

  my $low_res_file = firstval { /^low_res[.][a-z]{3}$/ } @dir_files;
  my %scaled = map { /scale(\d+)[.][a-z]{3}$/ ? ($1,$_) : () } @dir_files;
  my @sorted_scales =  sort {$a<=>$b} keys %scaled;
  my $max_scale = $sorted_scales[-1];
  my $high_res_file = $scaled{$max_scale};

  return ($high_res_file, $low_res_file, [ map { $_ / 100 } @sorted_scales ] );
}

__END__

=head1 SYNOPSIS

./make_ajax.pl filename1.pdf filename2.pdf etc.

=head1 DESCRIPTION

This program will take a graphics file (pdf, png, gif or jpg) and render the files
necessary to support a google style map.

=head1 ARGUMENTS

=head2 --scale

Sets the scale factors for the renders. For example, 75%, 100%, 125% and 150% is
represented as 

--scale=0.75,1,1.25,1.50

Please, no spaces.

=head2 --help

Print this help section

=head2 --quiet value

Currently unimplemented

=cut

