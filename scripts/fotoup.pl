#!/usr/bin/perl
#
# Tool to upload pictures to a FotoBilder server.
#
# Brad Fitzpatrick <brad@danga.com>
# Brad Whitaker <whitaker@danga.com>
#

use strict;
use LWP 5.8;
use LWP::UserAgent;
use HTTP::Request::Common;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use URI::Escape;
use XML::Simple;
use File::Find;
use File::Basename;

# disable buffering
$| = 1;

my $CONFFILE = "$ENV{'HOME'}/.fotoup.conf";

my ($opt_help, 
    $opt_public, $opt_private, 
    $opt_backup, 
    $opt_recursive,
    @opt_under,
    @opt_gallery, $opt_date);
exit 1 unless GetOptions('help' => \$opt_help,
                         'public|u' => \$opt_public,
                         'private|v' => \$opt_private,
                         'backup' => \$opt_backup,
                         'recursive' => \$opt_recursive,
                         'under=s' => \@opt_under,
                         'gallery=s' => \@opt_gallery,
                         'date=s' => \$opt_date,
                         );

if ($opt_help || (! $opt_backup && @ARGV == 0)) {
    print STDERR "Usage: fotoup.pl [opts] <files_or_dirs>+\n\n";
    print STDERR "Options:\n";
    print STDERR "    --gallery=\"Gallery Name\"  (more than 1 okay)\n";
    print STDERR "    --under=\"Gallery Name\"    (more than 1 okay)\n";
    print STDERR "    --recursive               upload directories of pictures\n";
    print STDERR "    --date=\"datestring\"       Optional date of new gallery (format: yyyy[-mm[-dd[[ hh:mm[:ss]]]]])\n";
    print STDERR "    --public                  make security public\n";
    print STDERR "    --private                 make security private\n";
    print STDERR "    --backup                  make local backup of your entire account\n";
    exit 1;
}

if ($opt_private && $opt_public) {
    die "Private & public are mutually exclusive.\n";
}

unless (-s $CONFFILE) {
    open (C, ">>$CONFFILE"); close C; chmod 0700, $CONFFILE;
    print "\nNo $CONFFILE config file found.\nFormat:\n\n";
    print "server: pp.com\n";
    print "username: bob\n";
    print "password: my password\n";
    print "# optional\n";
    print "# defaultsec values: 0=private, 253=reg users only, 254=friends, 255=public\n";
    print "defaultsec: 0\n";
    exit 1;
}

my %conf;
open (C, $CONFFILE);
while (<C>) {
    next if /^\#/;
    next unless /\S/;
    chomp;
    next unless /^(\w+)\s*:\s*(.+)/;
    $conf{$1} = $2;
}
close C;

my $is_dirs = 0;
my $is_files = 0;
my $is_topfiles = 0;
foreach (@ARGV) {
    die "Unknown file or directory: $_\n" unless -e $_;
    $is_dirs = 1 if -d _;    
    if (-f _) {
        $is_files = 1;        
        unless (m!/!) { # TODO: use File::Spec for portability
            $is_topfiles = 1;
        }
    }
}

if ($is_dirs && ! $opt_recursive) {
    die "To upload directories, use --recursive\n";
}

if ($opt_recursive && @opt_gallery) {
    die "Can't use specify --gallery names when using --recursive\n";
}

if ($is_topfiles && $opt_recursive && ! @opt_under) {
    die "When uploading a mix of directories and files recursively, you must specify at least one --under=\"\" gallery so the server will know where to put your top-level pictures.\n";
}

# expand directories
my @files;
foreach my $file (@ARGV) {
    if (-f $file) {
        push @files, $file;
        next;
    }
    if (-d $file) {
        find({
            'wanted' => sub {
                return if /\.(xvpics|thumbnails|thumbs)/;  # TODO: add more common thumbnail patterns?
                return unless -f $_;
                push @files, $_;
            },
            'no_chdir' => 1,
        }, $file);
    }
}

@files = sort @files;

my $ua = LWP::UserAgent->new;
$ua->agent("FotoBilder_Uploader/0.2");
my $chal = "";

sub error_as_str
{
    my $err = shift;
    return "" unless $err;
    return "[Error $err->{code}] $err->{content}\n";
}

