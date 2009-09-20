#!/usr/bin/perl

use strict;
use Digest::MD5 qw(md5_hex);
use Frontier::Client;
use DateTime;
use Getopt::Long;
use Encode qw(encode decode);

my $server_url = 'http://www.livejournal.com/interface/xmlrpc';
my $username;
my $pass;
my $hpass;
my $security;
my $subj = '';
my $journal = '';
my $edit;

GetOptions(
	'username|user=s' => \$username,
	'password|pass=s' => \$pass,
	'hpassword|hpass=s' => \$hpass,
	'server=s' => \$server_url,
	'security=s' => \$security,
	'subject|subj=s' => \$subj,
	'journal=s' => \$journal,
	'edit=s' => \$edit
	);

$username or die "Specify username.\n";
$server_url or die "Specify sever.\n";

if( ($pass && $hpass) || (!$pass && !$hpass) ) {
	 die "Specify either password or hpassword (md5 of password).\n";
}

if( $pass ) {
	$hpass = md5_hex($pass);
}

my $server = Frontier::Client->new('url' => $server_url, 'encoding' => 'UTF-8');

my $chal = $server->call('LJ.XMLRPC.getchallenge'); 
my $resp = md5_hex($chal->{'challenge'} . $hpass);

my $dt = DateTime->now(time_zone => "local");

undef $/;

if( !$edit ) {

	if( !$security ) {
		$security = 'public';
	}

	my $res = $server->call('LJ.XMLRPC.postevent', {
		'username' => $username,
		'auth_method' => 'challenge',
		'auth_challenge' => $chal->{'challenge'},
		'auth_response' => $resp,
		'ver' => 1,
		'subject' => $subj,
		'event' => <STDIN>,
		'lineendings' => "\n",
		'security' => $security,
		'usejournal' => $journal,
		'year' => $dt->year(),
		'mon' => $dt->month(),
		'day' => $dt->day(),
		'hour' => $dt->hour(),
		'min' => $dt->min()
		});

	print $res->{'itemid'} . "\n" . $res->{'url'} . "\n";

} else {

	my $res = $server->call('LJ.XMLRPC.editevent', {
		'username' => $username,
		'auth_method' => 'challenge',
		'auth_challenge' => $chal->{'challenge'},
		'auth_response' => $resp,
		'ver' => 1,
		'itemid' => $edit,
		'subject' => $subj,
		'event' => <STDIN>,
		'lineendings' => "\n",
		'security' => $security,
		'usejournal' => $journal
		});
		
	print $res->{'itemid'} . "\n" . $res->{'url'} . "\n";

}

