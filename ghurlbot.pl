#!/usr/bin/env perl
#
# This IRC 'bot expands short references to issues, pull requests,
# persons and teams on GitHub to full URLs. See the perldoc at the end
# for how to run it and manual.html for the interaction on IRC.
#
# TODO: The map-file should contain the IRC network, not just the
# channel names.
#
# Created: 2022-01-11
# Author: Bert Bos <bert@w3.org>
#
# Copyright © 2022 World Wide Web Consortium, (Massachusetts Institute
# of Technology, European Research Consortium for Informatics and
# Mathematics, Keio University, Beihang). All Rights Reserved. This
# work is distributed under the W3C® Software License
# (http://www.w3.org/Consortium/Legal/2015/copyright-software-and-document)
# in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.

package GHURLBot;
use FindBin;
use lib "$FindBin::Bin";	# Look for modules in agendabot's directory
use parent 'Bot::BasicBot::ExtendedBot';
use strict;
use warnings;
use Getopt::Std;
use Scalar::Util 'blessed';
use Term::ReadKey;		# To read a password without echoing
use open qw(:std :encoding(UTF-8)); # Undeclared streams in UTF-8
use File::Temp qw(tempfile tempdir);
use File::Copy;
use LWP;
use LWP::ConnCache;
use JSON::PP;

use constant MANUAL => 'https://w3c.github.io/GHURLBot/manual.html';
use constant VERSION => '0.1';
use constant DEFAULT_DELAY => 15;
use constant GITHUB_ENDPOINT => 'https://api.github.com/graphql';


# init -- initialize some parameters
sub init($)
{
  my $self = shift;
  my $errmsg;

  $self->{delays} = {}; # Maps channels to their delay (# of lines)
  $self->{linenumber} = {}; # Maps channels to their # of lines seen
  $self->{joined_channels} = {}; # Set of all channels currently joined
  $self->{history} = {}; # Maps channels to lists of when each ref was expanded
  $self->{suspend_issues} = {}; # Set of channels currently not expanding issues
  $self->{suspend_names} = {}; # Set of channels currently not expanding names
  $self->{repos} = {}; # Maps channels to their repository

  # Create a user agent to retrieve data from GitHub, if needed.
  if ($self->{github_api_token}) {
    $self->{ua} = LWP::UserAgent->new;
    $self->{ua}->agent(blessed($self) . '/' . VERSION);
    $self->{ua}->timeout(10);
    $self->{ua}->conn_cache(LWP::ConnCache->new);
    $self->{ua}->env_proxy;
    $self->{ua}->default_header(
      'Authorization' => 'bearer ' . $self->{github_api_token});
  }

  $errmsg = $self->read_rejoin_list() and die "$errmsg\n";
  $errmsg = $self->read_mapfile() and die "$errmsg\n";

  return 1;
}


# read_rejoin_list -- read or create the rejoin file, if any
sub read_rejoin_list($)
{
  my $self = shift;

  if ($self->{rejoinfile}) {		# Option -r was given
    if (-f $self->{rejoinfile}) {	# File exists
      $self->log("Reading $self->{rejoinfile}");
      open my $fh, "<", $self->{rejoinfile} or
	  return "$self->{rejoinfile}: $!";
      while (<$fh>) {
	chomp;
	$self->{joined_channels}->{$_} = 1;
	$self->{linenumber}->{$_} = 0;
	$self->{history}->{$_} = {};
      }
      # The connected() method takes care of rejoining those channels.
    } else {				# File does not exist yet
      $self->log("Creating $self->{rejoinfile}");
      open my $fh, ">", $self->{rejoinfile} or
	  $self->log("Cannot create $self->{rejoinfile}: $!");
    }
  }
  return undef;				# No errors
}