sub get_challenge
{
    my $req = HTTP::Request->new(GET => "http://$conf{'server'}/interface/simple");
    $req->push_header("X-FB-Mode" => "GetChallenge");
    $req->push_header("X-FB-User" => $conf{'username'});
    
    my $res = $ua->request($req);
    die "HTTP error: " . $res->content . "\n"
        unless $res->is_success;

    my $xmlres = XML::Simple::XMLin($res->content);
    my $methres = $xmlres->{GetChallengeResponse};

    if (my $err = $xmlres->{Error} || $methres->{Error}) {
        die error_as_str($err);
    }

    return $methres->{Challenge};
}

sub make_auth
{
    my $chal = shift;
    return "crp:$chal:" . md5_hex($chal . md5_hex($conf{'password'}));
}

sub read_file
{
    my $file = shift;

    my $img;
    open (F, $file) or die "Unable to read file: $file.\n";
    binmode(F);
    { local $/ = undef;
      $img = <F>; }
    close F;

    my $basefile = basename($file);
    my $md5 = Digest::MD5::md5_hex($img);
    my $length = length($img)
        or die "no filesize for image: $file.\n";

    return {
        Filename    => $file,
        Basefile    => $basefile,
        MD5         => $md5,
        ImageLength => $length,
        Dataref     => \$img,
    };
}

# start with UploadPrepare request
my @to_upload = (); # { keys: Filename, Basefile, ImageLength, MD5, PicSec, Receipt }

if (@files) {

    print "Reading local files...\n";

    my @post = ();

    # Create a request
    my $req = HTTP::Request->new(PUT => "http://$conf{'server'}/interface/simple");

    my %info_of_md5 = (); # md5 => { $filerec w/o Dataref }

    my $tot = scalar @files;
    my $idx = 0;
    while (@files) {

        # print a nice status line
        printf(" %.03d/%.03d [%05.02f%%]\n", $idx+1, $tot, ($idx+1)/$tot*100);

        my $file = shift @files;
        unless (-e $file) {
            print STDERR "File doesn't exist: $file\n";
            next;
        }

        my $filerec = read_file($file);
        my $magic = unpack("H*", substr(${$filerec->{Dataref}}, 0, 10));

        push @post, "UploadPrepare.Pic.$idx.MD5"   => $filerec->{MD5};
        push @post, "UploadPrepare.Pic.$idx.Magic" => $magic;
        push @post, "UploadPrepare.Pic.$idx.Size"  => $filerec->{ImageLength};

        delete $filerec->{Dataref};
        $info_of_md5{$filerec->{MD5}} = $filerec;

        $idx++;
    }
    print "\n";

    unless ($chal) {
        print "Getting challenge...\n";
        $chal = get_challenge()
            or die "No challenge string available.\n";
    }

    print "Checking for existing files...\n";

    unshift @post, (
                    Mode => "UploadPrepare",
                    User => $conf{'username'},
                    Auth => make_auth($chal),
                    GetChallenge => 1,
                    'UploadPrepare.Pic._size' => $idx,
                    );

    my $res = $ua->request(POST "http://$conf{'server'}/interface/simple", \@post);
    die "HTTP error: " . $res->content . "\n"
        unless $res->is_success;

    my $xmlres = XML::Simple::XMLin($res->content, 
                                    KeyAttr => '', 
                                    ForceArray => ['Pic']);

    my $methres = $xmlres->{UploadPrepareResponse};
    my $chalres = $xmlres->{GetChallengeResponse};

    if (my $err = $xmlres->{Error} || $methres->{Error} || $chalres->{Error}) {
        die error_as_str($err);
    }

    # { keys: Filename, ImageLength, MD5, Receipt? }
    foreach (@{$methres->{Pic}||[]}) {
        my $rec = $info_of_md5{$_->{MD5}};
        $rec->{Receipt} = $_->{Receipt} if $_->{known};

        push @to_upload, $rec;
    }

    $chal = $chalres->{Challenge};
}

my $known_ct = (grep { $_->{Receipt} } @to_upload)+0;
print "To upload: " . (@to_upload-$known_ct) . " from data, $known_ct from receipt\n\n";

