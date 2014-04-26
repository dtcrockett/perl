#!/usr/bin/perl

# Portions copyright (c) 2014, D Crockettt    https://github.com/dtcrockett 
#
# Portions copyright (c) 2013, Cathal Garvey. http://cgarvey.ie/
#  (see https://github.com/cgarvey/no-ip-ddns-update version 1.04)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
######


# This script will update a no-ip.com dynamic DNS account
# using the credentials specified in the config file
#
# An optional IP address can be specified, without which
# the script will determine your WAN IP address
#
# Call script with no arguments to see usage help, and
# supported arguments.
#
#######################################################################
# this script is based heavily on: 
# https://github.com/cgarvey/no-ip-ddns-update version 1.04
#
# The communication with no-ip is very little changed from cgarvey
# although is is broken into more subroutines
#
# changes:
# - broke code up into many short subroutines
# - dropped the IP address from the config file. I don't care what 
#   IP address is stored locally, I only care if the actual wan address 
#   is different from the address stored at no-ip. 
# - added commands: resolve, check, what
# dc,26-apr-2014
#
#
# NOTHING TO CHANGE HERE! - create the config file, and update it
#########################################################################

use strict;
use warnings;

$| = 1;

use LWP::UserAgent;
use HTTP::Request::Common;
use POSIX 'strftime';
use URI::Escape;
use File::Spec;
use Socket;
use feature "switch";

my $VERSION = "1.00";
my $verbosity = 2; # standard verbosity to print all response status, and errors
my $gotIpFromInternet = 0;
my $myName = $0;

my( $agent ) = new LWP::UserAgent;
$agent->agent( "No-ip.com updater script; Version " . $VERSION );

my( $path_vol, $path_dir, $path_script ) = File::Spec->splitpath(__FILE__);
my( $path_conf ) = $path_dir . "no-ip-ddns-update.conf";

my( $username, $password, $hostname );
my( $dummy_ip );

# Check for command args
if( not $#ARGV >= 0 ) {
   print usage(); # print in all verbsoities
   exit( 0 );
}

for ( $ARGV[0] ) {
    when (/^help/)   { print usage();        exit(0); }
    when (/^create/) { createConfig();       exit(0); }
    when (/^what/)   { whatIsMyIpAddress();  exit(0); }
}

readConfig();
checkConfig();

# Check for IP on command line (2nd arg), if not specified here will be guessed from the 'internet'
my $cmdLineIp = undef;
if( $#ARGV == 1 ) {
    $cmdLineIp = validateCommandLineIp( $ARGV[1] );
}

for ( $ARGV[0] ) {
    when (/^resolve/) { resolve($hostname, 1); }
    when (/^update/)  { getIpIfNecessaryAndUpdateNoIp( $cmdLineIp ); }
    when (/^force/)   { forceNoIpUpdate( $cmdLineIp, $hostname, 10 ); }
    when (/^check/)   { updateNoIpIfIpAddressHasChanged(); }
    default           { writeLog( 1, 1, "ERROR: Unsupported argument.\n\n" . usage() ); };
}

exit( 0 );

##############################################################################################################
# can't trust those pesky users to properly enter an IP address
sub validateCommandLineIp {
    my ($localIp) = @_;
    if( is_valid_ip( $localIp ) ) {
        return $localIp;
    } else {
        writeLog( 0, 0, "ERROR: Invalid format in IP address speciifed on command line.\n"
        . "Use xxx.xxx.xxx.xxx notation (e.g. 192.168.1.1)\n"
        . "Real IP used.\n\n"
        );
        return undef;
    }
}

##############################################################################################################
sub usage {
   my $s  = "\n"
    . "Usage: $0 <command> (<ip address>)\n"
    . "\n"
    . "  <command> is required, and one of:\n"
    . "    create  - Creates an initial sample configuration file with supporting\n"
    . "                comments.\n\n"
    . "    check   - Updates the No-IP account with IP address from internet only if \n"
    . "                it is different from current IP address.\n\n"
         . "    what    - what is my ip address\n\n"
         . "    resolve - what is the ip address as known by NO-IP\n\n"
    . "    update  - Updates the No-IP account with IP address from command line\n"
    . "                or configuration file (cmd line takes precedence).\n\n"
    . "    force   - Issues two updates to No-IP (to force it to recognise a\n"
    . "                change. First with dummy IP from config file. Second with\n"
    . "                real IP from command line, or guessed.\n\n"
    . "\n"
    . "  <ip address> is optional, and is the IP address to update the No-IP domain\n"
    . "               with. If not specified the ip address will be guessed\n"
    . "\n\n";
   return $s;
}

