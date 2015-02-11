#!/usr/bin/perl

# overdriveupdate.pl
# Overdrive availability updater for HCL discovery layer
# takes properties file as an argument, otherwise fails
# contacts Overdrive API to get availability information, updates Horizon database
use strict;
use warnings;

use XML::Simple;
use LWP;
use Config::Properties;
use DBI qw(:sql_types);
use MARC::Batch;
use MIME::Base64;
use LWP::UserAgent; 
use HTTP::Request::Common qw(POST GET);
use HTTP::Headers;
use JSON;
use Proc::Daemon;

$| = 1;

# Initialize properties
my $properties_file = shift(@ARGV);
die "Usage: overdriveupdate.pl <properties_file>\n" unless $properties_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die "Can't read properties file $properties_file: $!\n";

my $hz_server = $properties->requireProperty('hcl.hz_server');
my $hz_password = $properties->requireProperty('hcl.hz_password');
my $hz_user = $properties->requireProperty('hcl.hz_user');
my $hz_database = $properties->requireProperty('hcl.hz_database');

my $logfile = $properties->requireProperty('hcl.overdrive.logfile');
my $pid_file = $properties->requireProperty('hcl.overdrive.pidfile');
my $outfile;
if ($properties->getProperty('hcl.overdrive.loglevel')) {
  $outfile = $logfile;
} else {
  $outfile = '/dev/null';
}

my ($login,$pw,$uid,$gid) = getpwnam($properties->requireProperty('hcl.overdrive.user'));
open(LOGFILE,">>",$logfile) or die "Can't open logfile: $!\n";
close(LOGFILE);
open(PIDFILE,">",$pid_file) or die "Can't open PID file: $!\n";
close(PIDFILE);
chown($uid,$gid,($logfile,$pid_file)) or die "Can't chown $logfile or $pid_file: $!\n";

my $daemon = Proc::Daemon->new(
  child_STDOUT => $outfile,
  child_STDERR => $logfile,
  setuid => $login,
  pid_file => $pid_file
);

