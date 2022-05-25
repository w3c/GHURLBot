#!/usr/bin/env perl
#
# This IRC 'bot expands short references to issues, pull requests,
# persons and teams on GitHub to full URLs. See the perldoc at the end
# for how to run it and manual.html for the interaction on IRC.
#
# TODO: The map-file should contain the IRC network, not just the
# channel names.
#
# TODO: A way to remove a repository from the list for a channel.
#
# TODO: Allow "action-9" as an alternative for "#9"?
#
# TODO: Commands to register mappings of names to GitHub login names.
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
use v5.16;			# Enable fc
use Getopt::Std;
use Scalar::Util 'blessed';
use Term::ReadKey;		# To read a password without echoing
use open qw(:std :encoding(UTF-8)); # Undeclared streams in UTF-8
use File::Temp qw(tempfile tempdir);
use File::Copy;
use LWP;
use LWP::ConnCache;
use JSON::PP;
# use Date::Parse;
use Date::Manip::Date;
use POSIX qw(strftime);

use constant MANUAL => 'https://w3c.github.io/GHURLBot/manual.html';
use constant VERSION => '0.1';
use constant DEFAULT_DELAY => 15;


# init -- initialize some parameters
sub init($)
{
  my $self = shift;
  my $errmsg;

  $self->{delays} = {}; # Maps from a channel to a delay (# of lines)
  $self->{linenumber} = {}; # Maps from a channel to a # of lines seen
  $self->{joined_channels} = {}; # Set of all channels currently joined
  $self->{history} = {}; # Maps a channel to a map of when each ref was expanded
  $self->{suspend_issues} = {}; # Set of channels currently not expanding issues
  $self->{suspend_names} = {}; # Set of channels currently not expanding names
  $self->{repos} = {}; # Maps from a channel to a list of repository URLs

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


# read_mapfile -- read or create the file mapping channels to repositories
sub read_mapfile($)
{
  my $self = shift;

  if (-f $self->{mapfile}) {		# File exists
    $self->log("Reading $self->{mapfile}");
    open my $fh, '<', $self->{mapfile} or return "$self->{mapfile}: $!";
    while (<$fh>) {
      # The mapfile is a tab-separated file with four columns:
      # channel name, repository URL, delay, what
      # where what contains zero, one or both of the words "issues"
      # and "names", to indicate that issues and/or names are to be
      # expanded on that channel. There may be multiple lines for the
      # same channel. The repository is added to the list for that
      # channel. Only the last delay and what for a channel are used.
      my ($channel, $repo, $delay, $what) =
	  $_ =~ /^([^\t]+)\t([^\t]+)\t([0-9]+)\t([^\t]*)\n?$/
	  or return "$self->{mapfile}: wrong syntax";
      push @{$self->{repos}->{$channel}}, $repo;
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


# write_mapfile -- write the current status to file
sub write_mapfile($)
{
  my $self = shift;

  if (open my $fh, '>', $self->{mapfile}) {
    foreach my $channel (keys %{$self->{repos}}) {
      my $what = '';
      $what .= 'issues,' if !defined $self->{suspend_issues}->{$channel};
      $what .= 'names,' if !defined $self->{suspend_names}->{$channel};
      foreach my $repo (@{$self->{repos}->{$channel}}) {
	printf $fh "%s\t%s\t%d\t%s\n", $channel, $repo,
	    $self->{delays}->{$channel} // DEFAULT_DELAY, $what;
      }
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
    $self->rewrite_rejoinfile() if $self->{rejoinfile};
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


# add_repository -- remember the repository $2 for channel $1
sub add_repository($$)
{
  my ($self, $channel, $repository) = @_;
  my @h;

  # Expand the repository to a full URL, if needed.
  $repository =~ s/^ +//;	# Remove any leading spaces
  $repository =~ s/ *+$//;	# Remove any final spaces
  $repository =~ s/\/$//;	# Remove any final slash
  if ($repository !~ m{/}) {	# Only a repository name
    return "sorry, I don't know the owner. Please, use 'OWNER/$repository'"
	if !defined $self->{repos}->{$channel};
    $repository = $self->{repos}->{$channel}->[0] =~ s/[^\/]*$/$repository/r;
  } elsif ($repository =~ m{^[^/]+/[^/]+$}) { # "owner/repository"
    $repository = "https://github.com/$repository";
  } elsif ($repository !~ m{^https://github.com/[^/]+/[^/]+$}) {
    return "sorry, that doesn't look like a valid repository name.";
  }

  # Add $repository at the head of the list of repositories for this
  # channel, or move it to the head, if it was already in the list.
  if (defined $self->{repos}->{$channel}) {
    @h = grep $_ ne $repository, @{$self->{repos}->{$channel}};
  }
  unshift @h, $repository;
  $self->{repos}->{$channel} = \@h;

  $self->write_mapfile();
  $self->{history}->{$channel} = {}; # Forget recently expanded issues

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


# remove_repository -- remove a repository from this channel
sub remove_repository($$$)
{
  my ($self, $channel, $repository) = @_;
  my $repositories = $self->{repos}->{$channel} // [];
  my $found = 0;
  my @h;

  return "sorry, this channel has no repositories." if ! @$repositories;

  # Expand the repository to a full URL, if needed.
  $repository =~ s/^ +//;	# Remove any leading spaces
  $repository =~ s/ *+$//;	# Remove any final spaces
  $repository =~ s/\/$//;	# Remove any final slash
  if ($repository !~ m{/}) {	# Only a repository name
    $repository = $repositories->[0] =~ s/[^\/]*$/$repository/r;
  } elsif ($repository =~ m{^[^/]+/[^/]+$}) { # "owner/repository"
    $repository = "https://github.com/$repository";
  } elsif ($repository !~ m{^https://github.com/[^/]+/[^/]+$}) {
    return "sorry, that doesn't look like a valid repository name.";
  }

  foreach (@$repositories) {
    if ($_ ne $repository) {push @h, $_}
    else {$found = 1}
  }

  return "$repository was already removed." if !$found;

  $self->{repos}->{$channel} = \@h;
  $self->write_mapfile();	     # Write the new list to disk.
  $self->{history}->{$channel} = {}; # Forget recently expanded issues
  return 'OK';
}


# find_repository_for_issue -- expand issue reference to full URL, or undef
sub find_repository_for_issue($$$)
{
  my ($self, $channel, $ref) = @_;
  my ($prefix, $issue, $repos, @matchingrepos);

  ($prefix, $issue) = $ref =~ /^((?:[a-z0-9\/._-]+)?)#([0-9]+)$/i or do {
    $self->log("Bug! wrong argument to find_repository_for_issue()");
    return undef;
  };

  $repos = $self->{repos}->{$channel} // [];

  # First find all repos in our list with the exact name $prefix
  # (with or without an owner part). If there are none, find all
  # repos whose name start with $prefix. E.g., if prefix is "i",
  # it will match repos that have an "i" at the start of the repo
  # name, such as "https://github.com/w3c/i18n" and
  # "https://github.com/foo/ima"; if prefix is "w3c/i" it will
  # match a repo that has "w3c" as owner and a repo name that
  # starts with "i", i.e., it will only match the first of those
  # two; and likewise if prefix is "i18". If prefix is empty, all
  # repos match. (It is important to start with an exact match,
  # otherwise if there two repos "rdf-star" and
  # "rdf-star-wg-charter", you can never get to the former,
  # because it is a prefix of the latter.)
  @matchingrepos = grep $_ =~ /\/\Q$prefix\E$/, @$repos or
      @matchingrepos = grep $_ =~ /\/\Q$prefix\E[^\/]*$/, @$repos;

  # Found one or more repos whose name starts with $prefix:
  return $matchingrepos[0] if @matchingrepos;

  # Did not find a match, but $prefix has a "/", maybe it is a repo name:
  return "https://github.com/$prefix" if $prefix =~ /\//;

  # Use the owner part of the most recent repo:
  return $repos->[0] =~ s/[^\/]*$/$prefix/r if $prefix && scalar @$repos;

  # No recent repo, so we can't guess the owner:
  $self->log("Channel $channel, cannot infer a repository for $ref");
  return undef;
}


# name_to_login -- return the github name for a name, otherwise return the name
sub name_to_login($$)
{
  my ($self, $nick) = @_;

  # TODO.
  return 'bert-github' if fc($nick) eq fc('Bert');
  return $nick;
}


# create_action_process -- process that creates an action item on GitHub
sub create_action_process($$$$$$)
{
  my ($body, $self, $channel, $repository, $names, $text) = @_;
  my (@names, $res, $content, $date, $due);

  # Creating an action item is like creating an issue, but with
  # assignees and a label "action".

  $repository =~ s/^https:\/\/github.com\///;
  @names = map($self->name_to_login($_), split(/ *, */, $names));

  $date = new Date::Manip::Date;
  if ($text =~ /^(.*?)(?: *- *| +)due +(.*?)[. ]*$/i && $date->parse($2) == 0) {
    $text = $1;
  } else {
    $date->parse("next week");	# Default to 1 week
  }
  $due = $date->printf("%e %b %Y");

  $res = $self->{ua}->post(
    "https://api.github.com/repos/$repository/issues",
    Content => encode_json({title => $text, assignees => \@names,
			    body => "due $due", labels => ['action']}));

  print STDERR "Channel $channel new action \"$text\" in $repository -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot create action. Forbidden.\n";
  } elsif ($res->code == 404) {
    print "Cannot create action. Repository not found.\n";
  } elsif ($res->code == 410) {
    print "Cannot create action. Repository is gone.\n";
  } elsif ($res->code == 422) {
    print "Cannot create action. Validation failed. (Invalid user for this repository?)\n";
  } elsif ($res->code == 503) {
    print "Cannot create action. Service unavailable.\n";
  } elsif ($res->code != 201) {
    print "Cannot create action. Error ".$res->code."\n";
  } else {
    $content = decode_json($res->decoded_content);
    @names = ();
    push @names, $_->{login} foreach @{$content->{assignees}};
    print "Created $content->{html_url} -> action $content->{number}",
	" $content->{title} (on ", join(', ', @names), ") due $due\n";
  }
}


# create_action -- create a new action item
sub create_action($$$)
{
  my ($self, $channel, $names, $text) = @_;

  return "Sorry, I don't know what repository to use."
      if !defined $self->{repos}->{$channel} ||
      scalar @{$self->{repos}->{$channel}} == 0;

  $self->forkit(
    {run => \&create_action_process, channel => $channel,
     arguments => [$self, $channel, $self->{repos}->{$channel}->[0], $names,
       $text]});

  return undef;			# The forked process will print a result
}


# create_issue_process -- process that creates an issue on GitHub
sub create_issue_process($$$$)
{
  my ($body, $self, $channel, $repository, $text) = @_;
  my ($res, $content);

  $repository =~ s/^https:\/\/github.com\///;
  $res = $self->{ua}->post(
    "https://api.github.com/repos/$repository/issues",
    Content => encode_json({title => $text}));

  print STDERR "Channel $channel new issue \"$text\" in $repository -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot create issue. Forbidden.\n";
  } elsif ($res->code == 404) {
    print "Cannot create issue. Repository not found.\n";
  } elsif ($res->code == 410) {
    print "Cannot create issue. Repository is gone.\n";
  } elsif ($res->code == 422) {
    print "Cannot create issue. Validation failed.\n";
  } elsif ($res->code == 503) {
    print "Cannot create issue. Service unavailable.\n";
  } elsif ($res->code != 201) {
    print "Cannot create issue. Error ".$res->code."\n";
  } else {
    $content = decode_json($res->decoded_content);
    print "Created $content->{html_url} -> issue $content->{number}",
	" $content->{title}\n";
  }
}


# create_issue -- create a new issue
sub create_issue($$$)
{
  my ($self, $channel, $text) = @_;

  return "Sorry, I don't know what repository to use."
      if !defined $self->{repos}->{$channel} ||
      scalar @{$self->{repos}->{$channel}} == 0;

  $self->forkit(
    {run => \&create_issue_process, channel => $channel,
     arguments => [$self, $channel, $self->{repos}->{$channel}->[0], $text]});

  return undef;			# The forked process will print a result
}


# close_issue_process -- process that closes an issue on GitHub
sub close_issue_process($$$$$)
{
  my ($body, $self, $channel, $repository, $text) = @_;
  my ($res, $content, $issuenumber);

  ($issuenumber) = $text =~ /#(.*)/; # Just the number
  $repository =~ s/^https:\/\/github.com\///;
  $res = $self->{ua}->patch(
    "https://api.github.com/repos/$repository/issues/$issuenumber",
    Content => encode_json({state => 'closed'}));

  print STDERR "Channel $channel close $repository#$issuenumber -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot close issue $text. Forbidden.\n";
  } elsif ($res->code == 404) {
    print "Cannot close issue $text. Issue not found.\n";
  } elsif ($res->code == 410) {
    print "Cannot close issue $text. Issue is gone.\n";
  } elsif ($res->code == 422) {
    print "Cannot close issue $text. Validation failed.\n";
  } elsif ($res->code == 503) {
    print "Cannot close issue $text. Service unavailable.\n";
  } elsif ($res->code != 200) {
    print "Cannot close issue $text. Error ".$res->code."\n";
  } else {
    $content = decode_json($res->decoded_content);
    if (grep($_->{name} eq 'action', @{$content->{labels}})) {
      print "Closed $content->{html_url} -> action $content->{number}",
	  " $content->{title} (on ",
	  join(', ', map($_->{login}, @{$content->{assignees}})), ")\n";
    } else {
      print "Closed $content->{html_url} -> issue $content->{number} ".
	  "$content->{title}\n";
    }
  }
}


# close_issue -- close an issue
sub close_issue($$$)
{
  my ($self, $channel, $text) = @_;
  my $repository;

  $repository = $self->find_repository_for_issue($channel, $text) or
      return "Sorry, I don't know what repository to use for $text";

  $self->forkit(
    {run => \&close_issue_process, channel => $channel,
     arguments => [$self, $channel, $repository, $text]});

  return undef;			# The forked process will print a result
}


# reopen_issue_process -- process that reopens an issue on GitHub
sub reopen_issue_process($$$$)
{
  my ($body, $self, $channel, $repository, $text) = @_;
  my ($res, $content, $issuenumber, $comment);

  ($issuenumber) = $text =~ /#(.*)/; # Just the number
  $repository =~ s/^https:\/\/github.com\///;
  $res = $self->{ua}->patch(
    "https://api.github.com/repos/$repository/issues/$issuenumber",
    Content => encode_json({state => 'open'}));

  print STDERR "Channel $channel reopen $repository#$issuenumber -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot reopen issue $text. Forbidden.\n";
  } elsif ($res->code == 404) {
    print "Cannot reopen issue $text. Issue not found.\n";
  } elsif ($res->code == 410) {
    print "Cannot reopen issue $text. Issue is gone.\n";
  } elsif ($res->code == 422) {
    print "Cannot reopen issue $text. Validation failed.\n";
  } elsif ($res->code == 503) {
    print "Cannot reopen issue $text. Service unavailable.\n";
  } elsif ($res->code != 200) {
    print "Cannot reopen issue $text. Error ".$res->code."\n";
  } else {
    $content = decode_json($res->decoded_content);
    if (grep($_->{name} eq 'action', @{$content->{labels}})) {
      $comment = /(^due  ?[1-9].*)/ ? " $1" : "" for $content->{body} // '';
      print "Reopened $content->{html_url} -> action $content->{number} ",
	  "$content->{title} (on ",
	  join(', ', map($_->{login}, @{$content->{assignees}})),
	  ")$comment\n";
    } else {
      print "Reopened $content->{html_url} -> issue $content->{number} ",
	  "$content->{title}\n";
    }
  }
}


# reopen_issue -- reopen an issue
sub reopen_issue($$$)
{
  my ($self, $channel, $text) = @_;
  my $repository;

  $repository = $self->find_repository_for_issue($channel, $text) or
      return "Sorry, I don't know what repository to use for $text";

  $self->forkit(
    {run => \&reopen_issue_process, channel => $channel,
     arguments => [$self, $channel, $repository, $text]});

  return undef;			# The forked process will print a result
}


# account_info_process -- process that looks up the GitHub account we are using
sub account_info_process($$$)
{
  my ($body, $self, $channel) = @_;
  my ($res, $content, $issuenumber);

  $res = $self->{ua}->get("https://api.github.com/user",
    'Accept' => 'application/vnd.github.v3+json');

  print STDERR "Channel $channel user account -> ", $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot read account. Forbidden.\n";
  } elsif ($res->code == 404) {
    print "Cannot read account. Account not found.\n";
  } elsif ($res->code == 410) {
    print "Cannot read account. Account is gone.\n";
  } elsif ($res->code == 422) {
    print "Cannot read account. Validation failed.\n";
  } elsif ($res->code == 503) {
    print "Cannot read account. Service unavailable.\n";
  } elsif ($res->code != 200) {
    print "Cannot read account. Error ".$res->code."\n";
  } else {
    $content = decode_json($res->decoded_content);
    print "I am using GitHub login ", $content->{login}, "\n";
  }
}


# account -- get info about the GitHub account, if any, that the bot runs under
sub account_info($$)
{
  my ($self, $channel) = @_;

  return "I am not using a GitHub account." if !$self->{github_api_token};

  $self->forkit(
    {run => \&account_info_process, channel => $channel,
     arguments => [$self, $channel]});
  return undef;		     # The forked process willl print a result
}


# get_issue_summary_process -- try to retrieve info about an issue/pull request
sub get_issue_summary_process($$$$)
{
  my ($body, $self, $channel, $repository, $issue) = @_;
  my ($owner, $repo, $res, $ref, $comment);

  # This is not a method, but a function that is called by forkit() to
  # run as a background process. It prints text for the channel to
  # STDOUT and log entries to STDERR.

  if (!defined $self->{ua}) {
    print "$repository/issues/$issue -> \#$issue\n";
    return;
  }

  ($owner, $repo) = $repository =~ /([^\/]+)\/([^\/]+)$/;

  $res = $self->{ua}->get(
    "https://api.github.com/repos/$owner/$repo/issues/$issue",
    'Accept' => 'application/vnd.github.v3+json');

  print STDERR "Channel $channel info $repository#$issue -> ",$res->code,"\n";

  if ($res->code == 404) {
    print "$repository/issues/$issue -> Issue $issue [not found]\n";
    return;
  } elsif ($res->code == 410) {
    print "$repository/issues/$issue -> Issue $issue [gone]\n";
    return;
  } elsif ($res->code != 200) {	# 401 (wrong auth) or 403 (rate limit)
    print STDERR "  ", $res->decoded_content, "\n";
    print "$repository/issues/$issue -> \#$issue\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  if (grep($_->{name} eq 'action', @{$ref->{labels}})) {
    $comment = /(^due  ?[1-9].*)/ ? " $1" : "" for $ref->{body} // '';
    print "$repository/issues/$issue -> Action $issue ",
	($ref->{state} eq 'closed' ? '[closed] ' : ''),	"$ref->{title} (on ",
	join(', ', map($_->{login}, @{$ref->{assignees}})), ")$comment\n";
  } else {
    print "$repository/issues/$issue -> ",
	($ref->{pull_request} ? 'Pull Request' : 'Issue'), " $issue ",
	($ref->{state} eq 'closed' ? '[closed] ' : ''),
	"$ref->{title} ($ref->{user}->{login})",
	join(',', map(" $_->{name}", @{$ref->{labels}})), "\n";
  }
}


# maybe_expand_references -- return URLs for the issues and names in $text
sub maybe_expand_references($$$$)
{
  my ($self, $text, $channel, $addressed) = @_;
  my ($linenr, $delay, $do_issues, $do_names, $response, $repository);

  $linenr = $self->{linenumber}->{$channel};		    # Current line#
  $delay = $self->{delays}->{$channel} // DEFAULT_DELAY;
  $do_issues = !defined $self->{suspend_issues}->{$channel};
  $do_names = !defined $self->{suspend_names}->{$channel};
  $response = '';

  # Look for #number, prefix#number and @name.
  while ($text =~ /(?:^|\W)\K(([a-zA-Z0-9\/._-]*)#([0-9]+)|@([\w-]+))(?=\W|$)/g) {
    my ($ref, $prefix, $issue, $name) = ($1, $2, $3, $4);
    my $previous = $self->{history}->{$channel}->{$ref} // -$delay;

    if ($ref !~ /^@/		# It's a reference to an issue.
      && ($addressed || ($do_issues && $linenr > $previous + $delay))) {
      $repository = $self->find_repository_for_issue($channel, $ref) or do {
	$self->log("Channel $channel, cannot infer a repository for $ref");
	next;
      };
      # $self->log("Channel $channel $repository/issues/$issue");
      $self->forkit({run => \&get_issue_summary_process, channel => $channel,
		     arguments => [$self, $channel, $repository, $issue]});
      $self->{history}->{$channel}->{$ref} = $linenr;

    } elsif ($ref =~ /@/		# It's a reference to a GitHub user name
      && ($addressed || ($do_names && $linenr > $previous + $delay))) {
      $self->log("Channel $channel name https://github.com/$name");
      $response .= "https://github.com/$name -> \@$name\n";
      $self->{history}->{$channel}->{$ref} = $linenr;

    } else {
      $self->log("Channel $channel, skipping $ref");
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
  my $repositories = $self->{repos}->{$channel};
  my $s = '';

  $s .= 'the delay is ' . ($self->{delays}->{$channel} // DEFAULT_DELAY);
  $s .= ', issues are ' . ($self->{suspend_issues}->{$channel} ? 'off' : 'on');
  $s .= ', names are ' . ($self->{suspend_names}->{$channel} ? 'off' : 'on');

  if (!defined $repositories || scalar @$repositories == 0) {
    $s .= ' and no repositories are specified.';
  } elsif (scalar @$repositories == 1) {
    $s .= ' and the repository is ' . $repositories->[0];
  } else {
    $s .= ' and the repositories are ' . join(' ', @$repositories);
  }
  return $s;
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
  my $do_issues = !defined $self->{suspend_issues}->{$channel};

  return if $channel eq 'msg';		# We do not react to private messages

  $self->{linenumber}->{$channel}++;

  return $self->part_channel($channel), undef
      if $addressed && $text =~ /^ *bye *\.? *$/i;

  return $self->add_repository($channel, $1)
      if $addressed &&
      $text =~ /^ *(?:discussing|discuss|use|using|take +up|taking +up|this +will +be|this +is) +([^ ]+) *$/i;

  return $self->remove_repository($channel, $1)
      if $addressed &&
      $text =~ /^ *(?:forget|drop|remove|don't +use|do +not +use) +([^ ]+) *$/;

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

  return $self->create_issue($channel, $1)
      if ($addressed || $do_issues) && $text =~ /^ *issue *: *(.*)$/i;

  return $self->close_issue($channel, $1)
      if ($addressed || $do_issues) &&
      ($text =~ /^ *close +([a-zA-Z0-9\/._-]*#[0-9]+)(?=\W|$)/i ||
	$text =~ /^ *([a-zA-Z0-9\/._-]*#[0-9]+) +closed *$/i);

  return $self->reopen_issue($channel, $1)
      if ($addressed || $do_issues) &&
      ($text =~ /^ *reopen +([a-zA-Z0-9\/._-]*#[0-9]+)(?=\W|$)/i ||
         $text =~ /^ *([a-zA-Z0-9\/._-]*#[0-9]+) +reopened *$/i);

  return $self->create_action($channel, $1, $2)
      if ($addressed || $do_issues) &&
      ($text =~ /^ *action +([^:]+?) *: *(.*?) *$/i ||
	$text =~ /^ *action *: *(.*?) +to +(.*?) *$/i);

  return $self->account_info($channel)
      if $addressed &&
      $text =~ /^ *(?:who +are +you|account|user|login) *\?? *$/i;

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


# log -- print a message to STDERR, but only if -v (verbose) was specified
sub log
{
  my ($self, @messages) = @_;

  if ($self->{'verbose'}) {
    # Prefix all log lines with the current time, unless the line
    # already starts with a time.
    #
    my $now = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;
    $self->SUPER::log(
      map /^\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ/ ? $_ : "$now $_", @messages);
  }
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
sending HTTP requests to GitHub's API server, which requires an
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