##############################################################################################################
# Depending on the verbosity configured, print the specified message, and optionally die
# Arg 1: The minimum versbosity required (i.e. if 2, then only verbsoities of 2 or 3 will
#        cause a message to be printed)
# Arg 2: Whether or not to die. If 1, the script will die (with provided message if verbsoity
#        is appropriate), if 0, the msg will be printed, without dying.
# Arg 3: The message, if any, to print

sub writeLog {
   my( $level, $do_die, $msg ) = @_;
    
   if( $level <= $verbosity and $msg ) {
      die( $msg ) if $do_die > 0;
      print $msg;
   } else {
      exit( 2555 ) if $do_die > 0;
   }
}

##############################################################################################################
sub is_valid_ip {
   my( $test_ip ) = @_;

   return 0 unless defined( $test_ip );
   return 0 unless $test_ip;

   my( @matches ) = $test_ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
   return 0 unless $#matches == 3;

   foreach( @matches ) {
      return 0 unless ($_ >= 0 and $_ <= 255);
      #return unless ($_ >= 0 && $_ <= 255 && $_ !~ /^0\d{1,2}$/);
   }

   return 1;
}

##############################################################################################################
sub createConfig {
    writeLog( 0, 1, "WARNING: Config file already exists ($path_conf).\n"
    . "You must remove the file yourself.\n\n" ) if -r $path_conf;
    
    writeConfig();
    writeLog( 0, 0, "Configuration file created ($path_conf). Please update it\nto suit your needs.\n\n" );
}

##############################################################################################################
sub writeConfig {
    my( $hostname, $username, $password, $ip, $dummy_ip, $verbosity ) = @_;
    
    open( CONF, ">" . $path_conf )
    or writeLog( 0, 1, "ERROR: Failed to write conf file ($path_conf). Are folder permissions OK?\n\n" );
    
    print CONF "# Configuration file for $myName. Created " . strftime( '%y%m%d-%H%M%S', localtime ) . ".\n";
    print CONF "# Update the parameters below to match your No-IP.com account credentials.\n\n";
    print CONF "# Lines starting with # are comments, and are ignored.\n\n";
    print CONF "# HOSTNAME is required, and is the hostname you chose in your No-ip.com\n";
    print CONF "# control panel. E.g. mydomain.no-ip.org.\n";
    if ($hostname) { print CONF "HOSTNAME=${hostname}\n\n"; }
    else           { print CONF "HOSTNAME=myddns.test.noip.com\n\n"; }
    
    print CONF "# USERNAME is required, and is your email address that you used to register\n";
    print CONF "# on No-ip.com (and the one you writeLogin with).\n";
    if ( $username ) { print CONF "USERNAME=${username}\n\n"; }
    else             { print CONF "USERNAME=myemailaddress\@some.domain\n\n"; }
    
    print CONF "# PASSWORD is required, and is the one you use to writeLogin to No-ip.com.\n";
    if ( $password ) { print CONF "PASSWORD=${password}\n\n"; }
    else             { print CONF "PASSWORD=my_secret_password\n\n"; }
    
    print CONF "# DUMMY_IP is optional. If it's specified, and the corresponding\n";
    print CONF "# 'updateforce' command line argument is used, this address will be used to\n";
    print CONF "# update the No-ip.com account, before the real IP address is used in a\n";
    print CONF "# subsequent update. This is to force No-ip.com to see a change in IP address\n";
    print CONF "# (for ISPs who provide a long-term IP address lease). Some non-routable IP\n";
    print CONF "# address is recommended, like 127.0.0.1. Use standard IPv4 dotted notation.\n";
    if ( $dummy_ip ) { print CONF "DUMMY_IP=${dummy_ip}\n\n"; }
    else             { print CONF "#DUMMY_IP=127.0.0.1\n\n";  }
    
    print CONF "# VERBOSITY is optional, and controls what is output by the script. Supported values are:\n";
    print CONF "#  0 - Output nothing at all\n";
    print CONF "#  1 - Output only fatal errors; (configuration errors, but not services errors\n";
    print CONF "#      such as No-IP reporting failure to update IP. Recommended for Cron jobs.\n";
    print CONF "#  2 - Output all errors, and indication of success/failure in updating IP. This\n";
    print CONF "#      is the assumed default (if not configured here).\n";
    if ( $verbosity ) { print CONF "VERBOSITY=${verbosity}\n\n"; }
    else              { print CONF "#VERBOSITY=2\n\n";           }
    
    close( CONF );
}