# upload via data/receipt
while (@to_upload)
{
    my $rec = shift @to_upload;

    my $sleep_error = sub {
	my $err = shift;
	if (++$rec->{_error_count} > 3) {
	    die "\n >>> ERROR: $err\n >>> aborting.\n";
	}
	print STDERR "\n >>> ERROR: $err\n >>> (will try again in 5 seconds)\n";
	sleep 5;
        $chal = undef;
	unshift @to_upload, $rec;
    };

    my $file = $rec->{Filename};
    my $src = $rec->{Receipt} ? "receipt" : "data";
    print "Uploading from $src: $file\n";

    my @gals;
    if ($opt_recursive) {
        my @paths = @opt_under;
        my $dir = $file;
        $dir =~ s!^\.{0,2}\/!!;
        push @paths, split(m!/+!, $dir);
        pop @paths;  # pop the filename
        push @gals, join("\0", @paths);
    } else {
        @gals = @opt_gallery;
    }

    unless ($chal) {
        print "Getting challenge...\n";
	$chal = get_challenge()
            or die "No challenge string available.\n";
    }

    # read file if it needs to be uploaded from scratch,
    # otherwise use receipt from UploadPrepare above
    my $filerec = $rec->{Receipt} ? $rec : read_file($file);

    # Create a request
    my $req = HTTP::Request->new(PUT => "http://$conf{'server'}/interface/simple");
    $req->push_header("X-FB-Mode" => "UploadPic");
    $req->push_header("X-FB-User" => $conf{'username'});
    $req->push_header("X-FB-Auth" => make_auth($chal));
    $req->push_header("X-FB-GetChallenge" => 1);

    # picture security
    my $sec = $conf{'defaultsec'} ? $conf{'defaultsec'}+0 : 255;
    $sec = 0 if $opt_private;
    $sec = 255 if $opt_public;
    $req->push_header("X-FB-UploadPic.PicSec" => $sec);

    # add to galleries
    if (@gals) {

        # initialize galleries struct array
        $req->push_header(":X-FB-UploadPic.Gallery._size" => scalar(@gals));

        # add individual galleries
        foreach my $idx (0..@gals-1) {
            my $gal = $gals[$idx];

            my @path = split(/\0/, $gal);
            my $galname = pop @path;

            if (@path) {
                print "Adding to gallery: [", join(" // ", @path, $galname), "]\n";
            } else {
                print "Adding to gallery: $galname\n";
            }

            $req->push_header
                ("X-FB-UploadPic.Gallery.$idx.GalName" => $galname);
            $req->push_header
                ("X-FB-UploadPic.Gallery.$idx.GalDate" => $opt_date);
            $req->push_header
                ("X-FB-UploadPic.Gallery.$idx.GalSec" => $sec);

            if (@path) {
                $req->push_header
                    (":X-FB-UploadPic.Gallery.$idx.Path._size" => scalar(@path));
                foreach (0..@path-1) {
                    $req->push_header
                        (":X-FB-UploadPic.Gallery.$idx.Path.$_" => $path[$_]);
                }

            }
        }
    }

    # MD5 and filename
    $req->push_header("X-FB-UploadPic.MD5" => $filerec->{MD5});
    $req->push_header("X-FB-UploadPic.Meta.Filename" => $filerec->{Basefile});

    # PUT content (Receipt or ImageData/ImageLength)
    if ($filerec->{Receipt}) {
        $req->push_header("X-FB-UploadPic.Receipt" => $filerec->{Receipt});

    } else {
        $req->push_header("X-FB-UploadPic.ImageLength" => $filerec->{ImageLength});
        $req->push_header("Content-Length" => $filerec->{ImageLength});
        $req->content(${$filerec->{Dataref}});
    }

    my $res = $ua->request($req);
    unless ($res->is_success) {
	$sleep_error->("HTTP error: " . $res->content);
	next;
    }

    my $xmlres = XML::Simple::XMLin($res->content);
    my $methres = $xmlres->{UploadPicResponse};
    my $chalres = $xmlres->{GetChallengeResponse} || {};

    if (my $err = $xmlres->{Error} || $methres->{Error} || $chalres->{Error}) {
	$sleep_error->(error_as_str($err));
	next;
    }

    print "OK\n";
    print "PicID=$methres->{PicID}\n";
    print "URL=$methres->{URL}\n\n";

    $chal = $chalres->{Challenge};
}

