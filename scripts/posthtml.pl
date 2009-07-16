#!/usr/bin/perl

use strict;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use HTML::TreeBuilder;
use HTML::Element;
use File::Basename;
use Encode qw(encode decode);
use File::Temp qw(tempfile);

my $security;
my $journal;
#my $htbl;

GetOptions(
	'security=s' => \$security,
	'journal=s' => \$journal
	#'hashtable|hash=s' => \$htbl
	);

my $htmlfile = shift(@ARGV);
my $dir = dirname($htmlfile);

print STDERR "Reading configuration file...\n";

# take username and password from the configuration file of fotoup.pl
my $CONFFILE = "$ENV{'HOME'}/.fotoup.conf";

my %conf;
open(C, $CONFFILE) or die "Cannot open configuration file (~/.fotoup.conf).\n";
while (<C>) {
	next if /^\#/;
	next unless /\S/;
	chomp;
	next unless /^(\w+)\s*:\s*(.+)/;
	$conf{$1} = $2;
}
close C;

my $server_url = $conf{'xmlrpcserver'} || 'http://www.livejournal.com/interface/xmlrpc';
my $user = $conf{'username'};
my $pass = $conf{'password'};



print STDERR "Reading itemid file...\n";

my $itemidfile = $dir . "/." . basename($htmlfile) . ".$user.$journal";
my $edit;

if( open(ITEMID, "<", $itemidfile) ) {
	$edit = <ITEMID>;
	close(ITEMID);
} else {
	print STDERR "Itemid file doesn't exits (it will be created after sending the html to the server)\n";
}


print STDERR "Reading html file...\n";

undef $/;

# now read html file
open(INPUT, "<:utf8", $htmlfile) or die $!;
my $htmlcontent = <INPUT>;

my $root = HTML::TreeBuilder->new();
$root->implicit_tags(1);
$root->implicit_body_p_tag(1);
$root->p_strict(1);
$root->parse_content($htmlcontent);

close(INPUT);

#my %imtable;
#
#if( $htbl ) {
#
#	$/ = "\n";
#	open HTBL, "+>", $htbl or die $!;
#	while( <HTBL> ) {
#		next unless /^([a-f0-9]+)\s+(.+)/;
#		$imtable{$1} = $2;
#	}
#
#}


print STDERR "Uploading images...\n";

my @imgels = $root->find('img');

my $prefix = $dir . "/";
my $imglist = join(" ", map { "'" . $prefix . $_->attr('src') . "'"} @imgels);
my %imgs;

map { $imgs{$_->attr('src')} = $_ } @imgels;

$/ = "\n";
my @uploadres = `./fotoup.pl $imglist | tee /dev/stderr`;

$prefix = quotemeta($prefix);
while( @uploadres ) {
	my $str = shift(@uploadres);
		
	if( $str =~ /^Uploading from \w+\: (.+)/ && 
	    $1 =~ /$prefix(.+)/) {
		
		my $el = $imgs{$1};
		next unless $el;
		
		next unless shift(@uploadres) =~ /^OK/;
		shift(@uploadres);
		
		next unless shift(@uploadres) =~ /^URL\=(.+)/;
		$el->attr('src', $1);
		
		print STDERR "Replaced some image with $1\n";
	}
}

#for my $img (@imgels) {
#	
#	my $src = $dir . "/" . $img->attr('src');
#	$/ = "\n";
#	my @lala = `./fotoup.pl '$src'`;
#	if( $? != 0 ) {
#		print STDERR "fotoup.pl exited with code $?, here is its output:\n";
#		print STDERR @lala;
#		next;
#	}
#	pop(@lala);
#	pop(@lala) =~ /^URL\=(.+)/ or die "Cannot upload $src\n";
#	$img->attr('src', $1);
#	print STDERR "Uploaded $src (URL=$1)\n";
#
#}


my $head = $root->find('head');
my $subj = $head->find('title')->as_text();
my $css = $dir . "/" . 
	$head->look_down(
		'_tag', 'link',
		'rel', 'stylesheet'
		)->attr('href');

my ($tempcssh, $tempcss) = tempfile();
my ($temphtmlh, $temphtml) = tempfile();


print STDERR "Deleting \@media from css ($css)...\n";

system("sed 's/^\@media.\\+//g' < '$css' > '$tempcss'");


print STDERR "Inlining css...\n";

open(OUTPUT, "|./css-compile.pl -css '$tempcss' | tr '\\n' ' ' > '$temphtml'")
	or die "Cannot execute ./css-compile.pl\n";

print OUTPUT $root->as_HTML;

close(OUTPUT);

$? == 0 or die "Errors during css inlining\n";


print STDERR "Uploading html to the server...\n";

system( "cat $temphtml | ./ljpost.pl --subj '$subj' --user '$user' --pass '$pass' --server '$server_url'" . 
	"  --journal '$journal' --security '$security' " . 
	($edit ? "--edit '$edit'" : " | head -1 > '$itemidfile'"));