##############################################################################################################
sub readConfig {
    # Read config file
    open( CONF, $path_conf )
    or writeLog( 1, 1, "ERROR: Could not open the configuration file ($path_conf\n"
                . "in the current directory).\n"
                . " Run \"$myName createconfig\" to create a sample\n"
                . "conf file for you to change.\n\n" );
    
    while( my $line = <CONF> )
    {
        $line =~ s/[\r\n]//;
        for ( $line )
        {
            when ( /^USERNAME=(.*)/ )  { validateUsername ( $1 ) };
            when ( /^PASSWORD=(.*)/ )  { validatePassword ( $1 ) };
            when ( /^HOSTNAME=(.*)/ )  { validateHostname ( $1 ) };
            when ( /^DUMMY_IP=(.*)/ )  { validateDummyIp  ( $1 ) };
            when ( /^VERBOSITY=(.*)/ ) { validateVerbosity( $1 ) };
        }
    }
    close( CONF );
}

##############################################################################################################
sub validateUsername {
    ( $username ) = @_;

    if( !$username ) {
        writeLog( 1, 1, "ERROR: 'USERNAME' can not be empty, in the configuration file.\n\n" );
    } elsif( $username !~ /.*\@.*/ ) {
        writeLog( 1, 1, "ERROR: 'USERNAME' does not appear to be a valid email address.\n\n" );
    }

    writeLog( 2, 0, "read username: $username\n" );
}

##############################################################################################################
sub validatePassword {
    ( $password ) = @_;

    if( !$password ) {
        writeLog( 1, 1, "ERROR: 'PASSWORD' can not be empty, in the configuration file.\n\n" );
    }

    # don't show the password, even though it is stored in clear text in the config file
    #            writeLog( 0, 0, "read password: $password\n" );
    writeLog( 2, 0, "read password: ---\n" );
}

##############################################################################################################
sub validateHostname {
    ( $hostname ) = @_;

    if( !$hostname ) {
        writeLog( 1, 1, "ERROR: 'HOSTNAME' can not be empty, in the configuration file.\n\n" );
    }

    writeLog( 2, 0, "read hostname: $hostname\n" );
}

##############################################################################################################
sub validateDummyIp {
   ( $dummy_ip ) = @_;

    if( !$dummy_ip ) {
        writeLog( 1, 1, "ERROR: 'DUMMY_IP' can not be empty, in the configuration file.\n"
        . "Either use a valid IP address, or comment out to use the default.\n\n" );
    } elsif( ! is_valid_ip( $dummy_ip ) ) {
        writeLog( 1, 1, "ERROR: 'DUMMY_IP' does not appear to be a valid format (e.g. 192.168.1.1)\n\n" );
    }

    writeLog( 2, 0, "read dummy: $dummy_ip\n" );
}

##############################################################################################################
sub validateVerbosity {
    ( $verbosity ) = @_;

    if( !$verbosity ) {
        $verbosity = 2;
        writeLog( 1, 1, "ERROR: 'VERBOSITY' can not be empty, in the configuration file.\n"
        . "Either use a valid value, or comment out to use default.\n\n" );
    }
    
    $verbosity = ( 0 + $verbosity );
    if( $verbosity < 0 or $verbosity > 2 ) {
        $verbosity = 2;
        writeLog( 1, 1, "ERROR: Unsupported 'VERBOSITY' config. It needs to be 0, 1, or 2.\n\n" );
    }

    writeLog( 2, 0, "read verbosity: $verbosity\n" );
}

##############################################################################################################
# Here we check we have required config params, 
# the parms are assumed to be validated when they are read in
#
sub checkConfig {

    if( !$username ) {
        writeLog( 1, 1, "ERROR: 'USERNAME' was not configured in the configuration file.\n\n" );
    }

    if( !$password ) {
        writeLog( 1, 1, "ERROR: 'PASSWORD' was not configured in the configuration file.\n\n" );
    }

    if( !$hostname ) {
        writeLog( 1, 1, "ERROR: 'HOSTNAME' was not configured in the configuration file.\n\n" );
    }
}

##############################################################################################################
# get our current wan IP address from the all-knowing 'internet'
#
sub getIpFromInternet {
    my $req = new HTTP::Request( "GET",  "http://ip1.dynupdate.no-ip.com/" );
    my $resp = $agent->request( $req );
    
    if( $resp->code == 200 and is_valid_ip( $resp->content ) )
    {
        writeLog( 0,0, "The internet says our external IP address is: " . $resp->content . "\n" );
        return $resp->content;
    }
    writeLog( 0,0, "the internet says our external IP address is: unknown\n\n" );
    return undef;
}

##############################################################################################################
# update no-ip with an IP address
#
# the IP address is assumed to be valid
#
sub updateNoIp {
   my( $update_ip ) = @_;
    
   # Build up HTTP request args
   my $url = "http://dynupdate.no-ip.com/nic/update";

   # here is the IP address for https connection, TODO - update conversation to allow https connection 
   # my $httpsUrl = "https://dynupdate.no-ip.com/nic/update";
    
   $url .= "?myip=" . uri_escape( $update_ip );
   $url .= "&hostname=" . uri_escape( $hostname );
    
   my $req = new HTTP::Request( "GET", $url );
   $req->authorization_basic( $username, $password );
   my $resp = $agent->request( $req );
    
   if( $resp->code == 200 ) {

      if( $resp->content =~ /^(good|nochg) $update_ip/ ) {
         return "OK: $1 $update_ip. (" . $resp->content . ")";

      } elsif( $resp->content =~ /^nochg$/ ) {
         return "FAIL: (nochg) Probaly throttled for too many updates. (" . $resp->content . ")";

      } else {
         return "FAIL: Unsupported response. (" . $resp->content . ")";
      }
   } else {
      return "FAIL: (" . $resp->code . ") Bad HTTP response from No-IP.com";
   }
}


