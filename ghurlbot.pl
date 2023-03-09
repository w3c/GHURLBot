#!/usr/bin/env perl
#
# This IRC 'bot expands short references to issues, pull requests,
# persons and teams on GitHub to full URLs. See the perldoc at the end
# for how to run it and manual.html for the interaction on IRC.
#
# TODO: The map-file should contain the IRC network, not just the
# channel names.
#
# TODO: Allow "action-9" as an alternative for "#9"?
#
# TODO: Add a permission system to limit who can create, close or
# reopen issues? (Maybe people on IRC can somehow prove to ghurlbot
# that they have a GitHub account and maybe ghurlbot can find out if
# that account has the right to close an issue?)
#
# TODO: A way to ask for the github login of a given nick? Or to ask
# for all known aliases?
#
# TODO: Lock the mapfile, to avoid damage if another instance of
# ghurlbot is using the same file?
#
# TODO: Should all responses from the bot other than expanded
# references be emoted ("/me")?
#
# TODO: Get plain text instead of markdown from GitHub? (Requires
# setting the Accept header to "application/vnd.github.text+json" and
# using the "body_text" field instead of "body" from the returned
# JSON.)
#
# TODO: When listing issues and the result has 100 items, check if
# there are more and if so, say so on IRC.
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
use utf8;
use v5.16;			# Enable fc
use Getopt::Std;
use Scalar::Util 'blessed';
use Term::ReadKey;		# To read a password without echoing
use open qw(:std :encoding(UTF-8)); # Undeclared streams in UTF-8
use File::Temp qw(tempfile tempdir);
use File::Copy;
use LWP;
use LWP::ConnCache;
# use JSON::PP;
use JSON;
use Date::Manip::Date;
use Date::Manip::Delta;
use POSIX qw(strftime);
use Net::Netrc;
use Encode qw(str2bytes bytes2str);

use constant MANUAL => 'https://w3c.github.io/GHURLBot/manual.html';
use constant VERSION => '0.3';
use constant DEFAULT_DELAY => 15;

