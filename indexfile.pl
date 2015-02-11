#!/usr/bin/perl

# backfill indexing - Horizon and Syndetics data
# Meant to run immediately after solrmarc indexfile, using the same config file and MARC file for input
# run from solrmarc root
# Usage: indexfile.pl <config file> <MARC file>
use strict;
use warnings;
use Config::Properties;
use XML::Simple;
use LWP;
use JSON;
use MARC::Record;
use MARC::File::USMARC;
use DBI qw(:sql_types);
use Business::ISBN;
use Time::HiRes qw(gettimeofday tv_interval);
use MARC::Charset qw(marc8_to_utf8);
use Text::Iconv;
use Data::Dumper;

$| = 1;
my $start = [gettimeofday];

# Initialize properties
my ($properties_file,$marc_file) = @ARGV;
die "Usage: indexfile.pl <config file> <MARC file>\n" unless $properties_file && $marc_file;
my $properties = Config::Properties->new( file => $properties_file )
  or die "Can't read properties file $properties_file: $!\n";
my $solr_path = $properties->requireProperty('solr.hosturl');
my $hz_server = $properties->requireProperty('hcl.hz_server');
my $hz_password = $properties->requireProperty('hcl.hz_password');
my $hz_user = $properties->requireProperty('hcl.hz_user');
my $hz_database = $properties->requireProperty('hcl.hz_database');
my $syndetics = $properties->getProperty('hcl.syndetics');
my ($syndetics_user,$syndetics_pw,$syndetics_dsn,$syndetics_source);
if ($syndetics && $syndetics eq 'true') {
  $syndetics_user = $properties->requireProperty('hcl.syndetics_user');
  $syndetics_pw = $properties->requireProperty('hcl.syndetics_pw');
  $syndetics_dsn = $properties->requireProperty('hcl.syndetics_dsn');
  $syndetics_source = $properties->requireProperty('hcl.syndetics_source');
}
my $overdrive = $properties->getProperty('hcl.overdrive');
my $solrmarc_dir = $properties->requireProperty('hcl.solrmarc_dir');

# enhance record with information from Horizon and Syndetics
my $hz_dbh = DBI->connect("dbi:Sybase:server=$hz_server;database=$hz_database;maxConnect=100;charset=cp850",$hz_user,$hz_password)
  or die "Can't connect to Horizon: $DBI::errstr\n";
my $syndetics_dbh;
if ($syndetics && $syndetics eq 'true') {
  $syndetics_dbh = DBI->connect($syndetics_dsn, $syndetics_user, $syndetics_pw)
    or die "Can't connect to db: $DBI::errstr\n";
}

my $record_file = eval{ MARC::File::USMARC->in($marc_file); };
if ($record_file) {
  if ($@) {
    warn "Error reading MARC file $marc_file: $@\n";
  }
} else {
  if ($@) {
    die "Can't read MARC file $marc_file: $@\n";
  } else {
    die "No records in MARC file $marc_file\n";
  }
}

