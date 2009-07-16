#!/usr/bin/perl

#
# css-compile.pl
#
our $PACKAGE = 'css-compile.pl';
our $VERSION = '0.11';

our $debugging = 1;
our $show_version = 0;
my $stylesheet = undef;

# Required packages.
use CSS::Tiny;
use CSS::Tiny::Style;
use Getopt::ArgvFile qw(argvFile);
use Getopt::Long qw(GetOptions);
use HTML::Element;
use HTML::TreeBuilder;
use HTTP::Cookies;
use Pod::Usage;
use strict;
use URI::Escape;

# Read options
&argvFile
(
	"home"                  => 1,
	"current"               => 1,
	"resolveEnvVars"        => 1,
	"resolveRelativePathes" => 1,
	"startupFilename"       => ".css-compile",
	"fileOption"            => "--options"
);
&GetOptions
(
	"style|css|c=s"    => \$stylesheet,
	"verbose!"         => \$debugging,
	"quiet"            => sub { $debugging = 0; },
	"help|usage|h"     => sub { pod2usage(1); },
	"version|V"        => \$show_version
);

die "$PACKAGE/$VERSION\n" if ($show_version);

# Open input and output files -- default to STDIN and STDOUT.
my $infile  = shift @ARGV || '/dev/stdin';
my $outfile = shift @ARGV || '/dev/stdout';
&Debug("Input is from $infile.");
&Debug("Output is to $outfile.");
open INPUT,  "<:utf8", $infile;
open OUTPUT, ">:utf8", $outfile;

# Get HTML input.
my @html = <INPUT>;
my $html = join '', @html;

# Parse HTML input.
&Debug("Parsing HTML.");
my $root = HTML::TreeBuilder->new();
$root->implicit_tags(1);
$root->implicit_body_p_tag(1);
$root->p_strict(1);
$root->parse_content($html);

# Apply stylesheet to document.
$root = &Apply_Stylesheet($root, $stylesheet);

# Output finished HTML.	
&Debug("Generating output.");
$html = $root->as_HTML(undef, "\t");
print OUTPUT $html;

# Close files.
close INPUT;
close OUTPUT;

# All done!
exit;


#######################################################################
############################  Subroutines  ############################
#######################################################################

#
# Debug($msg)
#
# Output nice debugging message.
#
sub Debug
{
	print STDERR $_[0]."\n" if ($debugging);
}

sub Apply_Stylesheet
{
	my $root = shift;
	my $stylesheet = shift;
	
	if (!defined($stylesheet) || !length($stylesheet) || ! -s $stylesheet)
	{
		return $root;
	}

	&Debug("Applying stylesheet $stylesheet.");

	# Read stylesheet and retain internal order of rules.
	my $css = CSS::Tiny->read($stylesheet)
		|| warn "Stylesheet '$stylesheet' could not be processed.\n";
	my $i = 0;
	
	for my $st ($css->styles)
	{
		$st->{'_internal_order'} = $i++;
	}

	# For each HTML element...
	for my $el ($root->descendants)
	{
		# Find stylesheet rules which apply and sort by specifificity.
		my @applied_styles = ();	
		for my $st ($css->styles)
		{
			push @applied_styles, $st if (MY_match($st, $el));
		}
		sort Selector_Sort @applied_styles;

		# Apply each stylesheet rule, over-writing older (less specific)
		# values.
		my %S;		
		foreach my $st (@applied_styles)
		{
			foreach my $prop (keys %{ $st })
			{
				next if ($prop =~ m/^\_/);
				$S{lc($prop)} = $st->{$prop};
			}
		}

		# Pay attention to the element's "style" attribute, which should
		# over-ride all the CSS rules.
		my @internal_definitions = split /\;/, $el->attr('style');
		foreach my $def (@internal_definitions)
		{
			next if ($def !~ m/[a-z]/i);

			my ($prop, $val) = split /\:/, $def;
			$prop =~ s/(^\s+)|(\s+$)//g;
			$val  =~ s/(^\s+)|(\s+$)//g;

			$S{lc($prop)} = $val;
		}

		# Stringify.
		my $style = '';
		foreach my $prop (keys %S)
		{
			$style .= "$prop: $S{$prop}; ";
		}

		# Write attribute back to element.
		$style =~ s/ $//;
		$style = undef if ($style eq "");
		$el->attr('style', $style);

		# All the above is a lot smarter than the method
		# suggested in CSS::Tiny::Style's documentation.
	}
		
	return $root;
}

