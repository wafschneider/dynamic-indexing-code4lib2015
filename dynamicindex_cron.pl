#!/usr/bin/perl

# dynamicindex_cron.pl
# Dynamic indexer for HCL discovery layer
# takes properties file as an argument, otherwise fails
# forks multiple indexing jobs, runs solrmarc over the file, then runs the backfill script
# modified to launch from cron every x minutes

use strict;
use warnings;

use XML::Simple;
use LWP;
use JSON;
use Config::Properties;
use DBI qw(:sql_types);
use MARC::Batch;
use LWP::UserAgent; 
use HTTP::Request::Common qw(POST GET);
use HTTP::Headers;
use Proc::Daemon;
use POSIX ":sys_wait_h";
$| = 1;

# Initialize properties
my $properties_file = shift(@ARGV);
die "Usage: dynamicindex_cron.pl <properties_file>\n" unless $properties_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die "Can't read properties file $properties_file: $!\n";

my $solrmarc_dir = $properties->requireProperty('hcl.solrmarc_dir');
my $hz_server = $properties->requireProperty('hcl.hz_server');
my $hz_password = $properties->requireProperty('hcl.hz_password');
my $hz_user = $properties->requireProperty('hcl.hz_user');
my $hz_database = $properties->requireProperty('hcl.hz_database');

my $marc_suffix = $properties->getProperty('hcl.marc_suffix','mrc');
my $solrmarc_mem_args = $properties->getProperty('hcl.solrmarc_mem_args','-Xmx256m');
my $index_me_dir = $properties->requireProperty('hcl.dynamic.index_me_dir');
my $log_dir = $properties->requireProperty('hcl.dynamic.log_dir');
my $solrmarc_config = $properties->requireProperty('hcl.solrmarc_config');
my $solr_app = $properties->requireProperty('hcl.solr_app');
my $solr_core = $properties->requireProperty('hcl.solr_core');
my $solr_search_app = $properties->requireProperty('hcl.solr_search_app');
my $solr_search_core = $properties->requireProperty('hcl.solr_search_core');
my $time_between_replication = $properties->getProperty('hcl.dynamic.time_between_replication','3600');
my $num_indexers = $properties->requireProperty('hcl.dynamic.num_indexers');

die "Unable to access Solrmarc directory $solrmarc_dir!\n" unless (-d $solrmarc_dir && -r _ && -w _ );
die "Unable to access MARC extract directory $index_me_dir!\n" unless (-d $index_me_dir && -r _ && -w _ );
die "Unable to access log directory $log_dir!\n" unless (-d $log_dir && -r _ && -w _ );
die "Unable to access Solrmarc config $solrmarc_config!\n" unless (-r "$solrmarc_dir/$solrmarc_config");

my $n_recs = 0;
my $n_files = 0;
my $duration = 0;
my $rate = 0;
my $start_time = time();

# get today's date
my($sec, $min, $hr, $mday, $mon, $year, $wday) = (localtime(time()))[0..6];
my $yyyy = $year + 1900;
my $dd = pad($mday, "r", 2, "0");
my $mm = $mon + 1;
$mm = pad($mm, "r", 2, "0");
my $today = $yyyy . $mm . $dd;
$sec = pad($sec, "r", 2, "0");
$min = pad($min, "r", 2, "0");
$hr = pad($hr, "r", 2, "0");

# establish db connection
my $hz_dbh = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password) or die("Could not connect to database: $DBI::errstr");
$hz_dbh->do("use $hz_database") or die("Could not use database: $DBI::errstr");