if ($opt_backup)
{
    # TODO: use new version of protocol for backups (multiple requests)

    my $backdir = $conf{'backupdir'};
    die "Can't backup:  no 'backupdir' specified in ~/.fotoup.conf\n"
	unless $backdir;

    $backdir =~ s!^\~/!$ENV{'HOME'}/!;
    die "Can't make backup directory: $backdir\n"
	unless (-d $backdir || mkdir $backdir, 0700);

    my $pooldir = "$backdir/pool";
    die "Can't make pool directory: $pooldir\n"
	unless (-d $pooldir || mkdir $pooldir, 0700);
   
    # fetch the export XML file
    {
	print "Fetching export.xml from server...\n";
	my $req = HTTP::Request->new('POST', "http://$conf{'server'}/manage/export");
	my $auth = make_auth(get_challenge());
	$auth .= ":$conf{'username'}";
	$req->push_header("Cookie" => "fbsession=" . $auth);
	my $res = $ua->request($req);
	die "Couldn't fetch export XML file from server\n" 
	    unless $res->is_success;
	open (E, ">$backdir/export.xml") or die "Can't open export.xml\n";
	print E $res->content;
	close E;
    }
    
    my %altfile;  # file -> hashref
    my %altmd5;   # md5 -> hashref
    open (A, "$backdir/altfiles.dat");
    while (<A>) {
	chomp;
	my ($file, $size, $mtime, $md5) = split /\t/;
	$altmd5{$md5} = $altfile{$file} = {
	    'file' => $file,
	    'size' => $size,
	    'mtime' => $mtime,
	    'md5' => $md5,
	    'valid' => 0,  # will become valid later, or deleted.
	};
    }
    close A;
    open (A, ">>$backdir/altfiles.dat") or die "Can't append to altfiles.dat\n";
    select(A); $| = 1; select(STDOUT);
    
    # discover new pictures
    my @index = split(/\s*\,\s*/, $conf{'backupindex'});
    foreach (@index) {
	s!^\~/!$ENV{'HOME'}/!;
	my $id = $_;
	print "Discovering existing pictures in: $id\n";
	my @new;
	my $same;
	find({
	    'wanted' => sub { 
		return unless -f $_;
		my $size = -s _;
		my $mtime = (stat(_))[9];
		if ($altfile{$_} && 
		    $altfile{$_}->{'mtime'} == $mtime &&
		    $altfile{$_}->{'size'} == $size) 
		{
		    # mark that it's still alive.
		    $altfile{$_}->{'valid'} = 1;
		    $same++;
		    return;
		}
		push @new, [ $_, $size, $mtime ];
	    },
	    'no_chdir' => 1,
	},  $id);

	my $new = @new;
	print "  $same files already known.\n";
	if ($new) {
	    print "  $new files to learn...\n";
	    print "    0/$new (0.0%)\n";
	}
	my $done;
	foreach my $n (@new)
	{
	    my ($file, $size, $mtime) = @$n;

	    my $ctx = Digest::MD5->new;
	    open (F, $file) or die "Can't open file $file";
	    $ctx->addfile(\*F);
	    close F;
	    my $md5 = $ctx->hexdigest;

	    print A "$file\t$size\t$mtime\t$md5\n";
	    if (++$done % 10 == 0) {
		printf "    $done/$new (%.01f%)\n", (100*$done/$new);
	    }

	    $altmd5{$md5} = $altfile{$file} = {
		'file' => $file,
		'size' => $size,
		'mtime' => $mtime,
		'md5' => $md5,
		'valid' => 1,
	    };
	}

    }
    close A;

    # forget about files that have disappeared
    {
	my @remove;
	while (my ($file, $p) = each %altfile) {
	    push @remove, $p unless $p->{'valid'};
	}
	foreach my $p (@remove) {
	    delete $altmd5{$p->{'md5'}};
	    delete $altfile{$p->{'file'}};
	}
    }

    my $ex = XMLin("$backdir/export.xml",
		    keyattr => [ ],
		    );

    my $total = scalar @{$ex->{'pics'}->{'pic'}};
    print "Total pictures: $total\n";
    my $good = 0;
    my @backup;

    # check to see what we already have
    foreach my $p (@{$ex->{'pics'}->{'pic'}}) {
	my $md5 = $p->{'md5'};
	die "Bogus md5: $md5" unless $md5 =~ /^(..)(..).{28,28}$/;
	my ($pa, $pb) = ($1, $2);
	
	my $padir = "$pooldir/$pa";
	die "Can't make pooldir: $padir"
	    unless -d $padir || mkdir $padir, 0700;
	my $pbdir = "$pooldir/$pa/$pb";
	die "Can't make pooldir: $pbdir"
	    unless -d $pbdir || mkdir $pbdir, 0700;

	my $ext;
	if ($p->{'format'} eq "image/jpeg") { $ext = ".jpg"; }
	elsif ($p->{'format'} eq "image/gif") { $ext = ".gif"; }
	elsif ($p->{'format'} eq "image/png") { $ext = ".png"; }

	# location in pool
	my $dfile = "$pbdir/$md5$ext";
	
	# save for later:
	$p->{'-dfile'} = $dfile;

	if (-l $dfile) {
	    my $dest = readlink $dfile;
	    my $a = $altfile{$dest};
	    if ($a && $a->{'md5'} eq $md5) {
		$good++;
		next;
	    }
	} else {
	    # is it in the pool as a regular file?
	    if (-f $dfile && -s _ == $p->{'bytes'}) {
		# but maybe there's since become a copy elsewhere
		# so we could kill the pool copy and save some disk space.
		my $a = $altmd5{$p->{'md5'}};
		if ($a) {
		    unlink $dfile;
		    if (symlink $a->{'file'}, $dfile) {
			print "Deleted pool copy, replaced with link to $a->{'file'}\n";
			$good++;
			next;
		    }		
		} else {
		    $good++;
		    next;
		}
	    }
	}

	if ($altmd5{$p->{'md5'}}) {
	    unlink $dfile;
	    my $file = $altmd5{$p->{'md5'}}->{'file'};
	    if (symlink $file, $dfile) {
		$good++;
		next;
	    }
	}
	
	push @backup, $p;
    }

    print "Already backed up: $good\n";

    my $files_total = @backup;
    my $files_done = 0;
    print "Pictures to backup: $files_total\n";

    my $bytes_total = 0;
    my $bytes_done = 0;
    foreach my $p (@backup) { $bytes_total += $p->{'bytes'};   }
    print "Bytes to fetch over network: $bytes_total\n";

    $| = 1;
    foreach my $p (@backup) {
	$files_done++;
	print "  Fetching image $files_done/$files_total ... ";

	my $tempfile = "$pooldir/.picdownload.$p->{'picid'}";
	open (S, ">$tempfile") or die "Can't make download file: $tempfile\n";
	binmode(S);
	my $callback = sub {
	    my ($data, $response, $protocol) = @_;
	    print S $data;
	};

	my $req = HTTP::Request->new('GET', $p->{'url'});
	
	# for non-public pics, we need to authenticate
	if ($p->{'secid'} != 255) {
	    my $auth = make_auth(get_challenge());
	    $auth .= ":$conf{'username'}";
	    $req->push_header("Cookie" => "fbsession=" . $auth);
	}

	my $res = $ua->request($req, $callback, 4096);
	unless ($res->is_success) {
	    my $error = ($res->content() || error_as_str($res));
	    print "Error: \#$p->{'picid'}: $error\n";
	    next;
	}
	close S;

	# be paranoid and verify file's md5 (did download work?)
	open (S, $tempfile);
	my $ctx = Digest::MD5->new;
	$ctx->addfile(\*S);
	close F;
	my $md5 = $ctx->hexdigest;
	close S;
	die "MD5 of downloaded file doesn't match.\n"
	    unless $md5 eq $p->{'md5'};
	
	# move file to its permanent home
	unlink $p->{'-dfile'};
	rename $tempfile, $p->{'-dfile'};

	$bytes_done += $p->{'bytes'};
	printf " %0.01f%%\n", ($bytes_done/$bytes_total*100);

    }

}
