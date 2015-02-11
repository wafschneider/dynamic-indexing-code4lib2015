#!/usr/bin/perl

# massindex.pl
# Mass indexer for HCL discovery layer
# takes properties file as an argument, otherwise fails
# forks a process for each MARC file in the extract directory
# runs solrmarc over the file, then run the backfill script
# refreshes hcl_overdrive_availability table in Horizon db - pf 11/20/2013

use strict;
use warnings;

use XML::Simple;
use LWP;
use Config::Properties;
use DBI qw(:sql_types);
use POSIX ":sys_wait_h";
$| = 1;

# Initialize properties
my $properties_file = shift(@ARGV);
die "Usage: massindex.pl <properties_file>\n" unless $properties_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die "Can't read properties file $properties_file: $!\n";
my $marc_suffix = $properties->getProperty('hcl.marc_suffix','mrc');
my $enforce_marc_file_pattern_match = $properties->getProperty('hcl.enforce_marc_file_pattern_match','true');
my $solrmarc_mem_args = $properties->getProperty('hcl.solrmarc_mem_args','-Xmx256m');
my $extract_dir = $properties->requireProperty('hcl.extract_dir');
my $solrmarc_dir = $properties->requireProperty('hcl.solrmarc_dir');
my $solrmarc_config = $properties->requireProperty('hcl.solrmarc_config');
my $solr_app = $properties->requireProperty('hcl.solr_app');
my $solr_core = $properties->requireProperty('hcl.solr_core');
my $solr_search_app = $properties->requireProperty('hcl.solr_search_app');
my $solr_search_core = $properties->requireProperty('hcl.solr_search_core');
my $solr_backup_dir = $properties->requireProperty('hcl.solr_backup_dir');
my $solr_backup_retention = $properties->getProperty('hcl.solr_backup_retention',3);
my $hz_server = $properties->requireProperty('hcl.hz_server');
my $hz_password = $properties->requireProperty('hcl.hz_password');
my $hz_user = $properties->requireProperty('hcl.hz_user');
my $hz_database = $properties->requireProperty('hcl.hz_database');
my $overdrive = $properties->getProperty('hcl.overdrive');
my $index_me_dir = $properties->requireProperty('hcl.dynamic.index_me_dir');

die "Unable to access Solrmarc directory $solrmarc_dir!\n" unless (-d $solrmarc_dir && -r _ && -w _ );
die "Unable to access MARC extract directory $extract_dir!\n" unless (-d $extract_dir && -r _);
die "Unable to access Solrmarc config $solrmarc_config!\n" unless (-r "$solrmarc_dir/$solrmarc_config");
chdir($solrmarc_dir) or die "Can't cd to $solrmarc_dir: $!\n";

# Horizon database handle
my $dbh_hz = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password) or die("Could not connect to database: $DBI::errstr");
$dbh_hz->do("use $hz_database") or die("Could not use database: $DBI::errstr");

# check to make sure the boopsie_extract is finished
my $check_boopsie_extract = $dbh_hz->selectrow_arrayref("select value from hcl_solr_index_control where control = 'boopsie_extract_is_running'");
my $boopsie_extract_is_running = $$check_boopsie_extract[0];
while ($boopsie_extract_is_running) {
  print "Boopsie extract is still running...wait for 5 minutes and try again\n";
  sleep(300);
  $check_boopsie_extract = $dbh_hz->selectrow_arrayref("select value from hcl_solr_index_control where control = 'boopsie_extract_is_running'");
  $boopsie_extract_is_running = $$check_boopsie_extract[0];
}

# check to make sure there are 8 reasonably-sized MARC files to process
my @files = glob("$extract_dir/*.$marc_suffix");
my @file_check = ();
foreach my $f (@files) {
  if ($enforce_marc_file_pattern_match eq 'true') {
    if ($f =~ /hzbibs_20[0-9]{6}_[1-8]{1}\.mrc$/) {
      push(@file_check, $f);
    }
  } else {
    push(@file_check, $f)
  }
}
my $n_files = @file_check;
my $n_files_is_are = 'are';
my $n_files_pl = 's';
if ($n_files == 1) {
  $n_files_is_are = 'is';
  $n_files_pl = '';
}
die "There $n_files_is_are $n_files file$n_files_pl instead of 8 in the MARC extract dir ($extract_dir)!!\n"
  unless ($n_files == 8);
my $file_size_fail = 0;
foreach my $fc (@file_check) {
  my $fsize = -s "$fc";
  if ($fsize < 150000000) {
    $file_size_fail = 1;
  }
}
die "There is at least one MARC file smaller than 1.5MB in the MARC extract dir ($extract_dir)!!\n"
  if $file_size_fail;