# read_mapfile -- read or create the file mapping channels to repositories
sub read_mapfile($)
{
  my $self = shift;

  if (-f $self->{mapfile}) {		# File exists
    $self->log("Reading $self->{mapfile}");
    open my $fh, '<', $self->{mapfile} or return "$self->{mapfile}: $!";
    while (<$fh>) {
      my ($channel, $repo, $delay, $what) =
	  $_ =~ /^([^\t]+)\t([^\t]+)\t([0-9]+)\t([^\t]*)\n?$/
	  or return "$self->{mapfile}: wrong syntax";
      $self->{repos}->{$channel} = $repo;
      $self->{delays}->{$channel} = $delay;
      $self->{suspend_issues}->{$channel} = 1 if $what !~ /\bissues\b/;
      $self->{suspend_names}->{$channel} = 1 if $what !~ /\bnames\b/;
    }
  } else {				# File does not exist yet
    $self->log("Creating $self->{mapfile}");
    open my $fh, ">", $self->{mapfile} or
	$self->log("Cannot create $self->{mapfile}: $!");
  }
  return undef;				# No errors
}


# rewrite_rejoinfile -- replace the rejoinfile with an updated one
sub rewrite_rejoinfile($)
{
  my ($self) = @_;

  # assert: defined $self->{rejoinfile}
  eval {
    my ($temp, $tempname) = tempfile('/tmp/check-XXXXXX');
    print $temp "$_\n" foreach keys %{$self->{joined_channels}};
    close $temp;
    move($tempname, $self->{rejoinfile});
  };
  $self->log($@) if $@;
}


# write_mapfile -- write the current status to file
sub write_mapfile($)
{
  my $self = shift;

  if (open my $fh, '>', $self->{mapfile}) {
    foreach (keys %{$self->{repos}}) {
      my $what = '';
      $what .= 'issues,' if !defined $self->{suspend_issues}->{$_};
      $what .= 'names,' if !defined $self->{suspend_names}->{$_};
      printf $fh "%s\t%s\t%d\t%s\n", $_, $self->{repos}->{$_},
	  $self->{delays}->{$_} // DEFAULT_DELAY, $what;
    }
  } else {
    $self->log("Cannot write $self->{mapfile}: $!");
  }
}


# part_channel -- leave a channel, the channel name is given as argument
sub part_channel($$)
{
  my ($self, $channel) = @_;

  # Use inherited method to leave the channel.
  $self->SUPER::part_channel($channel);

  # Remove channel from list of joined channels.
  if (delete $self->{joined_channels}->{$channel}) {

    # If we keep a rejoin file, remove the channel from it.
    if ($self->{rejoinfile}) {
      $self->rewrite_rejoinfile();
    }
  }
}


# chanjoin -- called when somebody joins a channel
sub chanjoin($$)
{
  my ($self, $mess) = @_;
  my $who = $mess->{who};
  my $channel = $mess->{channel};

  if ($who eq $self->nick()) {	# It's us
    $self->log("Joined $channel");

    # Initialize data structures with information about this channel.
    if (!defined $self->{joined_channels}->{$channel}) {
      $self->{joined_channels}->{$channel} = 1;
      $self->{linenumber}->{$channel} = 0;
      $self->{history}->{$channel} = {};

      # If we keep a rejoin file, add the channel to it.
      if ($self->{rejoinfile}) {
	$self->rewrite_rejoinfile();
	# if (open(my $fh, ">>", $self->{rejoinfile})) {print $fh "$channel\n"}
	# else {$self->log("Cannot write $self->{rejoinfile}: $!")}
      }
    }
  }
  return;
}


# # join_channel -- join a channel, the channel name is given as argument
# sub join_channel
# {
#   my ($self, $channel, $key) = @_;

#   $self->log("Joining $channel");

#   # Use inherited method to join the channel.
#   $self->SUPER::join_channel($channel, $key);
# }


