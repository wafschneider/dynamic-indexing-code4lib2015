#!/usr/bin/perl

# this script watchs for problems in the following scripts:
# - hcl_solr_bib_export.pl running on POLOMOCHE
# - dynamicindex.pl running on INDEX (HCLCUTTER)
# - overdriveupdate.pl running on INDEX (HCLCUTTER)
# - ldap_update running on HCLLOCKE

# - this script is designed to run as a scheduled task every 15 minutes at 0, 15, 30, and 45 minutes past the hour

use strict;
use warnings;
use Config::Properties;
use DBI qw(:sql_types);
use Date::Calc qw(:all);
use Mail::Sendmail;
use Data::Dumper;

$| = 1;

# Initialize properties
my $properties_file = shift(@ARGV);
die "Usage: index_safetynet.pl <properties_file>\n" unless $properties_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die("Can't read properties file $properties_file: $!\n");

my $hz_server = $properties->requireProperty('hcl.hz_server');
my $hz_password = $properties->requireProperty('hcl.hz_password');
my $hz_user = $properties->requireProperty('hcl.hz_user');
my $hz_database = $properties->requireProperty('hcl.hz_database');
my $email_to = $properties->requireProperty('safetynet.email_to');
my $email_from = $properties->requireProperty('safetynet.email_from');
my $email_smtp = $properties->requireProperty('safetynet.email_smtp');

my $errlog = 'index_safetynet.log';
open(STDERR,">>$errlog")
  or warn "Can't open $errlog: $!\n";

my %errors = ();

# make a connection to the Horizon db
my $dbh = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password);
$dbh->do("use $hz_database") or task_die("Could not use database: $DBI::errstr");

print "Looking for indexing/updating errors...\n";