# Prepared queries for Horizon data
my $sth_collection = $hz_dbh->prepare("exec hcl_get_predominant_collection ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_item_call = $hz_dbh->prepare("exec hcl_get_predominant_call_reconstructed ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_ibarcodes = $hz_dbh->prepare("exec hcl_get_ibarcodes ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_author_sort = $hz_dbh->prepare("exec hcl_get_processed_author ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_title_sort = $hz_dbh->prepare("exec hcl_get_processed_title ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_public = $hz_dbh->prepare("exec hcl_get_bib_public ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_available = $hz_dbh->prepare("exec hcl_get_bib_availability_noref ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_available_ref = $hz_dbh->prepare("exec hcl_get_bib_availability_ref ?")
  or die "Can't prepare query: $DBI::errstr\n";
#my $sth_circ_count = $hz_dbh->prepare("exec hcl_get_bib_circulating ?")
#  or die "Can't prepare query: $DBI::errstr\n";
my $sth_locations = $hz_dbh->prepare("exec hcl_get_bib_locations ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_special_collections = $hz_dbh->prepare("exec hcl_get_special_collection ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_popularity_boost = $hz_dbh->prepare("exec hcl_get_pop_boost_data ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_cat_link_xrefs = $hz_dbh->prepare("exec hcl_get_cat_link_xrefs ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_solr_ready_xrefs = $hz_dbh->prepare("exec hcl_get_solr_ready_xrefs ?")
  or die "Can't prepare query: $DBI::errstr\n";

# Prepared queries for Overdrive
my ($sth_od_availability,$sth_od_update_odid,$sth_od_insert);
if ($overdrive && $overdrive eq 'true') {
  $sth_od_availability = $hz_dbh->prepare("
    select overdrive_id, available, n_copies, n_requests from hcl_overdrive_availability where bib_id = ?
  ") or die "Can't prepare query: $DBI::errstr\n";
  $sth_od_update_odid = $hz_dbh->prepare("
    update hcl_overdrive_availability
    set overdrive_id = ?,
    available = 1
    where bib_id = ?
  ") or die "Can't prepare query: $DBI::errstr\n";
  $sth_od_insert = $hz_dbh->prepare("
    insert into hcl_overdrive_availability
    (bib_id, overdrive_id, available)
    values
    (?, ?, 1)
  ") or die "Can't prepare query: $DBI::errstr\n";
}
my @solr_batch = (); # array for batch of solr atomic updates
my $language_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/language_map.properties' )
  or die "Missing or invalid language map file: $!\n";
my $format_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/hcl_format_map.properties' )
  or die "Missing or invalid format map file: $!\n";
my $availability_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/hcl_availability_map.properties' )
  or die "Missing or invalid availability map file: $!\n";
my $location_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/hcl_location_map.properties' )
  or die "Missing or invalid location map file: $!\n";
my $special_collection_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/hcl_special_collection_map.properties' )
  or die "Missing or invalid special collection map file: $!\n";
#my $circulating_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/hcl_circulating_map.properties' )
#  or die "Missing or invalid circulating map file: $!\n";
my $public_map = Config::Properties->new( file => $solrmarc_dir . '/translation_maps/hcl_public_map.properties' )
  or die "Missing or invalid public map file: $!\n";

# prepares for item data generation
my $sth_get_mc_floor_default = $hz_dbh->prepare("exec hcl_get_mc_floor_default")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_mc_floor_exception = $hz_dbh->prepare("exec hcl_get_mc_floor_exception")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_masked_location = $hz_dbh->prepare("exec hcl_get_masked_location")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_masked_collection = $hz_dbh->prepare("exec hcl_get_masked_collection")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_subscription_data = $hz_dbh->prepare("exec hcl_subscriptions_cfc ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_item_data = $hz_dbh->prepare("exec hcl_items_cfc ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_count_copy_issues = $hz_dbh->prepare("exec hcl_count_copy_issues ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_check_current_issue = $hz_dbh->prepare("exec hcl_check_current_issue ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_check_requestable = $hz_dbh->prepare("exec hcl_check_requestable ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_count_requests = $hz_dbh->prepare("exec hcl_count_requests ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_count_suspended_requests = $hz_dbh->prepare("exec hcl_count_suspended_requests ?")
  or die "Can't prepare query: $DBI::errstr\n";
my $sth_get_issue_data = $hz_dbh->prepare("exec hcl_issues_cfc ?")
  or die "Can't prepare query: $DBI::errstr\n";

# a few queries needed to provide information for item processing
# central floor
my %mc_floor_default = ();
my %mc_floor_exception = ();
my $get_mc_floor_default = $hz_dbh->selectall_arrayref($sth_get_mc_floor_default);
if (@{$get_mc_floor_default}) {
  foreach my $row_ref (@{$get_mc_floor_default}) {
    my($mc_loc, $mc_floor) = @{$row_ref};
    $mc_floor_default{$mc_loc} = $mc_floor;
  }
}
my $get_mc_floor_exception = $hz_dbh->selectall_arrayref($sth_get_mc_floor_exception);
if (@{$get_mc_floor_exception}) {
  foreach my $row_ref (@{$get_mc_floor_exception}) {
    my($mc_loc, $mc_coll, $mc_floor) = @{$row_ref};
    $mc_floor_exception{$mc_loc}{$mc_coll} = $mc_floor;
  }
}
# masked locations
my $get_masked_locations = $hz_dbh->selectall_arrayref($sth_get_masked_location);
my %masked_locations = ();
if (@{$get_masked_locations}) {
  foreach my $ml_ref (@$get_masked_locations) {
    my $ml = $$ml_ref[0];
    $masked_locations{$ml} = 1;
  }
}
# masked collections
my $get_masked_collections = $hz_dbh->selectall_arrayref($sth_get_masked_collection);
my %masked_collections = ();
if (@{$get_masked_collections}) {
  foreach my $mc_ref (@$get_masked_collections) {
    my $mc = $$mc_ref[0];
    $masked_collections{$mc} = 1;
  }
}
my %mc_location_sort = (
  'mc' => 1,
  'mcal' => 2,
  'mcbs' => 3,
  'mchs' => 4,
  'mcna' => 5,
  'mcgd' => 6,
  'mcsc' => 7
);
my $record_index = 0;
my $post_count = 0;
print "Updating records from $marc_file with enhanced data.\n";
while (my $marc = $record_file->next()) {
  my %update;
  my $bib = eval{ $marc->field('999')->subfield('a'); };
  if ($@) {
    warn "No bib# for record at position $record_index in $marc_file: $@\n";
    $record_index++;
    next;
  }
  $update{id} = $bib;
  
  #### item data ####
  # establish the variables - all will be included in the update
  my $in_house_only = 0; # covers both items and subscriptions
  my $mc_collection = ''; # covers both items and subscriptions
  my($num_items,$num_public_items,$num_onorder_items,$num_requestable,$in_house_only_items) = (0,0,0,0,0);
  my $mc_call = '';
  my %checked_in_libraries = ();
  my %checked_in_limited_access_libraries = ();
  my $requestable_item;
  my %mc_items = ();
  my $mc_collection_items = '';
  my $num_public_noncirc_items = 0;
  
  $sth_get_item_data->bind_param(1,$bib,SQL_INTEGER);
  my $get_item_data = $hz_dbh->selectall_arrayref($sth_get_item_data);
  
  # start of the item record loop
  foreach my $row_ref (@{$get_item_data}) {
    my($iid, $barcode, $location_code, $location_name, $collection, $collection_code, $float, $call, $copy, $note, $status_code, $itype, $status,
       $mask_pac_display, $last_useJ, $use, $due_dateJ, $status_setJ, $hcl_binding_public, $hcl_binding_staff, $issue_date, $creation_date) = @{$row_ref};
    
    # pretend that some items do not even exist
    if ($collection_code =~ /^zdep/) {
      next;
    }
    
    $call = '' unless $call;
    
    # how should it be counted?
    if ((substr($barcode,0,3) eq 'ord') && ($status_code eq 'order') && ($note =~ /~[0-9]+$/) && ($location_code eq 'cm')) {
      # Order of the Future
      my $num_onorder_oof = (split(/~/, $note))[1];
      $num_onorder_items += $num_onorder_oof;
      $num_requestable += $num_onorder_oof; # assume all OOF copies will be requestable
    } else {
      # requestable - need this data for binding-type specific requests
      $sth_check_requestable->bind_param(1,$iid,SQL_INTEGER);
      my $get_check_requestable = $hz_dbh->selectall_arrayref($sth_check_requestable);
      if (@{$get_check_requestable}) {
        if ($$get_check_requestable[0][0]) {
          $num_requestable++;
          $requestable_item = $iid;
        }
      }
      # On Order (but not OOF)
      if (($status_code eq 'order') || ($status_code eq 'r')) {
        # on order
        $num_onorder_items++;
      } else {
        $num_items++;
        # public or staff?
        # item is public if:
        # - the status is not masked
        # - the collection is not masked
        # - the location is not masked (except for location=ts && float=true)
        if (
             !$mask_pac_display
             && !exists($masked_collections{$collection_code})
             && (!exists($masked_locations{$location_code}) || (($location_code eq 'ts') && $float))
           ) {
          $num_public_items++;
          
          # check for non-circulating
          # used to find out if all of the public copies are non-circulating
          if ($itype eq 'nc') {
            $num_public_noncirc_items++;
          }
          
          # is it checked in?  save the library in the checked_in_libraries or checked_in_limited_access_libraries hash
          if ($status_code eq 'i') {
            my $library_code = $location_code;
            # make adjustments to location/library codes/names for MC and Su
            if ($location_code =~ /^mc/) {
              $library_code = 'mc';
            } elsif ($location_code eq 'susu') {
              $library_code = 'su';
            } elsif (($location_code eq 'ts') && ($float)) {
              $library_code = 'xx';  # unassigned
            }
            if (($collection =~ /secure stacks/i) || ($collection =~ /milestones/i) || ($collection_code =~ /^s/)) {
              # items are behind lock and key
              $checked_in_limited_access_libraries{$library_code}++;
            } else {
              $checked_in_libraries{$library_code}++;
            }
          }
          
          # is it a central copy?  add it to the hash to come up with mc_collection_items
          if ($location_code =~ /^mc/) {
            # Mpls Central floor
            my $central_floor = 1;
            if (exists($mc_floor_exception{$location_code}{$collection_code})) {
              $central_floor = $mc_floor_exception{$location_code}{$collection_code};
            } else {
              $central_floor = $mc_floor_default{$location_code};
            }
            if ($central_floor eq '1') {
              $central_floor = '(1<sup>st</sup> floor)';
            } elsif ($central_floor eq '2') {
              $central_floor = '(2<sup>nd</sup> floor)';
            } elsif ($central_floor eq '3') {
              $central_floor = '(3<sup>rd</sup> floor)';
            } elsif ($central_floor eq '4') {
              $central_floor = '(4<sup>th</sup> floor)';
            }
            my $mc_loc_sort = 7;
            if (exists($mc_location_sort{$location_code})) {
              $mc_loc_sort = $mc_location_sort{$location_code};
            }
            my $mc_loc_coll_call = $location_code . '|' . $collection . ' ' . $central_floor . '|' . $call;
            $mc_items{$mc_loc_coll_call}{count}++;
            $mc_items{$mc_loc_coll_call}{loc_sort} = $mc_loc_sort;
          }
        }
      }
    }
  }
  if (%mc_items) {
    # generate mc_collection_items and mc_call_items
    my @sorted_mc_items = sort { $mc_items{$b}{count} <=> $mc_items{$a}{count} || $mc_items{$a}{loc_sort} <=> $mc_items{$b}{loc_sort} } keys %mc_items;
    if (@sorted_mc_items) {
      my $mc_loc_coll_call = $sorted_mc_items[0];
      $mc_collection_items = (split(/\|/, $mc_loc_coll_call))[1];
      $mc_call = (split(/\|/, $mc_loc_coll_call))[2];
    }
  }
  my @checked_in_libs = keys(%checked_in_libraries);
  my @checked_in_limited_access_libs = keys(%checked_in_limited_access_libraries);
  if ($num_public_noncirc_items && ($num_public_noncirc_items == $num_public_items)) {
    $in_house_only_items = 1;
  }
  
  $update{num_items} = { set => $num_items };
  $update{num_public_items} = { set => $num_public_items };
  $update{num_onorder_items} = { set => $num_onorder_items };
  $update{num_requestable} = { set => $num_requestable };
  $update{checked_in_libraries} = { set => \@checked_in_libs };
  $update{checked_in_limited_access_libraries} = { set => \@checked_in_limited_access_libs };
  $update{requestable_item} = { set => $requestable_item };
  $update{mc_call_number_d} = { set => $mc_call };
  
  # subscriptions
  my($num_subscriptions,$num_public_subscriptions,$in_house_only_subscriptions) = (0,0,0);
  my %subscriptions_libraries = ();
  my $num_public_noncirc_subscriptions = 0;
  my %mc_subscriptions = ();
  my $mc_collection_subscriptions = '';
  $sth_get_subscription_data->bind_param(1,$bib,SQL_INTEGER);
  my $get_subscription_data = $hz_dbh->selectall_arrayref($sth_get_subscription_data);
  foreach my $row_ref (@{$get_subscription_data}) {
    my($sid, $location_code, $location_name, $collection_code, $collection, $note, $acq_status) = @$row_ref;
    $num_subscriptions++;
    # public?
    if (!exists($masked_locations{$location_code}) && ($location_code !~ /^(ts|cm)$/)) {
      $num_public_subscriptions++;
      # make adjustments to location/library codes/names for MC and Su
      my $library_code = $location_code;
      if ($location_code =~ /^mc/) {
        $library_code = 'mc';
      } elsif ($location_code eq 'susu') {
        $library_code = 'su';
      }
      $subscriptions_libraries{$library_code}++;
      # is it a central copy?  add it to the hash to come up with mc_collection_items
      if ($location_code =~ /^mc/) {
        # Mpls Central floor
        my $central_floor = 1;
        if (exists($mc_floor_exception{$location_code}{$collection_code})) {
          $central_floor = $mc_floor_exception{$location_code}{$collection_code};
        } else {
          $central_floor = $mc_floor_default{$location_code};
        }
        if ($central_floor eq '1') {
          $central_floor = '(1<sup>st</sup> floor)';
        } elsif ($central_floor eq '2') {
          $central_floor = '(2<sup>nd</sup> floor)';
        } elsif ($central_floor eq '3') {
          $central_floor = '(3<sup>rd</sup> floor)';
        } elsif ($central_floor eq '4') {
          $central_floor = '(4<sup>th</sup> floor)';
        }
        my $mc_loc_sort = 7;
        if (exists($mc_location_sort{$location_code})) {
          $mc_loc_sort = $mc_location_sort{$location_code};
        }
        my $mc_loc_coll = $location_code . '|' . $collection . ' ' . $central_floor;
        $mc_subscriptions{$mc_loc_coll}{count}++;
        $mc_subscriptions{$mc_loc_coll}{loc_sort} = $mc_loc_sort;
      }
      # non-circ?
      if ($collection =~ /reference/i) {
        $num_public_noncirc_subscriptions++;
      }
    }
  }
  my @subscriptions_libs = keys(%subscriptions_libraries);
  if ($num_public_subscriptions && ($num_public_noncirc_items == $num_public_subscriptions)) {
    $in_house_only_subscriptions = 1;
  }
  if (%mc_subscriptions) {
    # generate mc_collection_items and mc_call_items
    my @sorted_mc_subscriptions = sort { $mc_subscriptions{$b}{count} <=> $mc_subscriptions{$a}{count} || $mc_subscriptions{$a}{loc_sort} <=> $mc_subscriptions{$b}{loc_sort} } keys %mc_subscriptions;
    if (@sorted_mc_subscriptions) {
      my $mc_loc_coll = $sorted_mc_subscriptions[0];
      $mc_collection_subscriptions = (split(/\|/, $mc_loc_coll))[1];
    }
  }
  
  $update{num_subscriptions} = { set => $num_subscriptions };
  $update{num_public_subscriptions} = { set => $num_public_subscriptions };
  $update{subscriptions_libraries} = { set => \@subscriptions_libs };
  
  if ($in_house_only_items || $in_house_only_subscriptions) {
    $in_house_only = 1;
  }
  $update{in_house_only} = { set => $in_house_only };
  
  if ($mc_collection_subscriptions) {
    $mc_collection = $mc_collection_subscriptions;
  } elsif ($mc_collection_items) {
    $mc_collection = $mc_collection_items;
  }
  $update{mc_collection_d} = { set => $mc_collection };
  
  # requestable issues
  my @requestable_issues = ();
  if ($num_public_subscriptions) {
    # get the copy text for the requestable issues array
    $sth_get_issue_data->bind_param(1,$bib,SQL_INTEGER);
    my $get_issue_data = $hz_dbh->selectall_arrayref($sth_get_issue_data);
    if ($get_issue_data && (@{$get_issue_data} > 0)) {
      foreach my $row_ref (@{$get_issue_data}) {
        push(@requestable_issues,{ copy_text => $$row_ref[0] });
      }
    }
  }
  my $num_requestable_issues = @requestable_issues;
  $update{num_requestable_issues} = { set => $num_requestable_issues };
  
  # request counts
  $sth_count_requests->bind_param(1,$bib,SQL_INTEGER);
  my $get_request_count = $hz_dbh->selectall_arrayref($sth_count_requests);
  my $num_requests = $$get_request_count[0][0];
  $sth_count_suspended_requests->bind_param(1,$bib,SQL_INTEGER);
  my $get_suspended_request_count = $hz_dbh->selectall_arrayref($sth_count_suspended_requests);
  my $num_suspended_requests = $$get_suspended_request_count[0][0];
  $update{num_requests} = { set => $num_requests };
  $update{num_suspended_requests} = { set => $num_suspended_requests };
  
  # pull in authority record xrefs
  $sth_get_cat_link_xrefs->bind_param(1,$bib,SQL_INTEGER);
  my $cat_link_xrefs = $hz_dbh->selectall_arrayref($sth_get_cat_link_xrefs);
  if (@$cat_link_xrefs) {
    # establish the master xref hash to gather the xrefs - hashes so that the headings are de-duped
    my %xrefs_master = ();
    my @xref_authors = ();
    my @xref_titles = ();
    my @xref_subjects = ();
    my @xref_series = ();
    my @xref_allfields = ();
    # loop through the auth controlled tags looking for xrefs
    foreach my $actag (@$cat_link_xrefs) {
      my($bib_tag,$aid) = @$actag;
      $sth_get_solr_ready_xrefs->bind_param(1,$aid,SQL_INTEGER);
      my $solr_ready_xrefs = $hz_dbh->selectall_arrayref($sth_get_solr_ready_xrefs);
      if ($solr_ready_xrefs) {
        if (@$solr_ready_xrefs) {
          # build a hash of xref data
          my %xrefs = ();
          foreach my $xref (@$solr_ready_xrefs) {
            my($base_aid,$atag,$tord,$scope,$xref_string) = @$xref;
            my $key = $base_aid . '-' . $tord;
            $xrefs{$key}{$scope} = $xref_string;
          }
          # if the original bib tag is 6xx, shove the full form of the xref into %subjects
          if ($bib_tag =~ /^6/) {
            foreach my $k (keys(%xrefs)) {
              if (exists($xrefs{$k}{full})) {
                my $v = $xrefs{$k}{full};
                $xrefs_master{subjects}{$v}++;
              }
            }
          
          # if the original bib tag is name main entry, shove the full form of the xref into %authors
          } elsif ($bib_tag =~ /^(100|110|111)$/) {
            foreach my $k (keys(%xrefs)) {
              if (exists($xrefs{$k}{full})) {
                my $v = $xrefs{$k}{full};
                $xrefs_master{authors}{$v}++;
              }
            }
          
          # if the original bib tag is 130, 240 or 730, check for an author title split, otherwise full into %titles
          } elsif ($bib_tag =~ /^(130|240|730)$/) {
            foreach my $k (keys(%xrefs)) {
              if (exists($xrefs{$k}{author}) && exists($xrefs{$k}{title})) {
                my $a = $xrefs{$k}{author};
                $xrefs_master{authors}{$a}++;
                my $t = $xrefs{$k}{title};
                $xrefs_master{titles}{$t}++;
              } elsif (exists($xrefs{$k}{full})) {
                my $v = $xrefs{$k}{full};
                $xrefs_master{titles}{$v}++;
              }
            }
          
          # if the original bib tag is series, check for an author title split, otherwise full into %series
          } elsif ($bib_tag =~ /^(440|800|810|811|830)$/) {
            foreach my $k (keys(%xrefs)) {
              if (exists($xrefs{$k}{author}) && exists($xrefs{$k}{title})) {
                my $a = $xrefs{$k}{author};
                $xrefs_master{authors}{$a}++;
                my $s = $xrefs{$k}{title};
                $xrefs_master{series}{$s}++;
              } elsif (exists($xrefs{$k}{full})) {
                my $v = $xrefs{$k}{full};
                $xrefs_master{series}{$v}++;
              }
            }
          
          # if the original bib tag is name added entry, check for an author title split, otherwise full into %authors
          } elsif ($bib_tag =~ /^(700|710|711)$/) {
            foreach my $k (keys(%xrefs)) {
              if (exists($xrefs{$k}{author}) && exists($xrefs{$k}{title})) {
                my $a = $xrefs{$k}{author};
                $xrefs_master{authors}{$a}++;
                my $t = $xrefs{$k}{title};
                $xrefs_master{titles}{$t}++;
              } elsif (exists($xrefs{$k}{full})) {
                my $v = $xrefs{$k}{full};
                $xrefs_master{authors}{$v}++;
              }
            }
          }
        }
      }
    }
    
    # add the xrefs to the update
    # add to defaultsearchfield, the boosting index, and the scoping index
    foreach my $cat (keys(%xrefs_master)) {
      my @xref_array = keys(%{$xrefs_master{$cat}});
      my @xref_array_utf8 = ();
      foreach my $xref (@xref_array) {
        my $converted = marc8_to_utf8($xref);
        if ($converted) {
          push(@xref_array_utf8,removeTrailingPunct($converted));
        }
      }
      push(@xref_allfields, @xref_array_utf8);
      if ($cat eq 'authors') {
        push(@xref_authors, @xref_array_utf8);
      } elsif ($cat eq 'titles') {
        push(@xref_titles, @xref_array_utf8);
      } elsif ($cat eq 'subjects') {
        push(@xref_subjects, @xref_array_utf8);
      } elsif ($cat eq 'series') {
        push(@xref_series, @xref_array_utf8);
      }
    }
    # dedup allfields
    my %allfields = ();
    foreach my $xref (@xref_allfields) {
      $allfields{$xref}++;
    }
    my @xref_allfields_deduped = keys(%allfields);
    $update{allfields} = { add => \@xref_allfields_deduped };
    if (@xref_authors) {
      $update{addl_author} = { add => \@xref_authors };
      $update{author} = { add => \@xref_authors };
    }
    if (@xref_titles) {
      $update{addl_title} = { add => \@xref_titles };
      $update{title} = { add => \@xref_titles };
    }
    if (@xref_subjects) {
      $update{subject_xrefs} = { add => \@xref_subjects };
      $update{subject} = { add => \@xref_subjects };
    }
    if (@xref_series) {
      $update{series_title} = { add => \@xref_series };
      $update{series} = { add => \@xref_series };
    }
  }
  
  # popularity boost
  # copies and requests added together (max value is capped at 90)
  $sth_popularity_boost->bind_param(1,$bib,SQL_INTEGER);
  my $pop_boost = $hz_dbh->selectall_arrayref($sth_popularity_boost);
  my($pb_n_copies, $pb_n_subscriptions, $pb_n_requests) = (0,0,0);
  if (@{$pop_boost}) {
    foreach my $pb (@$pop_boost) {
      ($pb_n_copies, $pb_n_subscriptions, $pb_n_requests) = @$pb;
      last;
    }
    my $popularity_boost = $pb_n_copies + $pb_n_requests;
    if ($pb_n_subscriptions) {
      $popularity_boost = $pb_n_subscriptions + $pb_n_requests;
    }
    if ($popularity_boost == 0) {
      #check the overdrive availability table
      my $check_oda = $hz_dbh->selectall_arrayref($sth_od_availability,undef,($bib));
      if (@{$check_oda}) {
        $popularity_boost = $$check_oda[0][2] + $$check_oda[0][3];
      }
    }
    $update{popularity_boost} = { set => $popularity_boost };
  }
  
  # predominant_collection_d
  $sth_collection->bind_param(1,$bib,SQL_INTEGER);
  my $collection = $hz_dbh->selectall_arrayref($sth_collection);
  if (@{$collection}) {
    $update{predominant_collection_d} = { set => $$collection[0][1] };
  }

  # primary_language
  # first try to pull from collection code
  # failing that, attempt to get it from the 008
  my $lang;
  my $language;
  if (@{$collection}) {
    my $c1 = substr($$collection[0][0],0,1);
    if ($c1 eq 'a' ||
        $c1 eq 't' ||
        $c1 eq 'c' ||
        $c1 eq 'e') {
          # map collection language to MARC code
          my $c7 = substr($$collection[0][0],6,1);
          $lang = 'amh' if $c7 eq 'e'; # Amharic
          $lang = 'ara' if $c7 eq 'a'; # Arabic
          $lang = 'cam' if $c7 eq 'k'; # Cambodian - custom hcl code (MARC codes say to use Khmer [khm])
          $lang = 'chi' if $c7 eq 'c'; # Chinese
          $lang = 'fre' if $c7 eq 'f'; # French
          $lang = 'ger' if $c7 eq 'g'; # German
          $lang = 'hin' if $c7 eq 'd'; # Hindi
          $lang = 'hmn' if $c7 eq 'h'; # Hmong
          $lang = 'jpn' if $c7 eq 'j'; # Japanese
          $lang = 'kor' if $c7 eq 'n'; # Korean
          $lang = 'lao' if $c7 eq 'l'; # Lao
          $lang = 'orm' if $c7 eq 'o'; # Oromo
          $lang = 'rus' if $c7 eq 'r'; # Russian
          $lang = 'som' if $c7 eq 'm'; # Somali
          $lang = 'spa' if $c7 eq 's'; # Spanish
          $lang = 'tha' if $c7 eq 't'; # Thai
          $lang = 'vie' if $c7 eq 'v'; # Vietnamese
    }
  }
  eval { $lang = $lang?$lang:substr($marc->field('008')->data,35,3) };
  if ($lang) {
    $language = $language_map->getProperty($lang);
  }
  if ($language && $language ne 'null') {
    $update{primary_language} = { set => $language };
  }
  
  # get predominant_call_number_d
  $sth_item_call->bind_param(1,$bib,SQL_INTEGER);
  my $item_call = $hz_dbh->selectall_arrayref($sth_item_call);
  if (@{$item_call}) {
    $update{predominant_call_number_d} = { set => $$item_call[0][0] };
  }
  
  # numbers (add barcodes)
  $sth_ibarcodes->bind_param(1,$bib,SQL_INTEGER);
  my $ibarcodes = $hz_dbh->selectall_arrayref($sth_ibarcodes);
  foreach my $i (@{$ibarcodes}) {
    if ($update{numbers}{add}) {
      push(@{$update{numbers}{add}},$$i[0]);
    } else {
      $update{numbers} = { add => [$$i[0]] };
    }
  }
  
  # author_sort
  $sth_author_sort->bind_param(1,$bib,SQL_INTEGER);
  my $author_sort = $hz_dbh->selectall_arrayref($sth_author_sort);
  if (@{$author_sort}) {
    $update{author_sort} = { set => lc($$author_sort[0][0]) };
  }

  # title_sort
  $sth_title_sort->bind_param(1,$bib,SQL_INTEGER);
  my $title_sort = $hz_dbh->selectall_arrayref($sth_title_sort);
  if (@{$title_sort}) {
    $update{title_sort} = { set => lc($$title_sort[0][0]) };
  }
  
  # public_f
  $sth_public->bind_param(1,$bib,SQL_INTEGER);
  my $public = $hz_dbh->selectall_arrayref($sth_public);
  if (@{$public}) {
    my $public_f = $public_map->getProperty($$public[0][0]);
    if ($public_f && $public_f ne 'null') {
      $update{public_f} = { set => $public_f };
    }
  }
  
  # format_icon, format_f
  if (@{$collection}) {
    my $c1 = substr($$collection[0][0],0,1);
    if ($c1 eq 'a' ||
        $c1 eq 't' ||
        $c1 eq 'c' ||
        $c1 eq 'e') {
      # determine the icon code from the collection code
      my $format_chars = substr($$collection[0][0],1,2);
      my $c4 = substr($$collection[0][0],3,1);
      my ($code,$descr);
      $code = 'GD' if $c4 eq 'g'; # Government Document
      $code = 'AT' if ($format_chars eq 'aa' && ($c4 eq 'f' || $c4 eq 'n')); # Audiobook on Tape
      $code = 'ATM' if ($format_chars eq 'aa' && $c4 eq 'm'); # Music on Tape
      $code = 'BK' if ($format_chars eq 'cb' || $format_chars eq 'cc' || $format_chars eq 'cs' || $format_chars eq 'pb' || $format_chars eq 'pd' || $format_chars eq 'pg'); # Book
      $code = 'BR' if $format_chars eq 'br'; # Braille
      $code = 'CD' if ($format_chars eq 'ac' && ($c4 eq 'f' || $c4 eq 'n')); # Audiobook on CD
      $code = 'CDM' if ($format_chars eq 'ac' && $c4 eq 'm'); # Music on CD
      $code = 'CDR' if $format_chars eq 'ec'; # CD-ROM
      $code = 'DVD' if $format_chars eq 'vd'; # DVD
      $code = 'LP' if $format_chars eq 'pl'; # Large Print
      $code = 'MA' if $format_chars eq 'cd' || $format_chars eq 'cp'; # Magazine
      $code = 'MAP' if $format_chars eq 'pm'; # Map
      $code = 'MF' if $format_chars eq 'cf' || $format_chars eq 'ci' || $format_chars eq 'ff' || $format_chars eq 'fi'; # Microform
      $code = 'MM' if $format_chars eq 'm-'; # Mixed Media
      $code = 'MU' if $format_chars eq 'ph' || $format_chars eq 'ps'; # Printed Music
      $code = 'NP' if $format_chars eq 'cn'; # Newspaper
      $code = 'VHS' if $format_chars eq 'vv'; # VHS
      if ($code) {
        $update{format_icon} = { set => $code };
        $descr = $format_map->getProperty($code);
        if ($descr && $descr ne 'null') {
          $update{format_f} = { set => $descr };
        }
      }
    }
  }
  
  # audience_f
  if (@{$collection}) {
    my $audience;
    my $c1 = substr($$collection[0][0],0,1);
    $audience = 'Adult' if $c1 eq 'a';
    $audience = 'Teen' if $c1 eq 't';
    $audience = "Children's" if $c1 eq 'c';
    $audience = 'Easy' if $c1 eq 'e';
    if ($audience) {
      $update{audience_f} = { set => $audience };
    }
  }
  
  # litform_f
  if (@{$collection}) {
    my $litform;
    if ($$collection[0][0] eq 'apbr---') {
      $litform = 'Nonfiction'; # Adult New Reader
    } else {
      my $c1 = substr($$collection[0][0],0,1);
      if ($c1 eq 'a' ||
          $c1 eq 't' ||
          $c1 eq 'c' ||
          $c1 eq 'e') {
        # determine the literary form from the collection code
        my $c4 = substr($$collection[0][0],3,1);
        $litform = "Nonfiction" if $c4 eq 'n';
        $litform = "Fiction" if $c4 eq 'f';
        $litform = "Fiction" if $c4 eq 'r'; # Easy Reader
      }
    }
    if ($litform) {
      $update{litform_f} = { set => $litform };
    }
  }

  # availability_f, availability_ref_f
  # no ref availability
  $sth_available->bind_param(1,$bib,SQL_INTEGER);
  my $available = $hz_dbh->selectall_arrayref($sth_available);
  my @available;
  foreach my $i (@{$available}) {
    push(@available,$$i[0]);
  }
  # availability including ref
  $sth_available_ref->bind_param(1,$bib,SQL_INTEGER);
  my $available_ref = $hz_dbh->selectall_arrayref($sth_available_ref);
  my @available_ref;
  foreach my $i (@{$available_ref}) {
    push(@available_ref,$$i[0]);
  }
  # online availability
  my $available_online = 0;
  my $t960 = $marc->field('960');
  my $t960a;
  if ($t960) {
    $t960a = $t960->subfield('a');
    if ($t960a) {
      if ($t960a eq 'ogr' || $t960a eq 'ebook' || $t960a eq 'ejournal') {
        $available_online = 1;
      }
    }
  }
  # Overdrive
  if ($overdrive && $overdrive eq 'true') {
    my $odid;
#    # first look in the 037 - no don't (8/19/2014 pf) because 3m records have 037s with ODIDs
#    my @t037s = $marc->field('037');
#    foreach my $t037 (@t037s) {
#      if ($t037->subfield('a')) {
#        if ($t037->subfield('a') =~ /([0-9A-Za-z]{8}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{12})/) {
#          $odid = $1;
#        }
#      }
#    }
#    if (!$odid) {
#      # if nothing in the 037, check the 856
    # check the 856
    my @t856s = $marc->field('856');
    foreach my $t856 (@t856s) {
      if ($t856->subfield('u')) {
        if ($t856->subfield('u') =~ /econtent\.hclib\.org/) {
          if ($t856->subfield('u') =~ /ID=([0-9A-Za-z]{8}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{12})/i) {
            $odid = $1;
          }
        }
      }
    }
#    }
    if ($odid) {
      my $check_oda = $hz_dbh->selectall_arrayref($sth_od_availability,undef,($bib));
      if (@{$check_oda}) {
        if ($$check_oda[0][0] eq $odid) {
          $available_online = $$check_oda[0][1];
        } else {
          $sth_od_update_odid->execute($odid,$bib);
          $available_online = 1;
        }
      } else {
        $sth_od_insert->execute($bib,$odid);
        $available_online = 1;
      }
    }
  }
  if ($available_online) {
    push(@available,'online');
    push(@available_ref,'online');
  }
  # available "Anywhere"
  push(@available,'xx') if @available;
  push(@available_ref,'xx') if @available_ref;
  # property map
  my @available_f;
  foreach my $i (@available) {
    my $availability_f = $availability_map->getProperty($i);
    if ($availability_f && $availability_f ne 'null') {
      push(@available_f,$availability_f);
    }
  }
  my @available_ref_f;
  foreach my $i (@available_ref) {
    my $availability_ref_f = $availability_map->getProperty($i);
    if ($availability_ref_f && $availability_ref_f ne 'null') {
      push(@available_ref_f,$availability_ref_f);
    }
  }
  if (@available_f) {
    $update{availability_f} = { set => \@available_f };
  }
  if (@available_ref_f) {
    $update{availability_ref_f} = { set => \@available_ref_f };
  }
  
  # circulating_f
#  my $circ = 'false';
#  $sth_circ_count->bind_param(1,$bib,SQL_INTEGER);
#  my $circ_count = $hz_dbh->selectall_arrayref($sth_circ_count);
#  if (@{$circ_count} && $$circ_count[0][0]) {
#    $circ = 'true';
#  } else {
#    # check for online copies
#    if ($t960 && $t960a) {
#      if ($t960a eq "ogr" ||
#          $t960a eq "dlbk" ||
#          $t960a eq "dlab" ||
#          $t960a eq "dlv" ||
#          $t960a eq "dlm" ||
#          $t960a eq "ebook" ||
#          $t960a eq "ejournal") {
#        $circ = 'true';
#      }
#    }
#  }
#  my $circulating_f = $circulating_map->getProperty($circ);
#  if ($circulating_f && $circulating_f ne 'null') {
#    $update{circulating_f} = { set => $circ };
#  }
  
  # location_f
  $sth_locations->bind_param(1,$bib,SQL_INTEGER);
  my $locations = $hz_dbh->selectall_arrayref($sth_locations);
  my @location;
  foreach my $i (@{$locations}) {
    my $location_f = $location_map->getProperty($$i[0]);
    if ($location_f && $location_f ne 'null') {
      push(@location,$location_f);
    }
  }
  if (@location) {
    $update{location_f} = { set => \@location };
  }
  
  # special_collection_f
  $sth_special_collections->bind_param(1,$bib,SQL_INTEGER);
  my $special_collections = $hz_dbh->selectall_arrayref($sth_special_collections);
  my @special_collection;
  foreach my $i (@{$special_collections}) {
    my $special_collection_f = $special_collection_map->getProperty($$i[0]);
    if ($special_collection_f && $special_collection_f ne 'null') {
      push(@special_collection,$special_collection_f);
    }
  }
  if (@special_collection) {
    $update{special_collection_f} = { set => \@special_collection };
  }
  
  # Syndetics
  if ($syndetics && $syndetics eq 'true') {
    my $index_xml;
  
    # build the de-duped lists of UPCs and ISBNs
    my @upc;
    my @upc_f = $marc->field('024');
    foreach my $upc_f (@upc_f) {
      if (($upc_f->indicator(1) eq '1') && ($upc_f->subfield('a')) && ($upc_f->subfield('a') =~ /^([0-9]{6,}).*/)) {
        my $upc_new = $1;
        my $dup;
        foreach my $upc (@upc) {
          if ($upc eq $upc_new) {
            $dup = 1;
            last;
          }
        }
        push(@upc,$upc_new) unless $dup;
      }
    }
    my @isbn;
    my @isbn_f = $marc->field('020');
    foreach my $isbn_f (@isbn_f) {
      if (($isbn_f->subfield('a')) && ($isbn_f->subfield('a') =~ /^([0-9Xx]{10,13}).*/)) {
        my $business_isbn;
        # Business::ISBN is crabby about bad ISBNs, wrap calls in eval to avoid dying
        eval { $business_isbn = Business::ISBN->new($1) };
        if ($business_isbn) {
          eval { $business_isbn = $business_isbn->as_isbn13 };
          my $isbn_new;
          eval { $isbn_new = $business_isbn->as_string([]) };
          if ($isbn_new) {
            my $dup;
            foreach my $isbn (@isbn) {
              if ($isbn eq $isbn_new) {
                $dup = 1;
                last;
              }
            }
            push(@isbn,$isbn_new) unless $dup;
          }
        }
      }
    }

    if (@upc || @isbn) {
      # first check the db cache
      my $sql_string = "select upc, isbn, xml from index_xml where ";
      if (@upc) {
        my $upc_in;
        foreach my $upc (@upc) {
          if ($upc_in) {
            $upc_in .= ',' . $syndetics_dbh->quote($upc);
          } else {
            $upc_in = '(' . $syndetics_dbh->quote($upc);
          }
        }
        $upc_in .= ')';
        $sql_string .= "upc in $upc_in";
        if (@isbn) {
          $sql_string .= " or ";
        }
      }
      if (@isbn) {
        my $isbn_in;
        foreach my $isbn (@isbn) {
          if ($isbn_in) {
            $isbn_in .= ',' . $syndetics_dbh->quote($isbn);
          } else {
            $isbn_in = '(' . $syndetics_dbh->quote($isbn);
          }
        }
        $isbn_in .= ')';
        $sql_string .= "isbn in $isbn_in";
      }
      my $xml_ref;
      eval { $xml_ref = $syndetics_dbh->selectall_arrayref($sql_string) };
      if ($@) {
        warn "Error checking db for bib# $bib: $@ ($DBI::errstr\n";
      }
      if ($xml_ref && (@{$xml_ref} > 0)) {
        foreach my $upc (@upc) {
          foreach my $row_ref (@{$xml_ref}) {
            if ($$row_ref[0] && ($$row_ref[0] eq $upc)) {
              $index_xml = $$row_ref[2];
              last;
            }
            last if $index_xml;
          }
          last if $index_xml;
        }
        unless ($index_xml) {
          foreach my $isbn (@isbn) {
            foreach my $row_ref (@{$xml_ref}) {
              if ($$row_ref[1] && ($$row_ref[1] eq $isbn)) {
                $index_xml = $$row_ref[2];
                last;
              }
              last if $index_xml;
            }
            last if $index_xml;
          }
        }
      } else {
        # index is not in db cache
        # query the web service
        # TODO: refactor using HTTP::Async
        my $syndetics_search = '';
        if (@upc) {
          $syndetics_search .= '&upc=';
          my $upc_list;
          foreach my $upc (@upc) {
            if ($upc_list) {
              $upc_list .= ",$upc";
            } else {
              $upc_list = $upc;
            }
          }
          $syndetics_search .= $upc_list;
        }
        if (@isbn) {
          $syndetics_search .= '&isbn=';
          my $isbn_list;
          foreach my $isbn (@isbn) {
            if ($isbn_list) {
              $isbn_list .= ",$isbn";
            } else {
              $isbn_list = $isbn;
            }
          }
          $syndetics_search .= $isbn_list;
        }
        $syndetics_search .= '/INDEX.XML';
        my $ua = LWP::UserAgent->new;
        my $request = HTTP::Request->new( GET => $syndetics_source . $syndetics_search );
        my $response = $ua->request($request);
        if ($response->is_success) {
          $index_xml = $response->content;
        } else {
          warn "Error getting Syndetics data for bib# $bib: " . $response->status_line . "\n";
        }
      }
    }
      
    # look for summary data
    my $summary_xml;
    if ($index_xml) {
      my $index_ref =  eval { XMLin($index_xml) };
      unless ($@) { # index.xml is valid xml
        my ($key,$key_type);
        if ($$index_ref{UPC}) {
          $key_type = 'upc';
          $key = $syndetics_dbh->quote($$index_ref{UPC});
        } elsif ($$index_ref{ISBN}) {
          $key_type = 'isbn';
          $key = $syndetics_dbh->quote($$index_ref{ISBN});
        }
        if ($key && $key_type) {   
          if ($$index_ref{SUMMARY}) {
            my $summary_ref = eval { $syndetics_dbh->selectall_arrayref("select xml from summary_xml where $key_type = $key") };
            if ($summary_ref && @{$summary_ref} && $$summary_ref[0][0]) {
              $summary_xml = $$summary_ref[0][0];
            }
          } elsif ($$index_ref{AVSUMMARY}) {
            my $summary_ref = eval { $syndetics_dbh->selectall_arrayref("select xml from avsummary_xml where $key_type = $key") };
            if ($summary_ref && @{$summary_ref} && $$summary_ref[0][0]) {
              $summary_xml = $$summary_ref[0][0];
            }
          }
        }
      }
    }
    if ($index_xml) {
      $update{syndetics_index_xml} = { set => $index_xml };
    } else {
      $update{syndetics_index_xml} = { set => '<?xml version="1.0" encoding="utf-8"?><INDEX-ROOT></INDEX-ROOT>' };
    }
    if ($summary_xml) {
      $update{syndetics_summary_xml} = { set => $summary_xml };
    }
  }
  
  $record_index++;
  push(@solr_batch,\%update);
  print "Updating record $record_index from $marc_file: $bib\n";

  # post update to Solr in batches of 5000
  if (@solr_batch == 5000) {
    if (solr_post(\@solr_batch)) {
      $post_count += 5000;
      print "Updated $post_count records in index.\n";
      @solr_batch = ();
    } else {
      die "Error posting update to SOLR\n";
    }
  }
}

# post remainder of updates
if (@solr_batch) {
  if (solr_post(\@solr_batch)) {
    $post_count += @solr_batch;
      print "Updated $post_count records in index.\n";
  } else {
    die "Error posting update to SOLR\n";
  }
}

print "Processed $record_index records, posted $post_count in " . tv_interval($start,[gettimeofday]) . " seconds.\n";

exit;

sub solr_post {
  # post to solr
  my $batch_ref = shift;
  my $ua = LWP::UserAgent->new;
  my $request = HTTP::Request->new( POST => "$solr_path/update" );
  $request->content_type('application/json');
  $request->content(encode_json($batch_ref));
  my $response = $ua->request($request);
  unless ($response->is_success) {
    warn "Error posting solr update: " . $response->status_line . "\n";
    return undef;
  }
        
  # commit changes
  $request = HTTP::Request->new( GET => "$solr_path/update?commit=true" );
  $response = $ua->request($request);
  unless ($response->is_success) {
    warn "Error committing solr update: " . $response->status_line . "\n";
    return undef;
  }
  1;
}

# mimic the behavior of solrmarc's removeTrailingPunct function
sub removeTrailingPunct {
  my $string = shift;
  my $finished = 0;
  while (!$finished) {
    if ($string =~ /\ $/) {
      $string =~ s/\ {1,}$//;
    } elsif ($string =~ /\,$/) {
      $string =~ s/\,$//;
    } elsif ($string =~ /\/$/) {
      $string =~ s/\/$//;
    } elsif ($string =~ /\;$/) {
      $string =~ s/\;$//;
    } elsif ($string =~ /\:$/) {
      $string =~ s/\:$//;
    } elsif ($string =~ /[a-zA-z]{3,}\.$/) {
      $string =~ s/\.$//;
    } elsif ($string =~ /^\]/) {
      $string =~ s/^\]//;
    } elsif ($string =~ /^\[/) {
      $string =~ s/^\[//;
    } elsif ($string =~ /\]$/) {
      $string =~ s/\]$//;
    } elsif ($string =~ /\[$/) {
      $string =~ s/\[$//;
    } else {
      $finished = 1;
    }
  }
  return $string;
}