# set_repository -- remember the repository $2 for channel $1
sub set_repository($$)
{
  my ($self, $channel, $repository) = @_;

  # Expand the repository to a full URL, if needed.
  $repository =~ s/^ +//;	# Remove any leading spaces
  $repository =~ s/ *+$//;	# Remove any final spaces
  $repository =~ s/\/$//;	# Remove any final slash
  if ($repository !~ m{/}) {	# Only a repository name
    return "Sorry, I don't know the owner. Please, use 'OWNER/$repository'"
	if !defined $self->{repos}->{$channel};
    $repository = $self->{repos}->{$channel} =~ s/[^\/]*$/$repository/r;
  } elsif ($repository =~ m{^[^/]+/[^/]+$}) { # "owner/repository"
    $repository = 'https://github.com/' . $repository;
  } elsif ($repository !~ m{^https://github.com/[^/]+/[^/]+$}) {
    return "Sorry, that doesn't look like a valid repository name.";
  }

  if (($self->{repos}->{$channel} // '') ne $repository) {
    $self->{repos}->{$channel} = $repository;
    $self->write_mapfile();
    $self->{history}->{$channel} = {}; # Forget recently expanded issues
  }

  return "OK. But note that I'm currently off. " .
      "Please use: ".$self->nick().", on"
      if defined $self->{suspend_issues}->{$channel} &&
      defined $self->{suspend_names}->{$channel};
  return "OK. But note that only names are expanded. " .
      "To also expand issues, please use: ".$self->nick().", set issues to on"
      if defined $self->{suspend_issues}->{$channel};
  return "OK. But note that only issues are expanded. " .
      "To also expand names, please use: ".$self->nick().", set names to on"
      if defined $self->{suspend_names}->{$channel};
  return 'OK';
}


# get_issue_summary -- try to retrieve info about an issue or pull request
sub get_issue_summary($$$)
{
  my ($self, $repository, $issue) = @_;
  my ($owner, $repo, $res, $query, $json, $ref, $s);

  return undef if !$self->{ua};

  ($owner, $repo) = $repository =~ /([^\/]+)\/([^\/]+)$/;

  # Make a GraphQL query and embed it in a bit of JSON.
  $query = "query {
      repository(owner: \"$owner\", name: \"$repo\") {
	issueOrPullRequest(number: $issue) {
	  __typename
	  ... on Issue {
	    title
	    author { login }
	    closed
	    labels(first: 100) {
	      edges { node { name } }
	    }
	  }
	  ... on PullRequest {
	    title
	    author { login }
	    closed
	    labels(first: 100) {
	      edges { node { name } }
	    }
	  }
	}
      }
    }";
  $json = encode_json({"query" => $query});

  # $self->log($query);

  $res = $self->{ua}->post(GITHUB_ENDPOINT, Content => $json);

  if ($res->code != 200) {
    $self->log("Code ".$res->code." when querying GitHub:\n".
	       $res->decoded_content);
    return undef;
  }

  $ref = decode_json($res->decoded_content);
  $ref = $ref->{'data'}->{'repository'}->{'issueOrPullRequest'};
  return "Issue $issue [not found]" if !defined $ref->{'__typename'};

  $s = $ref->{'__typename'} . " $issue ";
  $s .= '[closed] ' if $ref->{'closed'};
  $s .= $ref->{'title'};
  $s .= ' (' . $ref->{'author'}->{'login'} . ')';
  $s .= ', ' . $_->{'node'}->{'name'} foreach @{$ref->{'labels'}->{'edges'}};
  return $s;
}


# maybe_expand_references -- return URLs for the issues and names in $text
sub maybe_expand_references($$$$)
{
  my ($self, $text, $channel, $addressed) = @_;
  my ($repository, $linenr, $delay, $do_issues, $do_names, $response);

  $repository = $self->{repos}->{$channel} or return undef; # No repo known
  $linenr = $self->{linenumber}->{$channel};		    # Current line#
  $delay = $self->{delays}->{$channel} // DEFAULT_DELAY;
  $do_issues = !defined $self->{suspend_issues}->{$channel};
  $do_names = !defined $self->{suspend_names}->{$channel};
  $response = '';

  while ($text =~ /(?:^|\W)\K(#([0-9]+)|@(\w+))(?=\W|$)/g) {
    my ($ref, $issue, $name) = ($1, $2, $3);
    my $previous = $self->{history}->{$channel}->{$ref} // -$delay;
    if ($ref =~ /^#/
      && ($addressed || ($do_issues && $linenr > $previous + $delay))) {
      $response .= '-> ';
      $response .= $self->get_issue_summary($repository, $issue) // "#$issue";
      $response .= " $repository/issues/$issue\n";
      $self->{history}->{$channel}->{$ref} = $linenr;
    } elsif ($ref =~ /^@/
      && ($addressed || ($do_names && $linenr > $previous + $delay))) {
      $response .= "-> @$name https://github.com/$name\n";
      $self->{history}->{$channel}->{$ref} = $linenr;
    }
  }
  return $response;
}


# set_delay -- set minimum number of lines between expansions of the same ref
sub set_delay($$$)
{
  my ($self, $channel, $n) = @_;

  if (($self->{delays}->{$channel} // -1) != $n) {
    $self->{delays}->{$channel} = $n;
    $self->write_mapfile();
  }
  return 'OK';
}


# status -- return settings for this channel
sub status($$)
{
  my ($self, $channel) = @_;

  return 'the delay is '
      . ($self->{delays}->{$channel} // DEFAULT_DELAY)
      . ', issues are '
      . ($self->{suspend_issues}->{$channel} ? 'off' : 'on')
      . ', names are '
      . ($self->{suspend_names}->{$channel} ? 'off' : 'on')
      . ' and the repository is '
      . ($self->{repos}->{$channel} // 'not set.');
}


# set_suspend_issues -- set expansion of issues on a channel to on or off
sub set_suspend_issues($$$)
{
  my ($self, $channel, $on) = @_;

  # Do nothing if already set the right way.
  return 'issues were already off.'
      if defined $self->{suspend_issues}->{$channel} && $on;
  return 'issues were already on.'
      if !defined $self->{suspend_issues}->{$channel} && !$on;

  # Add the channel to the set or delete it from the set, and update mapfile.
  if ($on) {$self->{suspend_issues}->{$channel} = 1}
  else {delete $self->{suspend_issues}->{$channel}}
  $self->write_mapfile();
  return 'OK';
}


# set_suspend_names -- set expansion of names on a channel to on or off
sub set_suspend_names($$$)
{
  my ($self, $channel, $on) = @_;

  # Do nothing if already set the right way.
  return 'names were already off.'
      if defined $self->{suspend_names}->{$channel} && $on;
  return 'names were already on.'
      if !defined $self->{suspend_names}->{$channel} && !$on;

  # Add the channel to the set or delete it from the set, and update mapfile.
  if ($on) {$self->{suspend_names}->{$channel} = 1}
  else {delete $self->{suspend_names}->{$channel}}
  $self->write_mapfile();
  return 'OK';
}


# set_suspend_all -- set both suspend_issues and suspend_names
sub set_suspend_all($$$)
{
  my ($self, $channel, $on) = @_;
  my $msg;

  $msg = $self->set_suspend_issues($channel, $on);
  $msg = $msg eq 'OK' ? '' : "$msg\n";
  return $msg . $self->set_suspend_names($channel, $on);
}


# invited -- do something when we are invited
sub invited($$)
{
  my ($self, $info) = @_;
  my $who = $info->{who};
  my $raw_nick = $info->{raw_nick};
  my $channel = $info->{channel};

  $self->log("Invited by $who ($raw_nick) to $channel");
  $self->join_channel($channel);
}


# said -- handle a message
sub said($$)
{
  my ($self, $info) = @_;
  my $who = $info->{who};		# Nick (without the "!domain" part)
  my $text = $info->{body};		# What Nick said
  my $channel = $info->{channel};	# "#channel" or "msg"
  my $me = $self->nick();		# Our own name
  my $addressed = $info->{address};	# Defined if we're personally addressed

  return if $channel eq 'msg';		# We do not react to private messages

  $self->{linenumber}->{$channel}++;

  return $self->part_channel($channel), undef
      if $addressed && $text =~ /^ *bye *\.? *$/i;

  return $self->set_repository($channel, $1)
      if $addressed &&
      $text =~ /^ *(?:discussing|discuss|use|using|take +up|taking +up|this +will +be|this +is) +([^ ]+) *$/i;

  return $self->set_delay($channel, 0 + $1)
      if $addressed &&
      $text =~ /^ *(?:set +)?delay *(?: to |=| ) *?([0-9]+) *(?:\. *)?$/i;

  return $self->status($channel)
      if $addressed && $text =~ /^ *status *(?:[?.] *)?$/i;

  return $self->set_suspend_all($channel, 0)
      if $addressed && $text =~ /^ *on *(?:\. *)?$/i;

  return $self->set_suspend_all($channel, 1)
      if $addressed && $text =~ /^ *off *(?:\. *)?$/i;

  return $self->set_suspend_issues($channel, 0)
      if $addressed &&
      $text =~ /^ *(?:set +)?issues *(?: to |=| ) *(on|yes|true) *(?:\. *)?$/i;

  return $self->set_suspend_issues($channel, 1)
      if $addressed &&
      $text =~ /^ *(?:set +)?issues *(?: to |=| ) *(off|no|false) *(?:\. *)?$/i;

  return $self->set_suspend_names($channel, 0)
      if $addressed &&
      $text =~ /^ *(?:set +)?(names|persons|teams) *(?: to |=| ) *(on|yes|true) *(?:\. *)?$/i;

  return $self->set_suspend_names($channel, 1)
      if $addressed &&
      $text =~ /^ *(?:set +)?names *(?: to |=| ) *(off|no|false) *(?:\. *)?$/i;

  return $self->maybe_expand_references($text, $channel, $addressed);
}


# help -- return the text to respond to an "agendabot, help" message
sub help($$)
{
  my ($self, $info) = @_;
  my $me = $self->nick();		# Our own name
  my $text = $info->{body};		# What Nick said

  return 'I am an IRC bot that expands references to GitHub issues ' .
      '("#7") and GitHub users ("@jbhotp") to full URLs. I am an instance ' .
      'of ' . blessed($self) . ' ' . VERSION . '. See ' . MANUAL;
}


# connected -- handle a successful connection to a server
sub connected($)
{
  my ($self) = @_;

  $self->join_channel($_) foreach keys %{$self->{joined_channels}};
}


# nickname_in_use_error -- handle a nickname_in_use_error
sub nickname_in_use_error($$)
{
  my ($self, $message) = @_;

  $self->log("Error: $message\n");

  # If the nick length isn't too long already, add an underscore and try again
  if (length($self->nick) < 20) {
    $self->nick($self->nick() . '_');
    $self->connect_server();
  }
  return;
}


# Main body

my (%opts, $ssl, $proto, $user, $password, $host, $port, %passwords, $channel);

$Getopt::Std::STANDARD_HELP_VERSION = 1;
getopts('m:n:N:r:t:v', \%opts) or die "Try --help\n";
die "Usage: $0 [options] [--help] irc[s]://server...\n" if $#ARGV != 0;

# The single argument must be an IRC-URL.
#
($proto, $user, $password, $host, $port, $channel) = $ARGV[0] =~
    /^(ircs?):\/\/(?:([^:]+)(?::([^@]*))?@)?([^:\/#?]+)(?::([^\/]*))?(?:\/(.+)?)?$/i
    or die "Argument must be a URI starting with `irc:' or `ircs:'\n";
$ssl = $proto =~ /^ircs$/i;
$user =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $user;
$password =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $password;
$port //= $ssl ? 6697 : 6667;
$channel =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $channel;
$channel = '#' . $channel if defined $channel && $channel !~ /^[#&]/;

# If there was a ":" after the user but an empty password, prompt for it.
if (defined $password && $password eq '') {
  print "IRC password for user \"$user\": ";
  ReadMode('noecho');
  $password = ReadLine(0);
  ReadMode('restore');
  print "\n";
  chomp $password;
}

my $bot = GHURLBot->new(
  server => $host,
  port => $port,
  ssl => $ssl,
  username => $user,
  password => $password,
  nick => $opts{'n'} // 'ghurlbot',
  name => $opts{'N'} // 'GHURLBot '.VERSION,
  channels => (defined $channel ? [$channel] : []),
  rejoinfile => $opts{'r'},
  mapfile => $opts{'m'} // 'ghurlbot.map',
  github_api_token => $opts{'t'},
  verbose => defined $opts{'v'});

$bot->run();



=encoding utf8

=head1 NAME

ghurlbot - IRC bot that gives the URLs for GitHub issues & users

=head1 SYNOPSIS

ghurlbot [-n I<nick>] [-N I<name>] [-m I<map-file>]
[-r I<rejoin-file>] [-t I<github-api-token>] [-v] I<URL>

=head1 DESCRIPTION

B<ghurlbot> is an IRC bot that replies with a full URL when
somebody mentions a short reference to a GitHub issue or pull request
(e.g., "#73") or to a person or team on GitHub (e.g., "@joeousy").
Example:

 <joe> Let's talk about #13.
 <ghurlbot> -> #13 https://github.com/xxx/yyy/issues/13

B<ghurlbot> can also retrieve a summary of the issue from GitHub, if
it has been given a token (a kind of password) that gives access to
GitHub's API. See the B<-t> option.

The online L<manual|https://w3c.github.io/ghurlbot/manual.html>
explains in detail how to interact with B<ghurlbot> on IRC. The
rest of this manual page only describes how to run the program.

=head2 Specifying the IRC server

The I<URL> argument specifies the server to connect to. It must be of
the following form:

=over

I<protocol>://I<username>:I<password>@I<server>:I<port>/I<channel>

=back

But many parts are optional. The I<protocol> must be either "irc" or
"ircs", the latter for an SSL-encrypted connection.

If the I<username> is omitted, the I<password> and the "@" must also
be omitted. If a I<username> is given, but the I<password> is omitted,
agendabot will prompt for it. (But if both the ":" and the I<password>
are omitted, agendabot assumes that no password is needed.)

The I<server> is required.

If the ":" and the I<port> are omitted, the port defaults to 6667 (for
irc) or 6697 (for ircs).

If a I<channel> is given, agendabot will join that channel (in
addition to any channels it rejoins, see the B<-r> option). If the
I<channel> does not start with a "#" or a "&", agendabot will add a
"#" itself.

Omitting the password is useful to avoid that the password is visible
in the list of running processes or that somebody can read it over
your shoulder while you type the command.

Note that many characters in the username or password must be
URL-escaped. E.g., a "@" must be written as "%40", ":" must be written
as "%3a", "/" as "%2f", etc.

=head1 OPTIONS

=over

=item B<-n> I<nick>

The nickname the bot runs under. Default is "ghurlbot".

=item B<-N> I<name>

The real name of the bot (for the purposes of the \whois command of
IRC). Default is "GHURLBot 0.1".

=item B<-m> I<map-file>

B<ghurlbot> stores its status in a file and restores it from this
file when it starts Default is "ghurlbot.map" in the current
directory.

=item B<-r> I<rejoin-file>

B<ghurlbot> can remember the channels it was on and automatically
rejoin them when it is restarted. By default it does not remember the
channels, but when the B<-r> option is given, it reads a list of
channels from I<rejoin-file> when it starts and tries to join them,
and it updates that file whenever it joins or leaves a channel.

=item B<-t> I<github-api-token>

With this option, B<ghurlbot> will not only print a link to each issue
or pull request, but will also try to print a summary of the issue or
pull request. For that it needs to query GitHub. It does that by
sending HTTP requests to GitHub's GraphQL server, which requires an
access token provided by GitHub. See L<Creating a personal access
token|https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token>.

=item B<-v>

Be verbose. B<ghurlbot> will log what it is doing to standard
error output.

=head1 FILES

=over

=item B<./ghurlbot.map>

The default map file is B<ghurlbot.map> in the directory from
which B<ghurlbot> is started. The map file can be changed with
the B<-m> option. This file contains the status of B<ghurlbot>
and is updated whenever the status changes. It contains for each
channel the currently discussed GitHub repository, whether the
expansion of issues and names to URLs is currently suspended or
active, and how long (how many messages) B<ghurlbot> waits before
expanding the same issue or name again.

If the file is not writable, B<ghurlbot> will continue to
function, but it will obviously not remember its status when it is
rerstarted. In verbose mode (B<-v>) it will write a message to
standard error.

=item I<rejoin-file>

When the B<-r> option is used, B<ghurlbot> reads this file when
it starts and tries to join all channels it contains. It then updates
the file whenever it leaves or joins a channel. The file is a simple
list of channel names, one per line.

If the file is not writable, B<ghurlbot> will function normally,
but will obviously not be able to update the file. In verbose mode
(B<-v>) it will write a message to standard error.

=back

=head1 BUGS

The I<map-file> and I<rejoin-file> only contain channel names, not the
names of IRC networks or IRC servers. B<ghurlbot> cannot check
that the channel names correspond to the IRC server it was started
with.

When B<ghurlbot> is killed in the midst of updating the
I<map-file> or I<rejoin-file>, the file may become corrupted and
prevent the program from restarting.

=head1 AUTHOR

Bert Bos E<lt>bert@w3.org>

=head1 SEE ALSO

L<Online manual|https://w3c.github.io/ghurlbot</manual.html>,
L<scribe.perl|https://w3c.github.io/scribe2/scribedoc.html>.

=cut