#
# Selector_Sort()
#
# Used to sort CSS selectors by specificity.
#
sub Selector_Sort
{
	my $spec = $a->specificity <=> $b->specificity;
	return $spec unless ($spec == 0);	
	return $a->{'_internal_order'} <=> $b->{'_internal_order'};
}

#
# MY_match()
#
# Local fixed copy of buggy CSS::Tiny::Style->match().
#
sub MY_match {
    my $self = shift;

    # the next argument is an element or a listref of elements
    my @el = shift; if (ref $el[0] eq 'ARRAY') { @el = @{$el[0]} };

    my ($sel, $rel, @sel);
    if (@_) {
	(
	 $sel,	# the first selector
	 $rel, 	# the relationship, i.e.: '>' or '+' or ' '
	 @sel	# the remaining selector
	) = @_;
    } else {
	($sel, $rel, @sel) = $self->selector_array;
    }

    #+++++++++++++++++++++++++++++++++++++++++++++++++++++
    # 1) loop through elements
    # 2) check if one matches
    # 3) if it matches, loop through his relatives
    # 4) return true if one matches
    #+++++++++++++++++++++++++++++++++++++++++++++++++++++

    my $match = 0;
    for (@el) {
	if ($self->element_match($_, $sel)) {
	    # if element matches, check his relatives
	    if ($rel) {
	        my $rellist = ();
	    	if ($rel eq 'parent')
		{
		  $rellist = ($_->{_parent});
		}
		elsif ($rel eq 'left')
		{
		  warn "CSS sibling selectors break things!\n";
		}
		elsif ($rel eq 'lineage')
		{
		  my $x = $_;
		  while (defined($x->{_parent}))
		  {
		  	push @{ $rellist }, $x->{_parent};
			$x = $x->{_parent};
		  }
		}
		$match = MY_match($self, $rellist, @sel)
	    } else {
		$match = 1;
	    }
	}
	last if $match;
    };
    
    return $match;
}

#######################################################################
###########################  Documentation  ###########################
#######################################################################

__END__

=head1 NAME

css-compile.pl - Compile CSS and HTML file together.

=head1 SYNOPSIS

css-compile.pl [@optfile] [options] [infile] [outfile]

Options:

  --css=FILE, -c FILE    Apply CSS file F.
  
  --verbose              Enable debugging messages.
  --noverbose, --quiet   Disable debugging messages.

  --options=OPTFILE      Alternative syntax for options file.

  --help, --usage, -h    Show this help message.
  --version, -V          Show version number.

Will read additional options from file optfile if specififed. By default
files ~/.css-compile and ./.css-compile (if present) are inspected for
options.

infile defaults to STDIN.
outfile defaults to STDOUT.

=head1 OPTIONS

=over 8

=item B<--css=FILE>

Given the file name of a cascading style sheet, will apply the style
sheet to the HTML tree, adding "style" attributes where appropriate.
This is pretty nifty.

=item B<--verbose>, B<--noverbose>, B<--quiet>

Control verbosity.

=item B<--options=OPTFILE>

Read command-line options from option file.

=item B<--help>, B<--usage>, B<--version>

Show usage/version information. Does not process files.

=back

=head1 DESCRIPTION

The program takes CSS rules and applies them to an HTML file, producing a
"compiled HTML file" which has the rules inserted into style attributes.

=head1 CSS SELECTORS

Supports the following selectors:

	* Element selector (e.g. div {...})
	* Class selector (e.g. .warning {...})
	* ID selector (e.g. #header {...})
	* Descendent selector (e.g. div p {...})
	
The following selectors should work, but may be buggy:

	* Child selector (e.g. div>p {...})
	* Sibling selector (e.g. p+p {...})
	
Pseudo-class selectors such as :hover and :visited do not work and may cause
the script to hang or crash!

=head1 AUTHOR

Toby Inkster.


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2008, Toby Inkster. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