# GitHub limits requests to 5000 per hour per authenticated app (and
# will return 403 if the limit is exceeded). We impose an extra limit
# of 100 changes to a given repository in 10 minutes.
use constant MAXRATE => 100;
use constant RATEPERIOD => 10;


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
      'Authorization' => 'token ' . $self->{github_api_token});
  }

  $errmsg = $self->read_rejoin_list() and die "$errmsg\n";
  $errmsg = $self->read_mapfile() and die "$errmsg\n";

  $self->log("Connecting...");
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
  my $channel;

  if (-f $self->{mapfile}) {		# File exists
    $self->log("Reading $self->{mapfile}");
    open my $fh, '<', $self->{mapfile} or return "$self->{mapfile}: $!";
    while (<$fh>) {
      # Empty lines and line that start with "#" are ignored. Other
      # lines must start with a keyword:
      #
      # alias NAME GITHUB-NAME
      #   When an action is assigned to NAME, use GITHUB-NAME instead.
      # channel CHANNEL
      #   Lines up to the next "channel" apply to CHANNEL.
      # repo REPO
      #   Add REPO to the list of repositories for the current CHANNEL.
      # delay NN
      #   Set the delay for CHANNEL to NN.
      # issues off
      #   Do not expand issue references on CHANNEL.
      # names off
      #   Do not expand name references on CHANNEL.
      # ignore NAME
      #   Ignore commands that open/close issues when they come from NAME.
      chomp;
      if ($_ =~ /^#/) {
	# Comment, ignored.
      } elsif ($_ =~ /^\s*$/) {
	# Empty line, ignored.
      } elsif ($_ =~ /^\s*alias\s+([^\s]+)\s+([^\s]+)\s*$/) {
	$self->{github_names}->{fc $1} = $2;
      } elsif ($_ =~ /^\s*channel\s+([^\s]+)\s*$/) {
	$channel = $1;
      } elsif (! defined $channel) {
	return "$self->{mapfile}:$.: missing \"channel\" line";
      } elsif ($_ =~ /^\s*repo\s+([^\s]+)\s*$/) {
	push @{$self->{repos}->{$channel}}, $1;
      } elsif ($_ =~ /^\s*delay\s+([0-9]+)\s*$/) {
	$self->{delays}->{$channel} = 0 + $1;
      } elsif ($_ =~ /\s*issues\s+off\s*$/) {
	$self->{suspend_issues}->{$channel} = 1;
      } elsif ($_ =~ /\s*names\s+off\s*$/) {
	$self->{suspend_names}->{$channel} = 1;
      } elsif ($_ =~ /\s*ignore\s+([^\s]+)\s*$/) {
	$self->{ignored_nicks}->{$channel}->{fc $1} = $1;
      } else {
	return "$self->{mapfile}:$.: wrong syntax";
      }
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
    foreach my $channel (keys %{$self->{linenumber}}) {
      printf $fh "channel %s\n", $channel;
      printf $fh "repo %s\n", $_ for @{$self->{repos}->{$channel}};
      printf $fh "delay %d\n", $self->{delays}->{$channel} // DEFAULT_DELAY;
      printf $fh "issues off\n" if $self->{suspend_issues}->{$channel};
      printf $fh "names off\n" if $self->{suspend_names}->{$channel};
      printf $fh "ignore %s\n", $_ for values %{$self->{ignored_nicks}->{$channel}};
      printf $fh "\n";
    }
    foreach my $nick (keys %{$self->{github_names}}) {
      printf $fh "alias %s %s\n", $nick, $self->{github_names}->{$nick};
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


# repository_to_url -- expand a repository name to a full URL, or return error
sub repository_to_url($$$)
{
  my ($self, $channel, $repo) = @_;

  my ($base, $owner, $name) = $repo =~
      /^([a-z]+:\/\/(?:[^\/?\#]*\/)*?)?([^\/?\#]+\/)?([^\/?\#]+)\/?$/i;

  return ($repo, undef)
      if $base;			# It's already a full URL
  return (defined $self->{repos}->{$channel}->[0] ?
    $self->{repos}->{$channel}->[0] =~ s/[^\/]+\/[^\/]+$/$owner$name/r :
    "https://github.com/$owner$name", undef)
      if $owner;
  return (undef, "sorry, that doesn't look like a valid repository: $repo")
      if ! $name;
  return ("https://github.com/w3c/$name", undef)
      # or: (undef,"sorry, I don't know the owner. Please, use 'OWNER/$name'")
      if ! defined $self->{repos}->{$channel};
  return ($self->{repos}->{$channel}->[0] =~ s/[^\/]+$/$name/r, undef);
}


# add_repositories -- remember the repositories $2 for channel $1
sub add_repositories($$$)
{
  my ($self, $channel, $repos) = @_;
  my $err = '';
  my @h;

  foreach (split /[ ,]+/, $repos) {
    my ($repository, $msg) = $self->repository_to_url($channel, $_);

    if ($msg) {
      $err .= "$msg\n";
    } else {
      # Add $repository at the head of the list of repositories for this
      # channel, or move it to the head, if it was already in the list.
      if (defined $self->{repos}->{$channel}) {
	@h = grep $_ ne $repository, @{$self->{repos}->{$channel}};
      }
      unshift @h, $repository;
      $self->{repos}->{$channel} = \@h;
    }
  }
  $self->write_mapfile();
  $self->{history}->{$channel} = {}; # Forget recently expanded issues

  return $err if $err;
  return "OK. But note that I am not currently expanding issues. " .
      "You can change that with: ".$self->nick()." issues on"
      if defined $self->{suspend_issues}->{$channel};
  return 'OK.';
}


# remove_repositories -- remove one or more repositories from this channel
sub remove_repositories($$$)
{
  my ($self, $channel, $repos) = @_;
  my $err = '';
  my $found = 0;

  return "sorry, this channel has no repositories."
      if scalar @{$self->{repos}->{$channel}} == 0;

  foreach my $repo (split /[ ,]+/, $repos) {
    my @x = grep /(?:^|\/)\Q$repo\E$/, @{$self->{repos}->{$channel}};
    if (scalar @x) {
      my @h = grep $_ ne $x[0], @{$self->{repos}->{$channel}};
      $self->{repos}->{$channel} = \@h;
      $found = 1;
    } else {
      $err .= "$repo was already removed.\n";
    }
  }
  $self->write_mapfile() if $found;	# Write the new list to disk.
  $self->{history}->{$channel} = {};	# Forget recently expanded issues
  return $err ? $err : 'OK.';
}


# clear_repositories -- forget all repositories for a channel
sub clear_repositories($$)
{
  my ($self, $channel) = @_;
  delete $self->{repos}->{$channel};
  return 'OK.';
}


# find_matching_repository -- return the repository that matches $prefix
sub find_matching_repository($$$)
{
  my ($self, $channel, $prefix) = @_;
  my ($repos, @matchingrepos);

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
  @matchingrepos = grep $_ =~ /\/\Q$prefix\E$/i, @$repos or
      @matchingrepos = grep $_ =~ /\/\Q$prefix\E[^\/]*$/i, @$repos;

  # Found one or more repos whose name starts with $prefix:
  return $matchingrepos[0] if @matchingrepos;

  # Did not find a match, but $prefix has a "/", maybe it is a repo name:
  return "https://github.com/$prefix" if $prefix =~ /\//;

  # Use the owner part of the most recent repo:
  return $repos->[0] =~ s/[^\/]*$/$prefix/r if $prefix && scalar @$repos;

  # No recent repo, so we can't guess the owner:
  return undef;
}


# find_repository_for_issue -- expand issue reference to full URL, or undef
sub find_repository_for_issue($$$)
{
  my ($self, $channel, $ref) = @_;

  my ($prefix, $issue) = $ref =~ /^([a-z0-9\/._-]*)#([0-9]+)$/i or
      $self->log("Bug! wrong argument to find_repository_for_issue()") and
      return undef;

  return $self->find_matching_repository($channel, $prefix);
}

# name_to_login -- return the github name for a name, otherwise return the name
sub name_to_login($$)
{
  my ($self, $nick) = @_;

  return $1 if $nick =~ /^@(.*)/; # A name prefixed with "@" is a GitHub login
  return $self->{github_names}->{fc $nick} // $nick;
}


# check_and_update_rate -- false if the rate is already too high, or update it
sub check_and_update_rate($$)
{
  my ($self, $repository) = @_;
  my $now = time;

  if (($self->{ratestart}->{$repository} // 0) < $now - 60 * RATEPERIOD) {
    # No rate period for this repository started, or it started more
    # than RATEPERIOD minutes ago. Start a new period, count one
    # action, and return OK.
    $self->{ratestart}->{$repository} = $now;
    $self->{rate}->{$repository} = 1;
    return 1;
  } elsif (($self->{rate}->{$repository} // 0) < MAXRATE) {
    # The current rate period started less than RATEPERIOD minutes
    # ago, but we have done less than MAXRATE actions in this period.
    # Increase the number of actions by one and return OK.
    $self->{rate}->{$repository}++;
    return 1;
  } else {
    # The current rate period started less than RATEPERIOD minutes ago
    # and we have already done MAXRATE actions in this period. So
    # return FAIL.
    $self->log("Rate limit reached for $repository");
    return 0;
  }
}


# create_action_process -- process that creates an action item on GitHub
sub create_action_process($$$$$$)
{
  my ($body, $self, $channel, $repository, $names, $text) = @_;
  my (@names, @labels, $res, $content, $date, $due, $today);

  # Creating an action item is like creating an issue, but with
  # assignees and a label "action".

  $repository =~ s/^https:\/\/github\.com\///i or
      print "Cannot create actions on $repository as it is not on github.com.\n"
      and return;

  @names = map($self->name_to_login($_), split(/ *, */, $names));

  $today = new Date::Manip::Date;
  $today->parse("today");

  $date = new Date::Manip::Date;
  if ($text =~ /^(.*?)(?: *- *| +)due +(.*?)[. ]*$/i && $date->parse($2) == 0) {
    $text = $1;
  } else {
    $date->parse("next week");	# Default to 1 week
  }

  # When a due date is in the past, adjust the year and print a warning.
  if ($today->cmp($date) > 0) {
    my $delta = new Date::Manip::Delta;
    $delta->parse("+1 year");
    $date = $date->calc($delta) until $date->cmp($today) >= 0;
    print "Assumed the due date is in ", $date->printf("%Y"), "\n";
  }

  $due = $date->printf("%e %b %Y");

  $res = $self->{ua}->post(
    "https://api.github.com/repos/$repository/issues",
    Content => encode_json({title => $text, assignees => \@names,
			    body => "due $due", labels => ['action']}));

  print STDERR "Channel $channel, new action \"$text\" in $repository -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot create action. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "Cannot create action. Insufficient or expired authorization.\n";
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
    # Issues created. Check that label and assignees were also added.
    $content = decode_json($res->decoded_content);
    my %n; $n{fc $_->{login}} = 1 foreach @{$content->{assignees}};
    @names = grep !exists $n{fc $_}, @names; # Remove names that were assigned
    if (! @{$content->{labels}}) {
      print "I created -> issue #$content->{number} $content->{html_url}\n",
	  "but I could not add the \"action\" label.\n",
	  "That probably means I don't have push permission on $repository.\n";
    } elsif (@names) {		# Some names were not assigned
      print "I created -> action #$content->{number} $content->{html_url}\n",
	  "but I could not assign it to ", join(", ", @names), "\n",
	  "They probably aren't collaborators on $repository.\n";
    } else {
      print "Created -> action #$content->{number} $content->{html_url}\n";
    }
  }
}


# create_action -- create a new action item
sub create_action($$$)
{
  my ($self, $channel, $names, $text) = @_;
  my $repository;

  $repository = $self->{repos}->{$channel}->[0] or
      return "Sorry, I don't know what repository to use.";

  $self->check_and_update_rate($repository) or
      return "Sorry, for security reasons, I won't touch a repository more ".
      "than ".MAXRATE." times in ".RATEPERIOD." minutes. ".
      "Please, try again later.";

  $self->forkit(
    {run => \&create_action_process, channel => $channel,
     arguments => [$self, $channel, $repository, $names, $text]});

  return undef;			# The forked process will print a result
}


# create_issue_process -- process that creates an issue on GitHub
sub create_issue_process($$$$)
{
  my ($body, $self, $channel, $repository, $text) = @_;
  my ($res, $content);

  $repository =~ s/^https:\/\/github\.com\///i or
      print "Cannot create issues on $repository as it is not on github.com.\n"
      and return;

  $res = $self->{ua}->post(
    "https://api.github.com/repos/$repository/issues",
    Content => encode_json({title => $text}));

  print STDERR "Channel $channel, new issue \"$text\" in $repository -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot create issue. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "Cannot create issue. Insufficient or expired authorization.\n";
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
    print "Created -> issue #$content->{number} $content->{html_url}",
	" $content->{title}\n";
  }
}


# create_issue -- create a new issue
sub create_issue($$$)
{
  my ($self, $channel, $text) = @_;
  my $repository;

  $repository = $self->{repos}->{$channel}->[0] or
      return "Sorry, I don't know what repository to use.";

  $self->check_and_update_rate($repository) or
      return "Sorry, for security reasons, I won't touch a repository more than ".MAXRATE.
      " times in ".RATEPERIOD." minutes. Please, try again later.";

  $self->forkit(
    {run => \&create_issue_process, channel => $channel,
     arguments => [$self, $channel, $repository, $text]});

  return undef;			# The forked process will print a result
}


# close_issue_process -- process that closes an issue on GitHub
sub close_issue_process($$$$$)
{
  my ($body, $self, $channel, $repository, $text) = @_;
  my ($res, $content, $issuenumber);

  ($issuenumber) = $text =~ /#(.*)/; # Just the number
  $repository =~ s/^https:\/\/github\.com\///i  or
      print "Cannot close issues on $repository as it is not on github.com.\n"
      and return;
  $res = $self->{ua}->patch(
    "https://api.github.com/repos/$repository/issues/$issuenumber",
    Content => encode_json({state => 'closed'}));

  print STDERR "Channel $channel, close $repository#$issuenumber -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot close issue $text. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "Cannot close issue. Insufficient or expired authorization.\n";
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
      print "Closed -> action #$content->{number} $content->{html_url}\n";
    } else {
      print "Closed -> issue #$content->{number} $content->{html_url}\n";
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

  $self->check_and_update_rate($repository) or
      return "Sorry, for security reasons, I won't touch a repository more than ".MAXRATE.
      " times in ".RATEPERIOD." minutes. Please, try again later.";

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
  $repository =~ s/^https:\/\/github\.com\///i  or
      print "Cannot open issuess on $repository as it is not on github.com.\n"
      and return;
  $res = $self->{ua}->patch(
    "https://api.github.com/repos/$repository/issues/$issuenumber",
    Content => encode_json({state => 'open'}));

  print STDERR "Channel $channel, reopen $repository#$issuenumber -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot reopen issue $text. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "Cannot reopen issue. Insufficient or expired authorization.\n";
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
      print "Reopened -> action #$content->{number} $content->{html_url} ",
	  "$content->{title} (on ",
	  join(', ', map($_->{login}, @{$content->{assignees}})),
	  ")$comment\n";
    } else {
      print "Reopened -> issue #$content->{number} $content->{html_url} ",
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

  $self->check_and_update_rate($repository) or
      return "Sorry, for security reasons, I won't touch a repository more than ".MAXRATE.
      " times in ".RATEPERIOD." minutes. Please, try again later.";

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
    'Accept' => 'application/json');

  print STDERR "Channel $channel, user account -> ", $res->code, "\n";

  if ($res->code == 403) {
    print "Cannot read account. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "Cannot read account. Insufficient or expired authorization.\n";
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

  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      print "$repository/issues/$issue -> \#$issue\n" and
      return;

  $res = $self->{ua}->get(
    "https://api.github.com/repos/$owner/$repo/issues/$issue",
    'Accept' => 'application/json');

  print STDERR "Channel $channel, info $repository#$issue -> ",$res->code,"\n";

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
	$response .= "I don't know which repository to use for $ref\n"
	    if $addressed;
	next;
      };
      # $self->log("Channel $channel $repository/issues/$issue");
      $self->forkit({run => \&get_issue_summary_process, channel => $channel,
		     arguments => [$self, $channel, $repository, $issue]});
      $self->{history}->{$channel}->{$ref} = $linenr;

    } elsif ($ref =~ /@/		# It's a reference to a GitHub user name
      && ($addressed || ($do_names && $linenr > $previous + $delay))) {
      $self->log("Channel $channel, name https://github.com/$name");
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
  return 'OK.';
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

  my $t = join ', ', values %{$self->{ignored_nicks}->{$channel}};
  $t =~ s/(.*),/$1 and/;	# Replace the last ",", if any, by "and"
  $s .= ", commands are ignored from $t" if $t ne '';

  if (!defined $repositories || scalar @$repositories == 0) {
    $s .= '; and no repositories are specified.';
  } elsif (scalar @$repositories == 1) {
    $s .= '; and the repository is ' . $repositories->[0];
  } else {
    $s .= '; and the repositories are ' . join(' ', @$repositories);
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
  return 'OK.';
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
  return 'OK.';
}


# set_suspend_all -- set both suspend_issues and suspend_names
sub set_suspend_all($$$)
{
  my ($self, $channel, $on) = @_;
  my $msg;

  $msg = $self->set_suspend_issues($channel, $on);
  $msg = $msg eq 'OK.' ? '' : "$msg\n";
  return $msg . $self->set_suspend_names($channel, $on);
}


# is_ignored_nick - check if commands from $who should be ignored on $channel
sub is_ignored_nick($$$)
{
  my ($self, $channel, $who) = @_;

  return defined $self->{ignored_nicks}->{$channel}->{fc $who};
}


# add_ignored_nicks -- add one or more nicks to the ignore list on $channel
sub add_ignored_nicks($$$)
{
  my ($self, $channel, $nicks) = @_;
  my $reply = '';

  return 'you need to give one or more IRC nicks after "ignore".'
      if $nicks eq '';

  for my $who (split /[ ,]+/, $nicks) {
    if (defined $self->{ignored_nicks}->{$channel}->{fc $who}) {
      $reply .= "$who was already ignored on this channel.\n"
    } else {
      $self->{ignored_nicks}->{$channel}->{fc $who} = $who;
    }
  }
  $self->write_mapfile();
  return $reply || 'OK';
}


# remove_ignored_nicks -- remove nicks from the ignore list on $channel
sub remove_ignored_nicks($$$)
{
  my ($self, $channel, $nicks) = @_;
  my $reply = "You need to give one or more IRC nicks after \"ignore\".";

  for my $who (split /[ ,]+/, $nicks) {
    if (!defined $self->{ignored_nicks}->{$channel}->{fc $who}) {
      $self->say({channel => $channel,
		  body => "$who was not ignored on this channel."});
    } else {
      delete $self->{ignored_nicks}->{$channel}->{fc $who};
    }
    $reply = "OK."
  }
  $self->write_mapfile();
  return $reply;
}


# set_github_alias -- remember or forget the github login for a given nick
sub set_github_alias($$$)
{
  my ($self, $who, $github_login) = @_;

  if (fc $who eq fc $github_login) {
    return "I already had that GitHub account for $who"
	if !defined $self->{github_names}->{fc $who};
    delete $self->{github_names}->{fc $who};
  } else {
    return "I already had that GitHub account for $who"
	if fc $self->{github_names}->{fc $who} eq fc $github_login;
    $self->{github_names}->{fc $who} = $github_login;
  }
  $self->write_mapfile();
  return "OK.";
}


# find_issues_process -- process to get a list of issues/actions with criteria
sub find_issues_process($$$$$$$$$$)
{
  my ($body, $self, $channel, $who, $state, $type, $labels, $creator,
    $assignee, $repo) = @_;
  my ($owner, $res, $ref, $q, $s);

  if (!defined $self->{ua}) {
    print "Sorry, I don't have a GitHub account\n";
    return;
  }

  $repo = $self->find_matching_repository($channel, $repo // '') or
      print "Sorry, I don't know what repository to use." and
      return;
  ($owner, $repo) =
      $repo =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      print "The repository must be on GitHub for searching to work.\n" and
      return;

  $type = lc $type;

  # TODO: Find out if there are more than 100 results and, if so, warn
  # that the list is not complete.

  $labels =~ s/ //g if $labels;
  $labels = $labels ? "$labels,action" : "action" if lc $type eq 'actions';
  $q = "per_page=100&state=$state";
  $creator = $who if $creator && $creator =~ /^m[ey]$/i;
  $assignee = $who if $assignee && $assignee =~ /^m[ey]$/i;
  $q .= "&assignee=" . esc($self->name_to_login($assignee)) if $assignee;
  $q .= "&creator=" . esc($self->name_to_login($creator)) if $creator;
  $q .= "&labels=" . esc($labels) if $labels;
  $res = $self->{ua}->get(
    "https://api.github.com/repos/$owner/$repo/issues?$q",
    Accept => 'application/json');

  print STDERR "Channel $channel, list $q in $owner/$repo -> ",$res->code,"\n";

  if ($res->code == 404) {
    print "Not found\n";
    return;
  } elsif ($res->code == 422) {
    print "Validation failed\n";
    return;
  } elsif ($res->code != 200) {
    print STDERR "  ", $res->decoded_content, "\n";
    print "Error ", $res->code, "\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  $s = join(", ", map("#".$_->{number}, @$ref));
  print "Found $type in $owner/$repo: ", ($s eq '' ? "none" : $s), "\n";
}


# find_issues -- get a list of issues or actions with criteria
sub find_issues($$$$$$$$)
{
  my ($self,$channel,$who,$state,$type,$labels,$creator,$assignee,$repo) = @_;

  $self->forkit(run => \&find_issues_process, channel => $channel,
    arguments => [$self, $channel, $who, $state, $type, $labels, $creator,
      $assignee, $repo]);
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
      if $addressed && $text =~ /^bye *\.?$/i;

  return $self->add_repositories($channel, $1)
      if ($addressed &&
	$text =~ /^(?:discussing|discuss|use|using|take +up|taking +up|this +will +be|this +is) +([^ ].*?)$/i) ||
      $text =~ /^repo(?:s|sitory|sitories)? *(?:[:：]|\+[:：]?) *([^ ].*?)$/i;

  return $self->remove_repositories($channel, $1)
      if ($addressed &&
	$text =~ /^(?:forget|drop|remove|don't +use|do +not +use) +([^ ].*?)$/) ||
      $text =~ /^repo(?:s|sitory|sitories)? *(?:-|-[:：]?) *([^ ].*?)$/i;

  return $self->clear_repositories($channel)
      if $text =~ /^repo(?:s|sitory|sitories)? *(?:[:：]|\+[:：]?)$/i;

  return $self->set_delay($channel, 0 + $1)
      if $addressed &&
      $text =~ /^(?:set +)?delay *(?: to |=| ) *?([0-9]+) *(?:\. *)?$/i;

  return $self->status($channel)
      if $addressed && $text =~ /^status *(?:[?.] *)?$/i;

  return $self->set_suspend_all($channel, 0)
      if $addressed && $text =~ /^on(?: *\.)?$/i;

  return $self->set_suspend_all($channel, 1)
      if $addressed && $text =~ /^off(?: *\.)?$/i;

  return $self->set_suspend_issues($channel, 0)
      if $addressed &&
      $text =~ /^(?:set +)?issues *(?: to |=| ) *(on|yes|true)(?: *\.)?$/i;

  return $self->set_suspend_issues($channel, 1)
      if $addressed &&
      $text =~ /^(?:set +)?issues *(?: to |=| ) *(off|no|false)(?: *\.)?$/i;

  return $self->set_suspend_names($channel, 0)
      if $addressed &&
      $text =~ /^(?:set +)?(?:names|persons|teams)(?: +to +| *= *| +)(on|yes|true)(?: *\.)?$/i;

  return $self->set_suspend_names($channel, 1)
      if $addressed &&
      $text =~ /^(?:set +)?(:names|persons|teams)(?: +to +| *= *| +)(off|no|false)(?: *\.)?$/i;

  return $self->create_issue($channel, $1)
      if ($addressed || $do_issues) && $text =~ /^issue *[:：] *(.*)$/i &&
      !$self->is_ignored_nick($channel, $who);

  return $self->close_issue($channel, $1)
      if ($addressed || $do_issues) &&
      ($text =~ /^close +([a-zA-Z0-9\/._-]*#[0-9]+)(?=\W|$)/i ||
	$text =~ /^([a-zA-Z0-9\/._-]*#[0-9]+) +closed(?: *\.)?$/i) &&
      !$self->is_ignored_nick($channel, $who);

  return $self->reopen_issue($channel, $1)
      if ($addressed || $do_issues) &&
      ($text =~ /^reopen +([a-zA-Z0-9\/._-]*#[0-9]+)(?=\W|$)/i ||
         $text =~ /^([a-zA-Z0-9\/._-]*#[0-9]+) +reopened(?: *\.)?$/i) &&
      !$self->is_ignored_nick($channel, $who);

  return $self->create_action($channel, $1, $2)
      if ($addressed || $do_issues) &&
      ($text =~ /^action +([^:：]+?) *[:：] *(.*?)$/i ||
	$text =~ /^action *[:：] *(.*?) +to +(.*?)$/i) &&
      !$self->is_ignored_nick($channel, $who);

  return $self->account_info($channel)
      if $addressed &&
      $text =~ /^(?:who +are +you|account|user|login) *\??$/i;

  return $self->add_ignored_nicks($channel, $1)
      if $addressed && $text =~ /^ignore *(.*?)$/i;

  return $self->remove_ignored_nicks($channel, $1)
      if $addressed && $text =~ /^(?:do +not|don't) +ignore *(.*?) *$/i;

  return $self->set_github_alias($1, $2)
      if $addressed &&
      $text =~ /^([^ ]+)(?:\s*=\s*|\s+is\s+)@?([^ ]+)$/i;

  return $self->find_issues($channel, $who, $2 // "open", $3 // "issues",
    $4, $5, $6 // $1, $7)
      if $addressed &&
      $text =~ /^(?:find|look +up|get|search|search +for|list)(?: +(my))?(?: +(open|closed|all))?(?: +(issues|actions))?(?:(?: +with)? +labels? +([^ ]+(?: *, *[^ ]+)*)| +by +([^ ]+)| +for +([^ ]+)| +from +([^ ].*?))*(?: *\.)?$/i;

  return $self->maybe_expand_references($text, $channel, $addressed);
}


# emoted -- handle a /me message
sub emoted($$)
{
  my ($self, $info) = @_;
  return $self->said($info);
}


# help -- return the text to respond to an "agendabot, help" message
sub help($$)
{
  my ($self, $info) = @_;
  my $me = $self->nick();		# Our own name
  my $text = $info->{body};		# What Nick said

  return
      "for help on commands, try \"$me, help x\",\n" .
      "where x is one of:\n" .
      "#, @, use, discussing, discuss, using, take up, taking up,\n" .
      "this will be, this is, repo, repos, repository, repositories,\n" .
      "forget, drop, remove, don't use, do not use, issue, action, set,\n" .
      "delay, status, on, off, issues, names, persons, teams, invite,\n" .
      "list, search, find, get, look up, is, =, ignore, don't ignore,\n" .
      "do not ignore, who are you, account, user, login, close, reopen,\n" .
      "bye.  Example: \"$me, help #\"."
      if $text =~ /\bcommands\b/i;

  return
      "when I see \"xxx/yyy#nn\" or \"yyy#nn\" or \"#nn\" (where nn is\n" .
      "an issue number, yyy the name of a GitHub repository and xxx\n" .
      "the name of a repository owner), I will print the URL to that\n" .
      "issue and try to retrieve a summary.\n" .
      "See also \"$me, help use\" for setting the default repositories.\n" .
      "Example: \"#1\"."
      if $text =~ /#/;

  return
      "when I see \"\@abc\" (where abc is any name), I will print\n" .
      "the URL of the user or team of that name on GitHub.\n" .
      "Example: \"\@w3c\".\n"
      if $text =~ /@/;

  return
      "the command \"$me, $1 xxx/yyy\" or \"$me, $1 yyy\"\n" .
      "adds repository xxx/yyy to my list of known repositories\n" .
      "and makes it the default. If you create issues and action\n" .
      "items, they will be created in this repository. If you omit xxx,\n" .
      "it will be copied from the next repository in my list, or \"w3c\"\n" .
      "if there is none. You can give more than one repository,\n" .
      "separated by commas or spaces. Aliases: use, discussing,\n" .
      "discuss, using, take up taking up, this will be, this is.\n" .
      "See also \"$me, help repo\". Example: \"$me, $1 w3c/rdf-star\"."
      if $text =~ /\b(use|discussing|discuss|using|take +up|taking +up|this +will +be|this +is)\b/i;

  return
      "the command \"$1: xxx/yyy\" or \"$1: yyy\" adds repository\n" .
      "xxx/yyy to my list of known repositories and makes it the\n" .
      "default. If you create issues and action items, they will be\n" .
      "created in this repository. If you omit xxx, it will be the copied\n" .
      "from the next repository in my list, or \"w3c\" if there is none.\n" .
      "You can give more than one repository. Use commas or\n" .
      "spaces to separate them. Aliases: repo, repos, repository,\n" .
      "repositories. See also \"$me, help use\".\n" .
      "Example: \"$1: w3c/rdf-star\"."
      if $text =~ /\b(repo|repos|repository|repositories)\b/i;

  return
      "the command \"$me, $1 xxx/yyy\" or \"$me, $1 yyy\"\n" .
      "removes repository xxx/yyy from my list of known\n" .
      "repositories. If you omit xxx, I remove the first in the list\n" .
      "whose name is xxx. If the removed repository was the default,\n" .
      "the second in the list will now be the default.\n" .
      "Aliases: forget, drop, remove, don't use, do not use."
      if $text =~ /\b(forget|drop|remove|don't +use|do +not +use)\b/i;

  return
      "the command \"issue: ...\" creates a new issue in the default\n" .
      "repository on GitHub. See \"$me, help use\" for how to set\n" .
      "the default repository. Example: \"issue: Section 1.1 is wrong\".\n"
      if $text =~ /\bissue\b/i;

  return
      "the command \"action: john to ...\" or \"action john: ...\"\n" .
      "creates an action item (in fact, an issue with an assignee and\n" .
      "a due date) in the default repository on GitHub. If you end the\n" .
      "text with \"due\" and a date, the due date will be that date.\n" .
      "Otherwise the due date will be one week after today.\n" .
      "The date can be specified in many ways, such as \"Apr 2\" and\n" .
      "\"next Thursday\". See \"$me, help use\" for how to set the\n" .
      "default repository. See \"$me, help is\" for defining aliases\n" .
      "for usernames.\n" .
      "Example: \"action john: solve #1 due in 2 weeks."
      if $text =~ /\baction\b/i;

  return
      "\"set\" is used to set certain parameters, see\n" .
      "\"$me, help delay\", \"$me, help issues\" and\n" .
      "\"$me, help names\"."
      if $text =~ /\bset\b/i;

  return
      "normally, I will not look up an issue on GitHub if I\n" .
      "already did it less than 15 lines ago. The command\n" .
      "\"$me, delay nn\", or \"$me, delay = nn\", or\n" .
      "\"$me, set delay nn\" or \"$me, set delay to nn\"\n" .
      "changes the number of lines from 15 to nn.\n" .
      "Example: \"$me, delay 0\""
      if $text =~ /\bdelay\b/i;

  return
      "if you say \"$me, status\" or \"$me, status?\" I will print\n" .
      "my current list of repositories, the current delay, whether I'm\n" .
      "looking up issues, and which IRC users I'm ignoring.\n" .
      "Example: \"$me, status?\""
      if $text =~ /\bstatus\b/i;

  return
      "the command \"$me, on\" tells me to start creating and\n" .
      "looking up issues on GitHub again and to show URLs for\n" .
      "GitHub user names, if I was previously told to stop doing so\n" .
      "with \"$me, off\". See also \"$me, help issues\" and\n" .
      "\"$me, help names\"."
      if $text =~ /\bon\b/i;

  return
      "the command \"$me, off\" tells me to stop creating and\n" .
      "looking up issues on GitHub and to stop showing URLs for\n" .
      "GitHub user names. Use \"$me, on\" to tell me to start again.\n" .
      "See also \"$me, help issues\" and \"$me, help names\"."
      if $text =~ /\boff\b/i;

  return
      "the command \"$me, issues off\" or \"$me, issues = off\"\n" .
      "or \"$me, set issues off\" or \"$me, set issues to off\"\n" .
      "tells me to stop creating and looking up issues on GitHub.\n" .
      "The same with \"on\" instead of \"off\" tells me to start again.\n" .
      "See also \"$me, help on\", \"$me, help off\" and\n" .
      "\"$me, help names\"."
      if $text =~ /\bissues\b/i;

  return
      "the command \"$me, $1 off\" or\n" .
      "\"$me, $1 = off\" or \"$me, set $1 off\" or\n" .
      "\"$me, set $1 to off\" tells me to stop showing URLs for\n" .
      "GitHub user names (such as \"\@w3c\"). Replace \"off\"\n" .
      "by \"on\" to tell me to start again. See also\n" .
      "\"$me, help on\", \"$me, help off\" and \"$me, help issues\"."
      if $text =~ /\b(names|persons|teams)\b/i;

  return
      "the command \"/invite $me\" (note the \"/\") invites me\n" .
      "to join this channel. See also \"$me, bye\" for how to\n" .
      "dismiss me from the channel."
      if $text =~ /\binvite\b/i;

  return
      "the command \"$me, aaa $1 bbb\" defines that aaa is\n" .
      "an alias for the person with the username bbb on GitHub.\n" .
      "You can add \"@\" in front of the GitHub username, if you wish.\n" .
      "Typically this command serves to define an equivalence\n" .
      "between an IRC nickname and a GitHub username, so that\n" .
      "you can say \"action aaa:...\", where aaa is an IRC nick.\n" .
      "Aliases: is, =. Example: \"$me, denis $1 \@deniak\"."
      if $text =~ /(\bis\b|=)/i;

  return
      "the command \"$me, $1 aaa\" tells me to stop\n" .
      "ignoring messages on IRC from user aaa.\n" .
      "See also \"$me, help ignore\".\n" .
      "Example: \"$me, $1 agendabot\"."
      if $text =~ /\b(don't +ignore|do +not +ignore)\b/i;

  return
      "the command \"$me, ignore aaa\" tells me to ignore\n" .
      "messages on IRC from user aaa.\n" .
      "See also \"$me, help don't ignore\".\n" .
      "Example: \"$me, ignore rrsagent\"."
      if $text =~ /\bignore\b/i;

  return
      "I will respond to the command \"$me, $1\"\n" .
      "or \"$me, $1?\" with the username that I use on GitHub.\n" .
      "Aliases: who are you, account, user, login."
      if $text =~ /\b(who +are +you|account|user|login)\b/i;

  return
      "the command \"close #nn\" or \"close yyy#nn\" or\n" .
      "\"close xxx/yyy#nn\" tells me to close GitHub issue number nn\n" .
      "in repository xxx/yyy. If you omit xxx or xxx/yyy, I will find\n" .
      "the repository in my list of repositories.\n" .
      "See also \"$me, help use\" for creating a list of repositories.\n" .
      "Example: \"close #1\"."
      if $text =~ /\bclose\b/i;

  return
      "the command \"reopen #nn\" or \"reopen yyy#nn\" or\n" .
      "\"reopen xxx/yyy#nn\" tells me to reopen GitHub issue\n" .
      "number nn in repository xxx/yyy. If you omit xxx or xxx/yyy,\n" .
      "I will find the repository in my list of repositories.\n" .
      "See also \"$me, help use\" for creating a list of repositories.\n" .
      "Example: \"reopen #1\"."
      if $text =~ /\breopen\b/i;

  return
      "the command \"$me, bye\" tells me to leave this channel.\n" .
      "See also \"$me help invite\"."
      if $text =~ /\bbye\b/i;

  return
      "the command \"$me, $1\" lists at most 100 most recent open issues.\n" .
      "It can optionally be followed by \"open\", \"closed\" or \"all\",\n" .
      "optionally followed by \"issues\" or \"actions\, followed by zero\n" .
      "or more conditions: \"with labels label1, label2...\" or\n" .
      "\"for name\" or \"by name\" or \"from repo\". I will list the\n" .
      "issues or actions that match those conditions.\n" .
      "Example: \"$1 closed actions for joe from w3c/rdf-star\".\n" .
      "Aliases: find, look up, get, search, search for, list."
      if $text =~ /\b(find|look +up|get|search|search +for|list)/i;

  return
      "I am a bot to look up and create GitHub issues and\n" .
      "action items. I am an instance of " .
      blessed($self) . " " . VERSION . ".\n" .
      "Try \"$me, help commands\" or\n" .
      "see " . MANUAL;
}


# connected -- handle a successful connection to a server
sub connected($)
{
  my ($self) = @_;

  $self->join_channel($_) foreach keys %{$self->{joined_channels}};
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


# esc -- escape characters for use in the value of a URL query parameter
sub esc($)
{
  my ($s) = @_;
  my ($octets);

  $octets = str2bytes("UTF-8", $s);
  $octets =~ s/([^A-Za-z0-9._~!$'()*+,=:@\/?-])/"%".sprintf("%02x",ord($1))/eg;
  return bytes2str("UTF-8", $octets);
}


# read_netrc -- find login & password for a host and (optional) login in .netrc
sub read_netrc($;$)
{
  my ($host, $login) = @_;

  my $machine = Net::Netrc->lookup($host, $login);
  return ($machine->login, $machine->password) if defined $machine;
  return (undef, undef);
}


# Main body

my (%opts, $ssl, $proto, $user, $password, $host, $port, $channel);

$Getopt::Std::STANDARD_HELP_VERSION = 1;
getopts('m:n:N:r:t:v', \%opts) or die "Try --help\n";
die "Usage: $0 [options] [--help] irc[s]://server...\n" if $#ARGV != 0;

# The single argument must be an IRC-URL.
#
($proto, $user, $password, $host, $port, $channel) = $ARGV[0] =~
    /^(ircs?):\/\/(?:([^:@\/?#]+)(?::([^@\/?#]*))?@)?([^:\/#?]+)(?::([^\/]*))?(?:\/(.+)?)?$/i
    or die "Argument must be a URI starting with `irc:' or `ircs:'\n";
$ssl = $proto =~ /^ircs$/i;
$user =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $user;
$password =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $password;
$port //= $ssl ? 6697 : 6667;
$channel =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $channel;
$channel = '#' . $channel if defined $channel && $channel !~ /^[#&]/;

# If there was no username, try to find one in ~/.netrc
if (!defined $user) {
  my ($u, $p) = read_netrc($host);
  ($user, $password) = ($u, $p) if defined $u;
}

# If there was a username, but no password, try to find one in ~/.netrc
if (defined $user && !defined $password) {
  my ($u, $p) = read_netrc($host, $user);
  $password = $p if defined $p;
}

# If there was a username, but still no password, prompt for it.
if (defined $user && !defined $password) {
  print "IRC password for user \"$user\": ";
  ReadMode('noecho');
  $password = ReadLine(0);
  ReadMode('restore');
  print "\n";
  chomp $password;
}

STDERR->autoflush(1);		# Write the log without buffering

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
 <ghurlbot> https://github.com/xxx/yyy/issues/13 -> #13

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