# hcl_solr_bib_export.pl 
# the script has a minimum cycle time of 300 seconds
# hcl_solr_bib_export.pl runs continuously
# check for errors recorded in the past 16 minutes (960 seconds)
print "hcl_solr_bib_export.pl\n";
my $right_now = time();
my $error_check_window = $properties->requireProperty('safetynet.errortime');
my $error_check_time = $right_now - $error_check_window;
my $error_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_solr_bib_export_log
  where timestamp > $error_check_time
  and n_exported < 0
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if ($$error_check[0]) {
  print " - ACK! recent errors found\n";
  push(@{$errors{hcl_solr_bib_export}}, "Error(s) detected in hcl_solr_bib_export_log");
} else {
  print " - no recent errors\n";
}
# check to make sure entries have been recorded in the past 10 minutes (600 seconds)
my $recent_check_window = $properties->requireProperty('safetynet.bibexport.recenttime');
my $recent_check_time = $right_now - $recent_check_window;
my $recent_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_solr_bib_export_log
  where timestamp > $recent_check_time
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if (!$$recent_check[0]) {
  print " - ACK! no recent entries found\n";
  push(@{$errors{hcl_solr_bib_export}}, "No entries found in hcl_solr_bib_export_log in the last $recent_check_window seconds");
} else {
  print " - recent entries found\n";
}
# Cull the log down to the most recent 36 hours (129600 seconds)
my $cull_threshold = $properties->requireProperty('safetynet.culltime');
my $cull_time = $right_now - $cull_threshold;
$dbh->do("
  delete hcl_solr_bib_export_log
  where timestamp < $cull_time
") or task_warn("Could not delete hcl_solr_bib_export_log rows: $DBI::errstr\n");

# dynamicindex_cron.pl
print "\ndynamicindex.pl\n";
$right_now = time();
# check for errors
$error_check_time = $right_now - $error_check_window;
$error_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_solr_bib_index_log
  where timestamp > $error_check_time
  and n_records < -1
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if ($$error_check[0]) {
  print " - ACK! recent errors found\n";
  push(@{$errors{dynamicindex}}, "Error(s) detected in hcl_solr_bib_index_log");
} else {
  print " - no recent errors\n";
}
# check to make sure entries have been recorded recently
$recent_check_window = $properties->requireProperty('safetynet.horizon.recenttime');
$recent_check_time = $right_now - $recent_check_window;
$recent_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_solr_bib_index_log
  where timestamp > $recent_check_time
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if (!$$recent_check[0]) {
  print " - ACK! no recent entries found\n";
  push(@{$errors{dynamicindex}}, "No entries found in hcl_solr_bib_index_log in the last $recent_check_window seconds");
} else {
  print " - recent entries found\n";
}
# Cull the log down to the most recent 36 hours (129600 seconds)
$cull_time = $right_now - $cull_threshold;
$dbh->do("
  delete hcl_solr_bib_index_log
  where timestamp < $cull_time
") or task_warn("Could not delete hcl_solr_bib_index_log rows: $DBI::errstr\n");
# Cull the index log files to the most recent 36 hours (129600 seconds)
# use the timestamp in the filename to determine
my $index_log_dir = $properties->requireProperty('safetynet.bibexport.logdir');
my @index_log_files = glob("${index_log_dir}index_me_*.log");
foreach my $ilf (@index_log_files) {
  if ($ilf =~ /index_me_([0-9]{10,})_[al0-9]{1,3}\.log/) {
    my $log_time = $1;
    if ($cull_time > $log_time) {
      unlink($ilf) or task_warn("Could not delete file $ilf\n");
    }
  }
}
# check for recent replication
$recent_check_window = $properties->requireProperty('safetynet.replication.recenttime');
$recent_check_time = $right_now - $recent_check_window;
$recent_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_solr_replication_log
  where timestamp > $recent_check_time
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if (!$$recent_check[0]) {
  print " - ACK! no recent entries found\n";
  push(@{$errors{dynamicindex}}, "No entries found in hcl_solr_replication_log in the last $recent_check_window seconds");
} else {
  print " - recent entries found\n";
}
## Cull the log down to the most recent 36 hours (129600 seconds)
#$cull_time = $right_now - $cull_threshold;
#$dbh->do("
#  delete hcl_solr_replication_log
#  where timestamp < $cull_time
#") or task_warn("Could not delete hcl_solr_replication_log rows: $DBI::errstr\n");
# strip out non-replications
$dbh->do("
  delete hcl_solr_replication_log
  where duration = 0
") or task_warn("Could not delete hcl_solr_replication_log rows: $DBI::errstr\n");

# overdriveupdate.pl
# the script has a minimum cycle time of 360 seconds (6 min)
# logs values of -1 when overdrive indexing is prevented
print "\noverdriveupdate.pl\n";
$right_now = time();
# check for errors
$error_check_time = $right_now - $error_check_window;
$error_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_overdrive_index_log
  where timestamp > $error_check_time
  and n_newly_unavailable < -1
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if ($$error_check[0]) {
  print " - ACK! recent errors found\n";
  push(@{$errors{overdriveupdate}}, "Error detected in hcl_overdrive_index_log");
} else {
  print " - no recent errors\n";
}
# check to make sure entries have been recorded in the past 24 minutes (1440 seconds)
$recent_check_window = $properties->requireProperty('safetynet.overdrive.recenttime');
$recent_check_time = $right_now - $recent_check_window;
$recent_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_overdrive_index_log
  where timestamp > $recent_check_time
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if (!$$recent_check[0]) {
  print " - ACK! no recent entries found\n";
  push(@{$errors{overdriveupdate}}, "No entries found in hcl_overdrive_index_log in the last $recent_check_window seconds");
} else {
  print " - recent entries found\n";
}
# Cull the log down to the most recent 36 hours (129600 seconds)
$cull_time = $right_now - $cull_threshold;
$dbh->do("
  delete hcl_overdrive_index_log
  where timestamp < $cull_time
") or task_warn("Could not delete hcl_overdrive_index_log rows: $DBI::errstr\n");

# ldap_update
# the script has a min cycle time of 5 seconds and runs continually
print "\nldap_update.pl\n";
$right_now = time();
# check to make sure entries have been recorded in the past 2 minutes (120 seconds)
$recent_check_window = $properties->requireProperty('safetynet.ldap.recenttime');
$recent_check_time = $right_now - $recent_check_window;
$recent_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_ldap_update_log
  where timestamp > $recent_check_time
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if (!$$recent_check[0]) {
  print " - ACK! no recent entries found\n";
  push(@{$errors{ldap_update}}, "No entries found in hcl_ldap_update_log in the last $recent_check_window seconds");
} else {
  print " - recent entries found\n";
}
# check for how many updates are queued up
my $ldap_pending_threshold = $properties->requireProperty('safetynet.ldap.pending_threshold');
my $ldap_pending_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_ldap_pending
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
my $ldap_pending_count = $$ldap_pending_check[0];
if ($ldap_pending_count > $ldap_pending_threshold) {
  push(@{$errors{ldap_update}}, "There are $ldap_pending_count updates queued up!");
  print " - ACK! too many updates queued up ($ldap_pending_count)!\n";
} else {
  print " - not too many updates queued up\n";
}
# Cull the log down to the most recent 36 hours (129600 seconds)
$cull_time = $right_now - $cull_threshold;
$dbh->do("
  delete hcl_ldap_update_log
  where timestamp < $cull_time
") or task_warn("Could not delete hcl_ldap_update_log rows: $DBI::errstr\n");

# hcl_solr_index_control
print "\nhcl_solr_index_control\n";
my $overdrive_recenttime = $properties->requireProperty('safetynet.overdrive.recenttime');
my $horizon_recenttime = $properties->requireProperty('safetynet.horizon.recenttime');
my $overdrive_resetafter = $properties->requireProperty('safetynet.overdrive.resetafter');
my $horizon_resetafter = $properties->requireProperty('safetynet.horizon.resetafter');
my $sth_update_sic_overdrive_is_running = $dbh->prepare("exec hcl_update_sic_overdrive_is_running ?");
my $sth_update_sic_horizon_is_running = $dbh->prepare("exec hcl_update_sic_horizon_is_running ?");
my $get_sic_records = $dbh->selectall_arrayref("select control,value,secs_since_last_update = datediff(ss, last_update, getdate()) from hcl_solr_index_control");
if ($get_sic_records) {
  foreach my $sic_record (@$get_sic_records) {
    my($control, $value, $secs_since_last_update) = @$sic_record;
    my($sec, $min, $hr, $mday, $mon, $year, $wday) = (localtime(time()))[0..6];
    if ($control eq 'prevent_horizon_dynamic') {
      print "  prevent_horizon_dynamic\n";
      if (($hr > 6) && (($hr < 21) || (($hr == 21) && ($min < 30)))) {
        if (($value == 1) && ($secs_since_last_update > 120)) {
          print "   - ACK! prevent_horizon_dynamic is true and the last update is too old\n";
          push(@{$errors{solr_index_control}}, "prevent_horizon_dynamic is true and the last update was over 120 seconds ago");
        } else {
          print "   - fine\n";
        }
      }
    } elsif ($control eq 'prevent_overdrive_dynamic') {
      print "  prevent_overdrive_dynamic\n";
      if (($hr > 6) && (($hr < 21) || (($hr == 21) && ($min < 30)))) {
        if (($value == 1) && ($secs_since_last_update > 120)) {
          print "   - ACK! prevent_overdrive_dynamic is true and the last update is too old\n";
          push(@{$errors{solr_index_control}}, "prevent_overdrive_dynamic is true and the last update was over 120 seconds ago");
        } else {
          print "   - fine\n";
        }
      }
    } elsif ($control eq 'overdrive_dynamic_is_running') {
      print "  overdrive_dynamic_is_running\n";
      if ($secs_since_last_update > $overdrive_recenttime) {
        print "   - ACK! last update is too old\n";
        push(@{$errors{solr_index_control}}, "Last update for overdrive_dynamic_is_running is over $overdrive_recenttime seconds ago");
      } else {
        print "   - last update is recent\n";
      }
      # if the value is 1 and resetafter value has been reached, reset the damn sic flag
      if ($value && ($secs_since_last_update > $overdrive_resetafter)) {
        print "    - WOW! overdrive_dynamic_is_running is true and the last update was over $overdrive_resetafter seconds ago.  Resetting the control\n";
        push(@{$errors{solr_index_control}}, "overdrive_dynamic_is_running is true and the last update was over $overdrive_resetafter seconds ago.  Resetting the control");
        $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
        $sth_update_sic_overdrive_is_running->execute();
      }
    } elsif ($control eq 'horizon_dynamic_is_running') {
      print "  horizon_dynamic_is_running\n";
      if (($hr > 7) || ($hr == 0)) {
        if ($secs_since_last_update > $horizon_recenttime) {
          print "   - ACK! last update is too old\n";
          push(@{$errors{solr_index_control}}, "Last update for horizon_dynamic_is_running is over $horizon_recenttime seconds ago");
        } else {
          print "   - last update is recent\n";
        }
      }
      # if the value is 1 and resetafter value has been reached, reset the damn sic flag
      if ($value && ($secs_since_last_update > $horizon_resetafter)) {
        print "    - WOW! horizon_dynamic_is_running is true and the last update was over $overdrive_resetafter seconds ago.  Resetting the control\n";
        push(@{$errors{solr_index_control}}, "horizon_dynamic_is_running is true and the last update was over $overdrive_resetafter seconds ago.  Resetting the control");
        $sth_update_sic_horizon_is_running->bind_param(1, 0, SQL_BIT);
        $sth_update_sic_horizon_is_running->execute();
      }
    }
  }
}

# hcl_frbr_update
# the script has a min cycle time of 60 seconds and runs continually
print "\nhcl_update_frbr.pl\n";
$right_now = time();
# check to make sure entries have been recorded in the past 5 minutes (300 seconds)
$recent_check_window = $properties->requireProperty('safetynet.frbr.recenttime');
$recent_check_time = $right_now - $recent_check_window;
$recent_check = $dbh->selectrow_arrayref("
  select count(*) from hcl_frbr_update_log
  where timestamp > $recent_check_time
") or task_die("Could not selectrow_arrayref: $DBI::errstr");
if (!$$recent_check[0]) {
  print " - ACK! no recent entries found\n";
  push(@{$errors{frbr_update}}, "No entries found in hcl_frbr_update_log in the last $recent_check_window seconds");
} else {
  print " - recent entries found\n";
}
# Cull the log down to the most recent 36 hours (129600 seconds)
$cull_time = $right_now - $cull_threshold;
$dbh->do("
  delete hcl_frbr_update_log
  where timestamp < $cull_time
") or task_warn("Could not delete hcl_frbr_update_log rows: $DBI::errstr\n");

if (%errors) {
  print "\n\nError detected!!  Sending email\n";
  # errors detected.  send an email
  my %email = ();
  $email{to} = $email_to;
  $email{from} = $email_from;
  $email{smtp} = $email_smtp;
  $email{subject} = 'Dynamic indexing/updating error(s) detected';
  $email{message} = "The following indexing/updating error(s) were detected:\n\n";
  foreach my $process (sort(keys(%errors))) {
    $email{message} .= "$process:\n";
    foreach my $error (@{$errors{$process}}) {
      $email{message} .= "  $error\n";
    }
    $email{message} .= "\n";
  }
  sendmail(%email);
} else {
  print "\n\nNo errors detected.  Yay!\n";
}
exit;


sub task_warn {
  my $errmsg = shift;
  my $ts = timestamp();
  warn("$ts  $errmsg\n");
}

sub task_die {
  my $errmsg = shift;
  my $ts = timestamp();
  die("$ts  $errmsg\n");
}

sub timestamp {
  my($y, $mo, $d, $h, $mi, $s) = Today_and_Now();
  $mi = sprintf("%02d",$mi);
  $s = sprintf("%02d",$s);
  return "$mo/$d/$y $h:$mi:$s";
}
