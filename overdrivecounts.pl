#!/usr/bin/perl

# overdrivecounts.pl
# Overdrive copy and request count updater for HCL discovery layer
# takes properties file as an argument, otherwise fails
# contacts Overdrive API to get availability information and updates Hz database
use strict;
use warnings;

use XML::Simple;
use LWP;
use Config::Properties;
use DBI;
use MARC::Batch;
use MIME::Base64;
use LWP::UserAgent; 
use HTTP::Request::Common qw(POST GET);
use HTTP::Headers;
use JSON;
use Data::Dumper;

$| = 1;

# Initialize properties
my $properties_file = shift(@ARGV);
die "Usage: overdrivecounts.pl <properties_file>\n" unless $properties_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die "Can't read properties file $properties_file: $!\n";


my $hz_server = $properties->requireProperty('hcl.hz_server');
my $hz_password = $properties->requireProperty('hcl.hz_password');
my $hz_user = $properties->requireProperty('hcl.hz_user');
my $hz_database = $properties->requireProperty('hcl.hz_database');
my $od_client_key = $properties->requireProperty('hcl.overdrive.client_key');
my $od_client_secret = $properties->requireProperty('hcl.overdrive.client_secret');
my $od_oauth_url = $properties->requireProperty('hcl.overdrive.oauth_url');
my $od_api_stem = $properties->requireProperty('hcl.overdrive.od_api_stem');
my $od_api_suffix = $properties->requireProperty('hcl.overdrive.od_api_suffix');
my $od_collection_key = $properties->requireProperty('hcl.overdrive.collection_key');
my $od_api_limit_value = $properties->requireProperty('hcl.overdrive.od_api_limit_value');


my $hz_dbh = DBI->connect("DBI:Sybase:server=$hz_server;maxConnect=100",$hz_user,$hz_password);
$hz_dbh->do("use $hz_database") or die("Could not use database: $DBI::errstr");

my $sth_check = $hz_dbh->prepare("
  select count(*) from hcl_overdrive_availability
  where bib_id = ?
  and overdrive_id = ?
");
my $sth_update = $hz_dbh->prepare("
  update hcl_overdrive_availability
  set n_copies = ?, n_requests = ?
  where bib_id = ?
  and overdrive_id = ?
");

# get the list of OverDrive IDs
my $get_odids = $hz_dbh->selectall_arrayref("select bib_id, overdrive_id from hcl_overdrive_availability");

my $ua = LWP::UserAgent->new;

#authenticate to the API
my($access_token, $token_type, $expire_time, $auth_error) = authenticate();
die "$auth_error\n" if $auth_error;

my $start_time = time();
my $idx = 0;
my $n_updates = 0;
my $n_ids = @$get_odids;
foreach my $odid_ref (@$get_odids) {
  if ($idx && ($idx % 500 == 0)) {
    my $d = time() - $start_time;
    my $r = $idx / $d;
    print "$idx ($n_updates) of $n_ids processed ($r recs/sec)\n";
  }
  my($bid,$odid) = @$odid_ref;
  # check to see if we need a new auth token
  if ($expire_time - time() < 300) {
    # reauthenticate
    ($access_token, $token_type, $expire_time, $auth_error) = authenticate();
    die "$auth_error\n" if $auth_error;
  }
  my $od_url = $od_api_stem . $od_collection_key . '/products/' . $odid . '/availability';
  my $headers = HTTP::Headers->new;
  $headers->header('Authorization' => "$token_type $access_token");
  $headers->header('User-Agent' => 'HCL Indexer');
  $headers->header('X-Forwarded-For' => '207.225.131.140');
  my $req_od = HTTP::Request->new('GET', $od_url, $headers);
  my $res = $ua->request($req_od);
  if ($res->is_success) {
    my $response = decode_json($res->content);
    my $n_copies = $response->{copiesOwned};
    my $n_requests = $response->{numberOfHolds};
    my $n_available = $response->{copiesAvailable};
    
    my $check = $hz_dbh->selectall_arrayref($sth_check,undef,($bid,$odid));
    if ($$check[0][0]) {
      $sth_update->execute($n_copies,$n_requests,$bid,$odid);
      $n_updates++;
    } else {
      print "What?!? Check failed\n";
    }
  }
  $idx++;
}

my $duration = time() - $start_time;
my $rate = $idx / $duration;
print "$idx ($n_updates) of $n_ids processed ($rate recs/sec)\n\n";


sub authenticate {
  
  my($access_token, $token_type, $expire_time, $error) = ();
  
  my $authorization_string = "$od_client_key:$od_client_secret";
  my $authorization_string_enc = encode_base64($authorization_string);
  my $auth_string = "Basic $authorization_string_enc";
  
  my $req = HTTP::Request->new(POST => $od_oauth_url);
  $req->content_type('application/x-www-form-urlencoded;charset=UTF-8');
  $req->authorization("$auth_string");
  $req->content('grant_type=client_credentials');
  
  my $res = $ua->request($req);
  if ($res->is_success) {
    my $oauth_response_json = decode_json($res->content);
    $access_token = $$oauth_response_json{access_token};
    $token_type = $$oauth_response_json{token_type};
    my $expires_in = $$oauth_response_json{expires_in};
    if ((length($access_token) > 200) && $token_type && ($expires_in > 10)) {
      # fairly pitiful but super easy validation
      $expire_time = time() + $expires_in;
    } else {
      $error = "Error getting Overdrive API credentials: access_token $access_token, token_type $token_type, expires_in $expires_in";
    }
  } else {
    $error = 'Error getting Overdrive API credentials: is_success failure';
  }
  
  return($access_token, $token_type, $expire_time);
  
}