# check on the core status
my $ua = LWP::UserAgent->new;
my $request = HTTP::Request->new(GET => "$solr_app/admin/cores?action=STATUS");
my $response = $ua->request($request);
if ($response->is_success) {
  my $core_status = XMLin($response->content);
  if ($$core_status{lst}{responseHeader}{'int'}{status}{content} == 0) { # successful query
    if ($$core_status{lst}{status}{lst}{$solr_core} ||
        $$core_status{lst}{status}{lst}{name} eq $solr_core) { # core exists
      print "Core $solr_core seems good.\n";
    } else {
      die "Core $solr_core not found.\n";
    }
  } else {
    die "Unable to query core status.\n";
  }
} else {
  die("Can't get SOLR core status: " . $response->status_line . "\n");
}

# stored procedures for setting indexing flags
my $sth_prevent_horizon_dynamic = $dbh_hz->prepare("exec hcl_update_sic_prevent_horizon ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_check_horizon_dynamic = $dbh_hz->prepare("select value from hcl_solr_index_control where control = 'horizon_dynamic_is_running'")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_prevent_bib_export = $dbh_hz->prepare("exec hcl_update_sic_prevent_bib_export ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_check_bib_export = $dbh_hz->prepare("select value from hcl_solr_index_control where control = 'bib_export_is_running'")
  or die "Can't prepare query: $DBI::errstr\n";

# Stop Horizon bib export and dynamic indexing

# set the flag to stop horizon dynamic indexing
$sth_prevent_bib_export->bind_param(1, 1, SQL_BIT);
$sth_prevent_bib_export->execute();
# set the flag to stop horizon dynamic indexing
$sth_prevent_horizon_dynamic->bind_param(1, 1, SQL_BIT);
$sth_prevent_horizon_dynamic->execute();

# check to see if horizon bib export is CURRENTLY running
my $check_bib_export = $dbh_hz->selectall_arrayref($sth_check_bib_export);
while ($$check_bib_export[0][0] == 1) {
  # wait for 10 seconds and then try again
  sleep(10);
  $check_bib_export = $dbh_hz->selectall_arrayref($sth_check_bib_export);
}

# check to see if horizon dynamic indexing is CURRENTLY running
my $check_horizon_dynamic = $dbh_hz->selectall_arrayref($sth_check_horizon_dynamic);
while ($$check_horizon_dynamic[0][0] == 1) {
  # wait for 10 seconds and then try again
  sleep(10);
  $check_horizon_dynamic = $dbh_hz->selectall_arrayref($sth_check_horizon_dynamic);
}

# wipe out the hcl_solr_pending table
print "Clearing the hcl_solr_pending table\n";
$dbh_hz->do("truncate table hcl_solr_pending");

# delete any backlogged marc files
print "Looking for backlog files to delete\n";
opendir(BACKLOG, $index_me_dir);
my @backlog_files = readdir(BACKLOG);
closedir(BACKLOG);
my $n_backlog_files = 0;
foreach my $backlog_file (@backlog_files) {
  if ($backlog_file =~ /\.mrc$/) {
    my $backlog_fileFP = $index_me_dir . $backlog_file;
    unlink($backlog_fileFP);
    $n_backlog_files++;
  }
}
if ($n_backlog_files) {
  print "Backlog files deleted: $n_backlog_files\n";
} else {
  print "No backlog files to delete\n";
}

# set up solr core for background indexing
print "Initializing ${solr_core}...";
# get core status
$request = HTTP::Request->new(GET => "$solr_app/admin/cores?action=STATUS");
$response = $ua->request($request);
if ($response->is_success) {
  my $core_status = XMLin($response->content);
  if ($$core_status{lst}{responseHeader}{'int'}{status}{content} == 0) { # successful query
    if ($$core_status{lst}{status}{lst}{$solr_core} ||
        $$core_status{lst}{status}{lst}{name} eq $solr_core) { # build core exists
      my $core_struct = $$core_status{lst}{status}{lst}{$solr_core}?$$core_status{lst}{status}{lst}{$solr_core}:$$core_status{lst}{status}{lst};
      my $build_dir_fullpath = $$core_struct{str}{instanceDir}{content};
      my @path = split(/\//,$build_dir_fullpath);
      my $build_dir = $path[@path - 1];
      my $data_dir_fullpath = $$core_struct{str}{dataDir}{content};
      # turn off replication until core is built
      $request->uri("$solr_app/${solr_core}/replication?command=disablereplication");
      $response = $ua->request($request);
      if ($response->is_success) {
        my $disable_rep_status = XMLin($response->content);
        if ($$disable_rep_status{lst}{'int'}{status}{content} == 0) { # replication disabled
          # unload build core, delete data dir
          $request->uri("$solr_app/admin/cores?action=UNLOAD&core=${solr_core}&deleteDataDir=true");
          $response = $ua->request($request);
          if ($response->is_success) {
            my $delete_status = XMLin($response->content);
            if ($$delete_status{lst}{'int'}{status}{content} == 0) { # successful delete
              # create it again
              $request->uri("$solr_app/admin/cores?action=CREATE&name=${solr_core}&instanceDir=$build_dir&dataDir=$data_dir_fullpath");
              $response = $ua->request($request);
              if ($response->is_success) {
                my $create_status = XMLin($response->content);
                if ($$create_status{lst}{'int'}{status}{content} == 0) { # successful create
                  # disable replication again, because it comes back up enabled after initialization
                  $request->uri("$solr_app/${solr_core}/replication?command=disablereplication");
                  $response = $ua->request($request);
                  if ($response->is_success) {
                    $disable_rep_status = XMLin($response->content);
                    if ($$disable_rep_status{lst}{'int'}{status}{content} == 0) { # replication disabled
                      print "core initialized, replication disabled.\n";
                    } else {
                      die "!!! core initialized, but replication was not disabled !!!\n";
                    }
                  } else {
                    die "!!! core initialized, but replication was not disabled !!! Error: " . $response->status_line . "\n";
                  }
                } else {
                  die "!!! core deleted, but unable to create core ${solr_core} !!!\n";
                }
              } else {
                die "!!! core deleted, but can't create core ${solr_core} !!! Error: " . $response->status_line . "\n";
              }
            } else {
              die "Unable to delete core ${solr_core}.\n";
            }
          } else {
            die "Can't unload core ${solr_core}: " . $response->status_line . "\n";
          }
        } else {
          die "Unable to disable replication on core $solr_core.\n";
        }
      } else {
        die "Can't disable replication on core ${solr_core}: " . $response->status_line . "\n";
      }
    } else {
      die "Build core ${solr_core} not found.\n";
    }
  } else {
    die "Unable to query core status.\n";
  }
} else {
  die "Can't get SOLR core status: " . $response->status_line . "\n";
}

# index MARC files
$ENV{SOLRMARC_MEM_ARGS} = $solrmarc_mem_args;
my %kid_pid;
my @marc_file = glob("$extract_dir/*.$marc_suffix");
my $index_log = 1;
foreach my $marc_file (@marc_file) {
  my $proceed_with_export = 0;
  if ($enforce_marc_file_pattern_match eq 'true') {
    if ($marc_file =~ /hzbibs_20[0-9]{6}_[1-8]{1}\.mrc$/) {
      $proceed_with_export = 1;
    }
  } else {
    $proceed_with_export = 1;
  }
  if ($proceed_with_export) {
    my $pid = fork();
    if ($pid) { # parent process
      $kid_pid{$pid} = $marc_file;
      $index_log++;
    } elsif ($pid == 0) { # child process
      print "Indexing file $marc_file (" . localtime() . ")...\n";
      if (system("bin/indexfile $solrmarc_dir/$solrmarc_config $marc_file > $solrmarc_dir/index_log.$index_log 2>&1") == 0) {
        print "SolrMARC processing complete for $marc_file " . localtime() . ").\n";
      } else {
        die "SolrMARC processing ended in an error condition for $marc_file, check logs\n";
      }    
      print "Backfill with Horizon and Syndetics data for $marc_file (" . localtime() . ")...\n";
      if (system("hcl/indexfile.pl $solrmarc_dir/$solrmarc_config $marc_file >> $solrmarc_dir/index_log.$index_log 2>&1") == 0) {
        print "Backfill processing complete for $marc_file (" . localtime() . ").\n";
      } else {
        die "Backfill processing ended in an error condition for $marc_file, check logs\n";
      }
      exit;
    } else {
      die "Couldn't fork process for $marc_file: $!\n";
    }
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

# optimize core for better performance
print "Optimizing core...\n";
$ua->timeout(600); # set timeout to 10 minutes
$request->uri("$solr_app/${solr_core}/update?optimize=true");
$response = $ua->request($request);
if ($response->is_success) {
  my $optimize_status = XMLin($response->content);
  if ($$optimize_status{lst}{'int'}{status}{content} == 0) { # successful optimization
    print "done (" . localtime() . ").\n";
  } else {
    die "Optimization failed.\n";
  }
} else {
  die "Can't optimize core: " . $response->status_line . "\n";
}

# backup core
print "Backing up core...\n";
$ua->timeout(600); # set timeout to 10 minutes
$request->uri("$solr_app/${solr_core}/replication?command=backup&location=$solr_backup_dir&numberToKeep=$solr_backup_retention");
$response = $ua->request($request);
if ($response->is_success) {
  my $optimize_status = XMLin($response->content);
  if ($$optimize_status{lst}{'int'}{status}{content} == 0) { # successful backup
    print "done (" . localtime() . ").\n";
  } else {
    warn "Backup failed.\n";
  }
} else {
  warn "Can't backup core: " . $response->status_line . "\n";
}

# reenable replication
print "Reenabling core replication...";
$ua->timeout(180); # set timeout back to 3 minutes
$request->uri("$solr_app/${solr_core}/replication?command=enablereplication");
$response = $ua->request($request);
if ($response->is_success) {
  my $enable_rep_status = XMLin($response->content);
  if ($$enable_rep_status{lst}{'int'}{status}{content} == 0) { # replication enabled
    print "replication enabled.\n";
  } else {
    die "Unable to enable replication on core $solr_core.\n";
  }
} else {
  die "Unable to enable replication on core $solr_core.\n";
}

# force search core to replicate
print "Forcing search core replication...";
$ua->timeout(180); # set timeout back to 3 minutes
$request->uri("$solr_app/${solr_core}/replication?command=enablereplication");
$response = $ua->request($request);
if ($response->is_success) {
  my $enable_rep_status = XMLin($response->content);
  if ($$enable_rep_status{lst}{'int'}{status}{content} == 0) { # replication enabled
    print "replication enabled.\n";
  } else {
    die "Unable to enable replication on core $solr_core.\n";
  }
} else {
  die "Unable to enable replication on core $solr_core.\n";
}

# force replicatation the search core
print "Forcing replication\n";
my $replication_start_time = time();
my $req_solr_replicate = HTTP::Request->new('GET', "$solr_search_app/${solr_search_core}/replication?command=fetchindex" );
my $response_solr_replicate = $ua->request($req_solr_replicate);
unless ($response_solr_replicate->is_success) {
  warn "Error replicating: " . $response_solr_replicate->status_line . "\n";
}
my $replicate_response = XMLin($response_solr_replicate->content);
if ($$replicate_response{lst}{'int'}{status}{content} == 0) { # successful replication
  print "Replication initiated. Waiting for replication to finish\n";
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
      my $replication_end_time = time();
      my $replication_duration = $replication_end_time - $replication_start_time;
      $dbh_hz->do("
        insert hcl_solr_replication_log (timestamp, duration)
        values($replication_end_time, $replication_duration)
      ");
      $replication_finished = 1;
    }
  }
}

print "Allowing horizon bib export and dynamic indexing again...\n";
# remove the flag so that bib export starts again
$sth_prevent_bib_export->bind_param(1, 0, SQL_BIT);
$sth_prevent_bib_export->execute();
# remove the flag so that dynamic indexing starts again
$sth_prevent_horizon_dynamic->bind_param(1, 0, SQL_BIT);
$sth_prevent_horizon_dynamic->execute();

if ($overdrive && $overdrive eq 'true') {
  # clean out the hcl_overdrive_availability table in Horizon to get rid of deleted records
  #### Step 1 - find all the bibs with Overdrive IDs
  print "Finding all Overdrive bibs in the Horizon db...";
  # generate the list of overdrive ids
  my $get_od_bibs = $dbh_hz->selectall_arrayref("
    select distinct bib# from bib
    where text like '%econtent.hclib.org/ContentDetails.htm?ID%'
  ") or die("Could not execute selectall_arrayref against bib: $DBI::errstr");
  print @{$get_od_bibs} . " bibs found\n";

  # spin into a hash
  my %od_bib;
  foreach my $i (@{$get_od_bibs}) {
    $od_bib{$$i[0]} = 1;
  }

  #### Step 2 - Get all the bibs from the hcl_overdrive_availability table
  print "Selecting bibs from hcl_overdrive_availability table...";
  my $get_od_avail_bibs = $dbh_hz->selectall_arrayref("
    select bib_id from hcl_overdrive_availability
  ") or die "Error selecting bibs from hcl_overdrive_availability table: $DBI::errstr";
  print @{$get_od_avail_bibs} . " bibs found\n";

  #### Step 3 - Run through the bib ids in the hcl_overdrive_availability table
  # delete rows that are no longer in Horizon
  my $sth_delete_od_avail = $dbh_hz->prepare("
    delete from hcl_overdrive_availability
    where bib_id = ?
  ") or die "Can't prepare query: $DBI::errstr\n";
  print "Deleting hcl_overdrive_availability rows for deleted bibs...";
  my $n_deleted = 0;
  foreach my $i (@{$get_od_avail_bibs}) {
    unless ($od_bib{$$i[0]}) {
      $sth_delete_od_avail->execute($$i[0]);
      $n_deleted++;
    }
  }
  print "$n_deleted deleted\n";
}

exit;