my $kid_pid = $daemon->Init;
unless ($kid_pid) {
  warn localtime() . " starting Overdrive availability updater.\n";

  my $od_cycle_time = $properties->requireProperty('hcl.overdrive.cycle_time');
  my $od_client_key = $properties->requireProperty('hcl.overdrive.client_key');
  my $od_client_secret = $properties->requireProperty('hcl.overdrive.client_secret');
  my $od_oauth_url = $properties->requireProperty('hcl.overdrive.oauth_url');
  my $od_api_stem = $properties->requireProperty('hcl.overdrive.od_api_stem');
  my $od_api_suffix = $properties->requireProperty('hcl.overdrive.od_api_suffix');
  my $od_collection_key = $properties->requireProperty('hcl.overdrive.collection_key');
  my $od_api_limit_value = $properties->requireProperty('hcl.overdrive.od_api_limit_value');
  
  my $ostart;
  my $start;
  my $end;
  my $duration;
  my $n_newly_available;
  my $n_newly_unavailable;
  
  MAINLOOP: while (1 == 1) {
    print "\n\n*****************************************\nStarting new cycle (" . localtime() .")\n";  
    $ostart = time();
    $start = time();
    
    my $hz_dbh = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password);
    $hz_dbh->do("use $hz_database") or die("Could not use database: $DBI::errstr");
    
    my $sth_update_sic_overdrive_is_running = $hz_dbh->prepare("exec hcl_update_sic_overdrive_is_running ?");
    my $check_overdrive_dynamic_prevented = $hz_dbh->selectall_arrayref("
      select value from hcl_solr_index_control where control = 'prevent_overdrive_dynamic'
    ");
    if ($$check_overdrive_dynamic_prevented[0][0]) {
      # red light
      # overdrive dynamic indexing is currently prevented
      # set exception values for logging
      $n_newly_available = -1;
      $n_newly_unavailable = -1;
      
    } else {
      # green light
      
      # let other processes know that overdrive dynamic is running
      $sth_update_sic_overdrive_is_running->bind_param(1, 1, SQL_BIT);
      $sth_update_sic_overdrive_is_running->execute();      
      
      # Step 1 - authenticate to the API
      my($access_token, $token_type, $expires_in);
      my $authorization_string = "$od_client_key:$od_client_secret";
      my $authorization_string_enc = encode_base64($authorization_string);
      my $auth_string = "Basic $authorization_string_enc";
      
      my $req = HTTP::Request->new(POST => $od_oauth_url);
      $req->content_type('application/x-www-form-urlencoded;charset=UTF-8');
      $req->authorization("$auth_string");
      $req->content('grant_type=client_credentials');
      
      my $ua = LWP::UserAgent->new;
      my $res = $ua->request($req);
      if ($res->is_success) {
        my $oauth_response_json = decode_json($res->content);
        $access_token = $$oauth_response_json{access_token};
        $token_type = $$oauth_response_json{token_type};
        $expires_in = $$oauth_response_json{expires_in};
        if ((length($access_token) > 200) && $token_type && ($expires_in > 10)) {
          # fairly pitiful but super easy validation
          $access_token = $$oauth_response_json{access_token};
          $token_type = $$oauth_response_json{token_type};
          $expires_in = $$oauth_response_json{expires_in};
        } else {
          $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
          $sth_update_sic_overdrive_is_running->execute();
          warn "There was a problem getting the Overdrive API credentials, sleeping $od_cycle_time seconds\n";
          sleep $od_cycle_time;
          next;
        }
      } else {
        $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
        $sth_update_sic_overdrive_is_running->execute();
        warn "There was a problem getting the Overdrive API credentials, sleeping $od_cycle_time seconds\n";
        sleep $od_cycle_time;
        next;
      }
      
      # Step 2 - get the list of UNavailable overdrive_ids from the API
      print "Getting list of unavailable ids from the API...\n";
      my %od_unavailable = ();
      my $success = 0;
      my $retries = 0;
      my $result_set_size = 0;
      my $n_ids_in_hash = 0;
      
      while (!$success) {
        if ($retries > 4) {
          $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
          $sth_update_sic_overdrive_is_running->execute();
          warn "Gave up after 5 tries at getting records from the Overdrive API, sleeping $od_cycle_time seconds\n";
          sleep $od_cycle_time;
          next MAINLOOP;
        }
        
        # make sure we're starting with an empty hash
        my $n_keys = (keys(%od_unavailable));
        if ($n_keys) {
          %od_unavailable = ();
        }
        
        my $next_batch_url = $od_api_stem . $od_collection_key . $od_api_suffix . $od_api_limit_value;
        
        my $bidx = 0;
        while ($next_batch_url) {
          $bidx++;
          if ($bidx % 5 == 0) {
            print "$bidx";
          } else {
            print ".";
          }
        
          # check availability from OverDrive API
          my $headers = HTTP::Headers->new;
          $headers->header('Authorization' => "$token_type $access_token");
          $headers->header('User-Agent' => 'HCL Indexer');
          $headers->header('X-Forwarded-For' => '207.225.131.140');
          my $req_od = HTTP::Request->new('GET', $next_batch_url, $headers);
          $res = $ua->request($req_od);
          if ($res->is_success) {
            my $response;
            
            my $eval_result = eval {
              $response = decode_json($res->content);
            };
            
            unless($eval_result) {
              $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
              $sth_update_sic_overdrive_is_running->execute();
              warn ("Error reading JSON: " . $@ . "\nSleeping $od_cycle_time seconds...\n");
              sleep $od_cycle_time;
              next MAINLOOP;
            }
            
            # check for the requisite elements
            $result_set_size = $response->{totalItems};
            my $self_url = $response->{links}->{self}->{href};
            
            if ($result_set_size && ($self_url =~ /\/v1\/collections\/$od_collection_key\/products/)) {
              # requisite elements are present - must have been a good response
              
              # grab the ids and add them to the hash
              foreach my $hash_ref (@{$response->{products}}) {
                my $id = $hash_ref->{id};
                $id = uc($id);
                $od_unavailable{$id}++;
              }
              
              # next page
              $next_batch_url = $response->{links}->{next}->{href};
              if ($next_batch_url) {
                $next_batch_url =~ s/^http:\/\/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/v1\/collections\//$od_api_stem/;
              }
            
            } else {
              # zap next_batch_url and exit the while loop
              $next_batch_url = '';
            }
          
          } else {
            # zap next_batch_url and exit the while loop
            $next_batch_url = '';
          }
        }
        print "\n";
        # the sum of the counts from the ids in the hash should be the same as the last $result_set_size
        my $n_ids_returned = 0;
        foreach my $k (keys(%od_unavailable)) {
          $n_ids_returned += $od_unavailable{$k};
        }
        $n_ids_in_hash = (keys(%od_unavailable));
        if ($n_ids_returned == $result_set_size) {
          $success = 1;
          print "Success!\n";
        } else {
          warn "Yak!?! n_ids_returned: $n_ids_returned  result_set_size: $result_set_size  n_ids_in_hash: $n_ids_in_hash\n";
        }
        $retries++;
      }
      if (keys(%od_unavailable) == 0) {
        $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
        $sth_update_sic_overdrive_is_running->execute();
        warn "There were no unavailable records returned from the Overdrive API?!?! Sleeping $od_cycle_time seconds...\n";
        sleep $od_cycle_time;
        next;
      }
      $end = time();
      my $duration = $end - $start;
      print "That took $duration seconds\n\n";
      
      # Step 2 - get the list of ids from horizon with their previous availability and compare to the current list of unavailable
      print "Comparing to the last time...\n";
      $start = time();
      my $get_old = $hz_dbh->selectall_arrayref("
        select bib_id, overdrive_id, available from hcl_overdrive_availability
      ");
      
      my $sth_update = $hz_dbh->prepare("
        update hcl_overdrive_availability
          set available = ?
        where bib_id = ?
      ");
      
      my $sth_insert = $hz_dbh->prepare("
        insert hcl_solr_pending
        (RecNum,RecType,Action)
        values(?,0,2)
      ");
      
      $n_newly_available = 0;
      $n_newly_unavailable = 0;
      
      # if changed, update hcl_overdrive_availability and flag in hcl_overdrive_pending
      foreach my $old_ref (@$get_old) {
        my($bid, $odid, $was_available) = @$old_ref;
        my $overdrive_id = uc($odid);
        if ($was_available) {
          if (exists($od_unavailable{$overdrive_id})) {
            $sth_update->bind_param(1, 0, SQL_BIT);
            $sth_update->bind_param(2, $bid, SQL_INTEGER);
            $sth_update->execute();
            $sth_insert->bind_param(1, $bid, SQL_INTEGER);
            $sth_insert->execute();
            $n_newly_unavailable++;
          }
        } else {
          if (!exists($od_unavailable{$overdrive_id})) {
            $sth_update->bind_param(1, 1, SQL_BIT);
            $sth_update->bind_param(2, $bid, SQL_INTEGER);
            $sth_update->execute();
            $sth_insert->bind_param(1, $bid, SQL_INTEGER);
            $sth_insert->execute();
            $n_newly_available++;
          }
        }
      }
      
      $sth_update->finish();
      $sth_insert->finish();
      
      $end = time();
      $duration = $end - $start;
      print "That took $duration seconds\n\n";
      
    }
    
    print "Changes: $n_newly_available newly available, $n_newly_unavailable newly unavailable\n";
    
    print "Updating the index log\n";
    $hz_dbh->do("
      insert hcl_overdrive_index_log
      (n_newly_unavailable, n_newly_available, timestamp)
      values($n_newly_unavailable,$n_newly_available,$ostart)
    ");
    $sth_update_sic_overdrive_is_running->bind_param(1, 0, SQL_BIT);
    $sth_update_sic_overdrive_is_running->execute();
    
    $end = time();
    $duration = $end - $start;
    print "That took $duration seconds\n\n";
    
    my $oduration = $end - $ostart;
    my $omin = int($oduration / 60);
    my $osec = $oduration % 60;
    print "Cycle complete (" . localtime() . ")\n";
    print "Overall that took $omin min, $osec sec\n\n";
    
    # disconnect from db
    $sth_update_sic_overdrive_is_running->finish();
    $hz_dbh->disconnect();
    
    my $sleep_time = 10;
    if ($oduration < $od_cycle_time) {
      $sleep_time = $od_cycle_time - $oduration;
    }
    print "Sleeping for $sleep_time seconds\n";
    sleep($sleep_time);
    
  }
} # end child process code


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