##############################################################################################################
sub getIpIfNecessaryAndUpdateNoIp {
    my ( $ip ) = @_;
    $ip = getIpFromInternet() if not defined $ip;
    
    writeLog( 2, 0, "Update DNS: " );
    my $ret = updateNoIp( $ip );
    
    writeLog( 2, $ret =~ /^OK/ ? 0 : 1, $ret . "\n" );
}

##############################################################################################################
# force the IP address to update
#
# Useful because NO-IP will delete your account unless there is some periodic activity. So change 
# ip address to something else, and then back to the chosen ip
#
sub forceNoIpUpdate {
    my ( $ip, $hostname, $sleepTime ) = @_;
    $ip = getIpFromInternet() if not defined $ip;
    $sleepTime = 10 if not defined $sleepTime;
    
    if( not defined $dummy_ip or not $dummy_ip ) {
        writeLog( 0, 0, "No valid dummy IP address found in config file, using default 127.0.0.1.\n\n" );
        $dummy_ip = "127.0.0.1"
    }
    
    writeLog( 2, 0, "let's see what we resolve to now\n" );
    my $ipA = resolve($hostname, 1);

    writeLog( 2, 0, "Dummy Update ($dummy_ip): " );
    my( $ret ) = updateNoIp( $dummy_ip );
    writeLog( 2, 0, "Dummy update, ret: " . $ret . "\n" );
    writeLog( 2, 1, "dummy update did not return ok, program exiting\n" ) if not $ret =~ /^OK/ ;
    
    writeLog( 2, 0, "let's see what we resolve to now\n" );
    my $ipB = resolve($hostname, 1);

    writeLog( 2, 0, "Waiting ($sleepTime) ..." );
    sleep( $sleepTime );
    writeLog( 2, 0, " done.\n" );
    
    writeLog( 2, 0, "Real Update ($ip): " );
    $ret = updateNoIp( $ip );
    writeLog( 2, 0, "Real update, ret: " .$ret . "\n" );
    
    writeLog( 2, 1, "real update did not return ok, program exiting" ) if not $ret =~ /^OK/ ;

    writeLog( 2, 0, "let's see what we resolve to now\n" );
    my $ipC = resolve($hostname, 1);

    writeLog( 2, 0, "ip started at $ipA, was temporarily $ipB, and is now $ipC\n" );
    exit( 0 );
}

##############################################################################################################
# update NO-IP if my current IP does not equal my resoved IP
# 
sub updateNoIpIfIpAddressHasChanged {
    my $internetIP = getIpFromInternet();
    my $resolveIP = resolve($hostname, 0);
    writeLog( 1,1, "ERROR - can't resolve host: $hostname") if not defined $resolveIP;
    
    if ( $resolveIP eq $internetIP ) {
        writeLog( 0,0, "host: $hostname resolves to ip: $resolveIP\n\tNo update necessary\n\tBye.\n\n");
        exit(0);
    }
    
    writeLog( 0,0, "Send new IP address to no-dns\n\told: $resolveIP\n\tnew: $internetIP\n\n");
    getIpIfNecessaryAndUpdateNoIp( $internetIP );
}

##############################################################################################################
# get the IP from the 'internet' and display it to the user
sub whatIsMyIpAddress {
    my $internetIP = getIpFromInternet();
    writeLog( 0,0, "IP address: $internetIP\n\n") if defined $internetIP;
    writeLog( 0,0, "IP address can not be determined (are you connected to the internet?)\n\n") if not defined $internetIP;
}

##############################################################################################################
# when called from the command line, set $blab == 1 so the user can see the progress
# when called from another routine, set $blab == 0 so the calling routine can decide what to print
sub resolve {
    my ($sitename, $blab) = @_;
    
    my $ba = inet_aton( $sitename );
    my $address = undef;
    if ( $ba ) {
        $address = inet_ntoa( $ba );
    }
    
    writeLog( $blab ? 0 : 3, 0, "$sitename resolves to $address\n" ) if defined $address;
    writeLog( $blab ? 0 : 3, 0, "$sitename does not resolve (are you connected to the internet)\n" ) if not defined $address;
    
    return $address;
}

##############################################################################################################
1;