my $check_solr_index_control = $hz_dbh->selectall_arrayref("
  select control,value from hcl_solr_index_control
") or die("Could not issue selectall_arrayref: $DBI::errstr");

my %sic = ();
foreach my $sic_ref (@$check_solr_index_control) {
  my($control,$value) = @$sic_ref;
  $sic{$control} = $value;
}

# If another instance of dynamic is running or has died while indexing, quit without logging.
if ($sic{horizon_dynamic_is_running} == 1) {
  exit;
}

# If dynamic is prevented, log with -1 and quit
if ($sic{prevent_horizon_dynamic} == 1) {
  # set exception values for logging
  $n_files = -1;
  $n_recs = -1;
  $duration = -1;
  $rate = -1;
  print "\n\n*****************************************\nStarting new cycle ($mm/$dd/$yyyy $hr:$min:$sec)\n";
  print "Horizon dynamic indexing is being actively prevented!  Exiting...\n\n";
  # update the index log
  my $right_now = time();
  $hz_dbh->do("
    insert hcl_solr_bib_index_log (timestamp, n_files, n_records, duration, rate)
    values($right_now, $n_files, $n_recs, $duration, $rate)
  ");
  # toss an empty entry into the replication log to stop the safety net from complaining
  $hz_dbh->do("
    insert hcl_solr_replication_log (timestamp, duration)
    values($right_now, 0)
  ");
  
  exit;
  
}

# green light
print "\n\n*****************************************\nStarting new cycle ($mm/$dd/$yyyy $hr:$min:$sec)\n";

# let other processes know that horizon dynamic is running  
$hz_dbh->do("exec hcl_update_sic_horizon_is_running 1");

print "Checking on the core...";
# get core status
my $ua = LWP::UserAgent->new;
my $request = HTTP::Request->new(GET => "$solr_app/admin/cores?action=STATUS");
my $response = $ua->request($request);
if ($response->is_success) {
  my $core_status = XMLin($response->content);
  if ($$core_status{lst}{responseHeader}{'int'}{status}{content} == 0) { # successful query
    if ($$core_status{lst}{status}{lst}{$solr_core} || $$core_status{lst}{status}{lst}{name} eq $solr_core) { # core exists
      print "Core $solr_core seems good.\n";
    } else {
      log_and_die(-2,"Core $solr_core not found.\n");
    }
  } else {
    log_and_die(-3,"Unable to query core status.\n");
  }
} else {
  log_and_die(-4,"Can't get SOLR core status: " . $response->status_line . "\n");
}

# process MARC files
print "Processing MARC files...\n";
my $index_file_base = 'index_me_' . time() . '_';
my $index_file_all_name = $index_file_base . 'all.mrc';
my $index_file_all_fp = $index_me_dir . $index_file_all_name;
open(OUT, ">$index_file_all_fp");
my %exported = (); # hash to keep track of the exported records already added to the index_me file
opendir(IMDIR, $index_me_dir);
my @imdir_files = sort { $b cmp $a } readdir(IMDIR);
foreach my $imdir_f (@imdir_files) {
  if ($imdir_f =~ /^hcl_[0-9]{5,}\.mrc$/) {
    print "  $imdir_f\n";
    $n_files++;
    my $mf = $index_me_dir . $imdir_f;
    my $batch = MARC::Batch->new('USMARC',$mf);
    $batch->strict_off();
    $batch->warnings_off();
    while (my $record = $batch->next()) {
      my $bid = $record->field('999')->subfield('a');
      if (!exists($exported{$bid})) {
        print OUT $record->as_usmarc();
        $n_recs++;
        $exported{$bid}++;
      }
    }
    undef $batch;
    # delete the original file
    unlink($mf) or log_and_warn(-5,"Cannot delete file $mf: $!\n");
  }
}
closedir(IMDIR);
close(OUT);

print "$n_recs record(s) from $n_files file(s)\n";
if ($n_recs >= $num_indexers) {
  # there are enough records to split into separate files
  # split the big file into $num_indexers equally sized files
  my %index_me_files = ();
  my $recs_per_file = int($n_recs / $num_indexers);
  my $batch = MARC::Batch->new('USMARC',$index_file_all_fp);
  my $file_idx = 1;
  my $index_file_name = $index_file_base . $file_idx . '.mrc';
  my $index_file_fp = $index_me_dir . $index_file_name;
  my $index_log_fp = $log_dir . $index_file_name;
  $index_log_fp =~ s/\.mrc$/\.log/;
  open(OUT, ">$index_file_fp");
  my $rec_idx = 0;
  while (my $record = $batch->next()) {
    if ($rec_idx && ($rec_idx % $recs_per_file == 0) && ($file_idx < $num_indexers)) {
      close(OUT);
      $index_me_files{$index_file_name}{index_file_fp} = $index_file_fp;
      $index_me_files{$index_file_name}{index_log_fp} = $index_log_fp;
      $file_idx++;
      $index_file_name = $index_file_base . $file_idx . '.mrc';
      $index_file_fp = $index_me_dir . $index_file_name;
      $index_log_fp = $log_dir . $index_file_name;
      $index_log_fp =~ s/\.mrc$/\.log/;
      open(OUT, ">$index_file_fp");
    }
    print OUT $record->as_usmarc();
    $rec_idx++;
  }
  close(OUT);
  $index_me_files{$index_file_name}{index_file_fp} = $index_file_fp;
  $index_me_files{$index_file_name}{index_log_fp} = $index_log_fp;
  
  # release the hounds
  $ENV{SOLRMARC_MEM_ARGS} = $solrmarc_mem_args;
  my %kid_pid;
  foreach my $ifn (sort(keys(%index_me_files))) {
    my $pid = fork();
    if ($pid) { # parent process
      $kid_pid{$pid} = $ifn;
    } elsif ($pid == 0) { # child process
      print "Indexing file $ifn (" . localtime() . ")...\n";
      if (system("$solrmarc_dir/bin/indexfile $solrmarc_dir/$solrmarc_config $index_me_files{$ifn}{index_file_fp} > $index_me_files{$ifn}{index_log_fp} 2>&1") == 0) {
        print "SolrMARC processing complete for $ifn " . localtime() . ").\n";
      } else {
        die "SolrMARC processing ended in an error condition for $ifn, check logs\n";
      }    
      print "Backfill with Horizon and Syndetics data for $ifn (" . localtime() . ")...\n";
      if (system("$solrmarc_dir/hcl/indexfile.pl $solrmarc_dir/$solrmarc_config $index_me_files{$ifn}{index_file_fp} >> $index_me_files{$ifn}{index_log_fp} 2>&1") == 0) {
        print "Backfill processing complete for $ifn (" . localtime() . ").\n";
      } else {
        die "Backfill processing ended in an error condition for $ifn, check logs\n";
      }
      if (unlink($index_me_files{$ifn}{index_file_fp})) {
        print "Deleted file $ifn\n";
      } else {
        die "Couldn't delete $ifn: $!\n";
      }
      exit;
    } else {
      die "Couldn't fork process for $ifn: $!\n";
    }
  }
  
  # zombie reaping
  my $error_state = 0;
  until (keys(%kid_pid) == 0) {
    my $kid = wait;
    if ($? == 0) {
      print "Completed processing for $kid_pid{$kid}\n";
    } else {
      warn "Error processing $kid_pid{$kid}\n";
      $error_state = 1;
    }
    delete $kid_pid{$kid};
  }
  die "Indexing aborted, record processing ended in error state\n" if $error_state;
  # delete the individual files
  if (unlink($index_file_all_fp)) {
    print "Deleted file $index_file_all_name\n";
  } else {
    print "ACK!\n";
    die "Couldn't delete $index_file_all_name: $!\n";
  }
  
} elsif ($n_recs) {
  # there aren't enough records to split up the _all file
  # process the file with solrmarc
  my $index_log_all_fp = $log_dir . $index_file_all_name;
  $index_log_all_fp =~ s/\.mrc$/\.log/;
  
  print "Indexing file $index_file_all_name (" . localtime() . ")...\n";
  if (system("$solrmarc_dir/bin/indexfile $solrmarc_dir/$solrmarc_config $index_file_all_fp > $index_log_all_fp 2>&1") == 0) {
    print "SolrMARC processing complete for $index_file_all_name " . localtime() . ").\n";
  } else {
    warn "SolrMARC processing ended in an error condition for $index_file_all_name, check logs\n";
  }
  
  # backfill with Horizon and Syndetics info and update Overdrive records
  print "Backfill with Horizon and Syndetics data for $index_file_all_name (" . localtime() . ")...\n";
  if (system("$solrmarc_dir/hcl/indexfile.pl $solrmarc_dir/$solrmarc_config $index_file_all_fp >> $index_log_all_fp 2>&1") == 0) {
    print "Backfill processing complete for $index_file_all_name (" . localtime() . ").\n";
  } else {
    warn "Backfill processing ended in an error condition for $index_file_all_name, check logs\n";
  }    
  # delete the MARC file
  unlink($index_file_all_fp);
  print "Done processing file $index_file_all_name\n";
  
} else {
  print "No files to process\n";
  unlink($index_file_all_fp);
}

# all done updating the index
print "\nEnd of indexing cycle\n";
my $end_time = time();

if ($duration != -1) {
  $duration = $end_time - $start_time;
  $rate = 0;
  if ($duration) {
    $rate = int($n_recs / $duration);
  }
}

print "Cycle time $duration seconds ($rate records/sec)\n";

# update the index log
my $right_now = time();
$hz_dbh->do("
  insert hcl_solr_bib_index_log (timestamp, n_files, n_records, duration, rate)
  values($right_now, $n_files, $n_recs, $duration, $rate)
");

# is it time for replication?
my $get_last_replication_time = $hz_dbh->selectall_arrayref("
  select max(timestamp) from hcl_solr_replication_log
");
my $last_replication_time = 0;
foreach my $glrt (@$get_last_replication_time) {
  $last_replication_time = $$glrt[0];
}
if (($right_now - $last_replication_time) > $time_between_replication) {
  # have there been updates to the index since last replication?
  my $get_update_count_since_last_replication = $hz_dbh->selectall_arrayref("
    select sum(n_records) from hcl_solr_bib_index_log
    where timestamp >= $last_replication_time
    and n_records > 0
  ");
  my $update_count_since_last_replication = 0;
  foreach my $guc (@$get_update_count_since_last_replication) {
    $update_count_since_last_replication = $$guc[0];
  }
  if ($update_count_since_last_replication) {
    # yes, replication is appropriate
    
    # force replicatation the search core
    my $replication_start_time = time();
    print "Forcing replication\n";
    my $ua = LWP::UserAgent->new;
    my $req_solr_replicate = HTTP::Request->new('GET', "$solr_search_app/${solr_search_core}/replication?command=fetchindex" );
    my $response_solr_replicate = $ua->request($req_solr_replicate);
    unless ($response_solr_replicate->is_success) {
      warn "Error replicating: " . $response_solr_replicate->status_line . "\n";
    }
    my $replicate_response = XMLin($response_solr_replicate->content);
    if ($$replicate_response{lst}{'int'}{status}{content} == 0) { # successful replication
      print "Replication successful\n";
      print "Waiting for replication to finish\n";
      # wait for replication to finish
      my $replication_finished = 0;
      while (!$replication_finished) {
        sleep(3);
        my $req_solr_repl_status = HTTP::Request->new( GET => "$solr_search_app/${solr_search_core}/replication?command=details" );
        my $response_solr_repl_status = $ua->request($req_solr_repl_status);
        unless ($response_solr_repl_status->is_success) {
          warn "Error checking replication status: " . $response_solr_repl_status->status_line . "\n";
        }
        my $repl_status_response = XMLin($response_solr_repl_status->content);
        if ($$repl_status_response{lst}{details}{lst}{str}{isReplicating}{content} eq 'false') {
          print "Replication finished\n";
          $replication_finished = 1;
        }
      }
    }
    
    # update the replication log
    my $replication_end_time = time();
    my $replication_duration = $replication_end_time - $replication_start_time;
    print "Replication took $replication_duration seconds\n";
    $hz_dbh->do("
      insert hcl_solr_replication_log (timestamp, duration)
      values($replication_end_time, $replication_duration)
    ");
    
  } else {
    print "No updates since the last replication\n";
    $hz_dbh->do("
      insert hcl_solr_replication_log (timestamp, duration)
      values($right_now, -1)
    ");
  }
} else {
  print "Not time for replication\n";
}

# remove the i-am-running flag
$hz_dbh->do("exec hcl_update_sic_horizon_is_running 0");

# disconnect from db
$hz_dbh->disconnect();

exit;

sub pad {
  my($string, $just, $size, $delim) = @_;
  $just = lc($just);
  if (length($string) >= $size) {
    $string = substr($string, 0, $size);
  } else {
    my $diff = $size - length($string);
    my $filler = $delim x $diff;
    if ($just eq "r") {
      $string = "$filler$string";
    } else {
      $string = "$string$filler";
    }
  }
  return("$string");
}

sub log_and_die {
  my($code,$msg) = @_;
  my $right_now = time();
  eval {
    my $hz_dbh = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password) or die("Could not connect to database: $DBI::errstr");
    $hz_dbh->do("use $hz_database") or die("Could not use database: $DBI::errstr");
    $hz_dbh->do("
      insert hcl_solr_bib_index_log
      (timestamp, n_files, n_records, duration, rate)
      values($right_now, $code, $code, $code, $code)
    ");
  };
  die $msg;
}

sub log_and_warn {
  my($code,$msg,$dbh_ref) = @_;
  my $right_now = time();
  eval {
    my $hz_dbh = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password) or die("Could not connect to database: $DBI::errstr");
    $hz_dbh->do("use $hz_database") or die("Could not use database: $DBI::errstr");
    $hz_dbh->do("
      insert hcl_solr_bib_index_log
      (timestamp, n_files, n_records, duration, rate)
      values($right_now, $code, $code, $code, $code)
    ");
    $hz_dbh->disconnect;
  };
  warn $msg;
}
