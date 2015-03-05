#!/usr/bin/perl

use strict;
use warnings;

use Config::Properties;
use MARC::Batch;
$| = 1;

# Initialize properties
my $properties_file = shift(@ARGV);
die "Usage: dynamicindex.pl <properties_file>\n" unless $properties_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die "Can't read properties file $properties_file: $!\n";

my $index_me_dir = $properties->requireProperty('bibexport.index_me_dir');
#$index_me_dir =~ s/^C/V/;

my @marc_files = ();

opendir( DIR, $index_me_dir );
my @files = sort { $b cmp $a } readdir(DIR);
foreach my $f (@files) {
  if ($f =~ /^hcl_[0-9]{5,}\.mrc$/) {
    push(@marc_files, $index_me_dir . $f);
  }
}
closedir( DIR );

#foreach my $f (@marc_files) {
#  print "$f\n";
#}
#exit;

my %exported = ();
my $deduped_file = $index_me_dir . "deduped.mrc";
open(OUT, ">$deduped_file");
my $n_recs = 0;
my $n_exported = 0;
my $n_skipped = 0;
foreach my $f (@marc_files) {
  print "$f\n";
  my $batch = MARC::Batch->new('USMARC',$f);
  $batch->strict_off();
  $batch->warnings_off();
  while (my $record = $batch->next()) {
    $n_recs++;
    my $bib = $record->field('999')->subfield('a');
    if (exists($exported{$bib})) {
      $n_skipped++;
    } else {
      print OUT $record->as_usmarc();
      $n_exported++;
      $exported{$bib}++;
    }
  }
  undef $batch;
}

print "$n_recs records processed\n$n_exported records kept\n$n_skipped records skipped\n";

exit 0;

