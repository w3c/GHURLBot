#!/usr/bin/env perl
#
# This IRC 'bot expands short references to issues, pull requests,
# persons and teams on GitHub to full URLs. See the perldoc at the end
# for how to run it and manual.html for the interaction on IRC.
#
#
# TODO: The map-file should contain the IRC network, not just the
# channel names.
#
# TODO: Allow "action-9" as an alternative for "#9"?
#
# TODO: Add a permission system to limit who can create, close, reopen
# or comment on issues? (Maybe people on IRC can somehow prove to ghurlbot
# that they have a GitHub account and maybe ghurlbot can find out if
# that account has the right to close an issue?)
#
# TODO: A way for a user to ask for the github login of a given nick?
# Or to ask for all known aliases?
#
# TODO: Should all responses from the bot other than expanded
# references be emoted ("/me")?
#
# TODO: Get plain text instead of markdown from GitHub? (Requires
# setting the Accept header to "application/vnd.github.text+json" and
# using the "body_text" field instead of "body" from the returned
# JSON.)
#
# TODO: Add and remove labels from issues?
#
# TODO: Add a way to use other servers than github.com.
#
# TODO: Set the default to not expanding names ("set names = off")?
#
# TODO: Try to track nick changes and update matching aliases?
#
# TODO: Add comments (with the "note" or "comment" commands) to the
# most recently created issue without having to say its number? Refer
# to it as "this" or "that"?
#
# TODO: Edit an issue? The bot can edit issues it created itself, with
# PATCH
# https://api.github.com/repos/{owner}/{repo}/issues/{issue_number}.
# It is possible to change the title, the body, the assignees and the
# labels: "edit #7: A new title", "edit text #7: Text for the body",
# "edit due #7: in two weeks", etc.
#
# TODO: handle_process_output() should use emote() instead of say()
# when the output is in response to a /me (emoted) command.
#
# Created: 2022-01-11
# Author: Bert Bos <bert@w3.org>
#
# Copyright © 2022-2023 World Wide Web Consortium, (Massachusetts Institute
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
use open qw(:encoding(UTF-8)); # Undeclared streams in UTF-8
use File::Temp qw(tempfile tempdir);
use File::Copy;
use Fcntl ':flock';
use LWP;
use LWP::ConnCache;
use JSON;
use Date::Manip::Date;
use Date::Manip::Delta;
use POSIX qw(strftime);
use Net::Netrc;
use Encode qw(encode decode);
use POE;			# For OBJECT, ARG0 and ARG1

use constant MANUAL => 'https://w3c.github.io/GHURLBot/manual.html';
use constant HOME => 'https://w3c.github.io/GHURLBot';
use constant VERSION => '0.5';
use constant DEFAULT_DELAY => 15;
use constant DEFAULT_MAXLINES => 10; # Nr. of issues to list in full. ( <= 100)
my $githubissue =
    qr{https://github\.com/[a-z0-9._-]+/[a-z0-9._-]+/issues/[0-9]+}i;

# GitHub limits requests to 5000 per hour per authenticated user (and
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

  # Create a user agent to retrieve data from GitHub.
  if ($self->{github_api_token}) {
    $self->{ua} = LWP::UserAgent->new(agent => blessed($self) . '/' . VERSION,
      timeout => 10, keep_alive => 1, env_proxy => 1);
    $self->{ua}->default_header('X-GitHub-Api-Version', '2022-11-28');
    $self->{ua}->default_header('Accept', 'application/json');
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
  my $mode;

  return if ! $self->{rejoinfile};

  # If the rejoinfile exists, open it for reading, but also for
  # writing, because writing mode is needed to set a lock on it. If
  # the file doesn't exist, create it.
  $mode = -e $self->{rejoinfile} ? "+<" : ">";
  open $self->{rejoinfile_handle}, $mode, $self->{rejoinfile} or
      return "$self->{rejoinfile}: $!";
  flock $self->{rejoinfile_handle}, LOCK_EX | LOCK_NB or
      return "$self->{rejoinfile}: already in use";

  return if $mode eq ">";	# File just created, nothing to read
  $self->log("Reading $self->{rejoinfile}");
  while (readline $self->{rejoinfile_handle}) {
    chomp;
    $self->{joined_channels}->{$_} = 1;
    $self->{linenumber}->{$_} = 0;
    $self->{history}->{$_} = {};
  }
  # The connected() method takes care of rejoining those channels.
  # Do not close the file. We want to keep a lock on it.
  return;			# undef return means there were no errors
}


# rewrite_rejoinfile -- replace the rejoinfile with an updated one
sub rewrite_rejoinfile($)
{
  my ($self) = @_;

  return if ! $self->{rejoinfile};
  eval {
    # Write a temporary file in the same directory as rejoinfile. When
    # done, rename it to rejoinfile. This way, the rejoinfile will
    # always be a complete file, even if the program is interrupted.
    # Get a lock on the temporary file before closing the filehandle
    # of the old rejoinfile (which release the lock on that file).
    my ($fh, $tempname) = tempfile($self->{rejoinfile}."XXXX", UNLINK => 1);
    flock $fh, LOCK_EX | LOCK_NB or
	$self->log("Cannot lock $tempname, continuing anyway");
    foreach (keys %{$self->{joined_channels}}) {
      print $fh "$_\n" or die "$tempname: $!";
    }
    $fh->flush;
    move($tempname, $self->{rejoinfile});
    close $self->{rejoinfile_handle}; # Releases lock
    $self->{rejoinfile_handle} = $fh;
  };
  $self->log($@) if $@;
}


# read_mapfile -- read or create the file mapping channels to repositories
sub read_mapfile($)
{
  my $self = shift;
  my ($channel, $fh, $mode);

  # If the file exists, open it for reading and writing, because write
  # mode is needed to set a lock on it. Otherwise create it.
  $mode = -e $self->{mapfile} ? "+<" : ">";
  open $self->{mapfile_handle}, $mode, $self->{mapfile} or
      return "$self->{mapfile}: $!";
  flock $self->{mapfile_handle}, LOCK_EX | LOCK_NB or
      return "$self->{mapfile}: already in use";

  return if $mode eq ">";	# File just created, nothing to read
  $self->log("Reading $self->{mapfile}");
  while (readline $self->{mapfile_handle}) {
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
    # maxlines NN
    #   When listing issues in full, show up to NN issues at a time.
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
    } elsif ($_ =~ /^\s*repo\b\s*([^\s]*)\s*$/) {
      push @{$self->{repos}->{$channel}}, $1 if $1;
    } elsif ($_ =~ /^\s*delay\s+([0-9]+)\s*$/) {
      $self->{delays}->{$channel} = 0 + $1;
    } elsif ($_ =~ /^\s*issues\s+off\s*$/) {
      $self->{suspend_issues}->{$channel} = 1;
    } elsif ($_ =~ /^\s*names\s+off\s*$/) {
      $self->{suspend_names}->{$channel} = 1;
    } elsif ($_ =~ /^\s*ignore\s+([^\s]+)\s*$/) {
      $self->{ignored_nicks}->{$channel}->{fc $1} = $1;
    } elsif ($_ =~ /^\s*maxlines\s+([0-9]+)\s*$/) {
      $self->{maxlines}->{$channel} = 0 + $1;
    } else {
      return "$self->{mapfile}:$.: wrong syntax";
    }
  }
  # Do not close the file, because we want to keep a lock on it.
  return undef;				# No errors
}


# write_mapfile -- write the current status to file
sub write_mapfile($)
{
  my $self = shift;

  eval {
    my ($fh, $tempname) = tempfile($self->{mapfile}."XXXX", UNLINK => 1);
    flock $fh, LOCK_EX | LOCK_NB or
	$self->log("Cannot lock $tempname. Continuing anyway");

    # Sorting (of channel names and aliases) is not
    # necessary, but helps make the mapfile more readable.
    #
    foreach my $channel
	(sort(uniq(keys(%{$self->{repos}}), keys(%{$self->{suspend_issues}}),
		   keys(%{$self->{suspend_names}}), keys(%{$self->{delays}}),
		   keys(%{$self->{ignored_nicks}})))) {
      printf $fh "channel %s\n", $channel or die $!;
      printf $fh "repo %s\n", $_ for @{$self->{repos}->{$channel} // []};
      printf $fh "delay %d\n", $self->{delays}->{$channel} if
	  defined $self->{delays}->{$channel} &&
	  $self->{delays}->{$channel} != DEFAULT_DELAY;
      printf $fh "issues off\n" if $self->{suspend_issues}->{$channel};
      printf $fh "names off\n" if $self->{suspend_names}->{$channel};
      printf $fh "ignore %s\n", $_
	  for sort values %{$self->{ignored_nicks}->{$channel} // {}};
      printf $fh, "maxlines %d\n", $self->{$channel} if
	  defined $self->{$channel} && $self->{$channel} != DEFAULT_MAXLINES;
      printf $fh "\n" or die $!;
    }
    foreach my $nick (sort keys %{$self->{github_names} // {}}) {
      printf $fh "alias %s %s\n",$nick,$self->{github_names}->{$nick} or die $!;
    }
    $fh->flush;
    move($tempname, $self->{mapfile});
    close $self->{mapfile_handle}; # Releases lock
    $self->{mapfile_handle} = $fh;
  };
  $self->log($@) if $@;
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
    $self->rewrite_rejoinfile();
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
      $self->rewrite_rejoinfile();
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

  # $ref may be an abbreviated issue reference (#nn, repo#nn, or
  # owner/repo#nn), or a full URL
  # (https://github.com/owner/repo/issues/nn).
  if ($ref =~
    m{^(https://github\.com/[a-z0-9._-]+/[a-z0-9._-]+)/issues/([0-9]+)$}i) {
    return ($1, $2);
  } elsif ($ref =~ m{^([a-z0-9/._-]*)#([0-9]+)$}i) {
    my $issue = $2;
    return ($self->find_matching_repository($channel, $1), $issue);
  } else {
    $self->log("Bug! wrong argument to find_repository_for_issue()");
    return (undef, undef);
  }
}


# name_to_login -- return the github name for a name, otherwise return the name
sub name_to_login($$)
{
  my ($self, $nick) = @_;

  # A name prefixed with "@" is assumed to be a GitHub login.
  # If we have an alias for the nick, use that.
  # Otherwise just return the nick itself.
  return $1 if $nick =~ /^@(.*)/;
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


# handle_process_output -- handler for text from a forked process, calls say()
sub handle_process_output($$$)
{
  my ($self, $body, $wheel_id) = @_[OBJECT, ARG0, ARG1];

  # This is not a method, but a POE event handler. It is called when a
  # background process prints a line to STDOUT. $body has the contents
  # of that line.

  # If the text starts with "say", just write it to IRC (minus the
  # "say"). No other keywords are currently defined.
  $body = decode('UTF-8', $body);
  chomp $body;		      # remove newline necessary to move data;
  if (($body =~ s/^say //)) {
    # Pick up the default arguments we squirreled away earlier.
    my $args = $self->{forks}{$wheel_id}{args};
    $args->{body} = $body;
    $self->say($args);
  } else {
    die "Bug: unrecognized output from a background process(): $body\n";
  }
  return;
}


# get_github_id_and_type -- get GitHub's ID for an issue/PR/discussion
sub get_github_id_and_type($$$$$$)
{
  my ($self, $owner, $repo, $issuenumber, $who, $channel) = @_;
  my ($q, $ref, $res);

  # This function is called from forked processes. It should not
  # modify anything in $self and should use print for output rather
  # than $self->say().

  $q = "query {
      repository(owner: \"$owner\", name: \"$repo\") {
	discussion(number: $issuenumber) { id }
	issue(number: $issuenumber) { id }
	pullRequest(number: $issuenumber) { id } } }";
  $res = $self->{ua}->post("https://api.github.com/graphql",
    'Content' => encode_json({query => $q}));
  print STDERR "Channel $channel, get id of $owner/$repo#$issuenumber -> ",
      $res->code, "\n";
  return (undef, undef) if $res->code != 200;

  $ref = decode_json($res->decoded_content)->{data}->{repository};

  return ($ref->{issue}->{id}, 'issue') if defined $ref->{issue};
  return ($ref->{pullRequest}->{id}, 'pr') if defined $ref->{pullRequest};
  return ($ref->{discussion}->{id}, 'discussion') if defined $ref->{discussion};
  return (undef, undef);
}


# create_action_process -- process that creates an action item on GitHub
sub create_action_process($$$$$$$$)
{
  my ($body, $self, $channel, $owner, $repo, $names, $text, $who) = @_;
  my (@names, @labels, $res, $content, $date, $due, $today, $s, $login);

  # This is not a method, but a routine that is run as a background
  # process by create_action(). Output to STDERR is meant for the log.
  # Output to STDOUT goes to IRC, via handle_process_output().

  # Creating an action item is like creating an issue, but with
  # assignees and a label "action".

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  @names = map($self->name_to_login($_),
	       grep(/./, split(/ *,? +and +| *, */, $names)));

  # If the action has a due date, remove it and put it in $date. Or use 1 week.
  $date = new Date::Manip::Date;
  if ($text =~ /^(.*) *- *due +(.*?)[. ]*$/i && $date->parse($2) == 0) {
    $text = $1;
  } elsif ($text =~ /^(.*) +due +(.*?)[. ]*$/i && $date->parse($2) == 0) {
    $text = $1;
  } else {
    $date->parse("next week");	# Default to 1 week
  }
  $text =~ s/,$//;		# Remove any final comma

  # When a due date is in the past, adjust the year and print a warning.
  $today = new Date::Manip::Date;
  $today->parse("today");
  if ($today->cmp($date) > 0) {
    my $delta = new Date::Manip::Delta;
    $delta->parse("+1 year");
    $date = $date->calc($delta) until $date->cmp($today) >= 0;
    print "say Assumed the due date is in ", $date->printf("%Y"), "\n";
  }

  $due = $date->printf("Due: %Y-%m-%d (%A %e %B)");
  $login = $self->name_to_login($who);
  $login = '@'.$login if $login ne $who;
  $s = "Opened by $login via IRC channel $channel on $self->{server}\n\n$due\n";

  $res = $self->{ua}->post(
    "https://api.github.com/repos/$owner/$repo/issues",
    'Content' => encode_json({title => $text, assignees => \@names,
			      body => "$s", labels => ['action']}));

  print STDERR "Channel $channel, new action \"$text\" in $owner/$repo -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "say Cannot create action. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "say Cannot create action. I have insufficient (or expired) authorization.\n";
  } elsif ($res->code == 404) {
    print "say Cannot create action. Please, check that I have write access to $owner/$repo\n";
  } elsif ($res->code == 410) {
    print "say Cannot create action. The repository $owner/$repo is gone.\n";
  } elsif ($res->code == 422) {
    print "say Cannot create action. Validation failed. Maybe ",
	scalar @names > 1 ? "one of the names" : $names[0],
	" is not a valid user for $owner/$repo?\n";
  } elsif ($res->code == 503) {
    print "say Cannot create action. Service unavailable.\n";
  } elsif ($res->code != 201) {
    print "say Cannot create action. Error ", $res->code, "\n";
  } else {
    # Issues created. Check that label and assignees were also added.
    $content = decode_json($res->decoded_content);
    my %n; $n{fc $_->{login}} = 1 foreach @{$content->{assignees}};
    @names = grep !exists $n{fc $_}, @names; # Remove names that were assigned
    if (! @{$content->{labels}}) {
      print "say I created -> issue #$content->{number} $content->{html_url}\n",
	  "say but I could not add the \"action\" label.\n",
	  "say That probably means I don't have push permission on $owner/$repo.\n";
    } elsif (@names) {		# Some names were not assigned
      print "say I created -> action #$content->{number} $content->{html_url}\n",
	  "say but I could not assign it to ", join(", ", @names), "\n",
	  "say They probably aren't collaborators on $owner/$repo.\n";
    } else {
      print "say Created -> action #$content->{number} $content->{html_url}\n";
    }
  }
}


# create_action -- create a new action item
sub create_action($$$$)
{
  my ($self, $channel, $names, $text, $who) = @_;
  my ($repository, $owner, $repo);

  return "Sorry, I cannot create actions, because I am running without " .
      "an access token for GitHub." if !defined $self->{github_api_token};

  # Check that this channel has a repository and that it is on GitHub.
  $repository = $self->{repos}->{$channel}->[0] or
      return "Sorry, I don't know what repository to use.";
  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      return "Cannot create actions on $repository as it is not on github.com.";

  # Check the rate limit.
  $self->check_and_update_rate("$owner/$repo") or
      return "Sorry, for security reasons, I won't touch a repository more ".
      "than ".MAXRATE." times in ".RATEPERIOD." minutes. ".
      "Please, try again later.";

  $self->forkit(run => \&create_action_process,
    handler => "handle_process_output", channel => $channel,
    arguments => [$self, $channel, $owner, $repo, $names, $text, $who]);

  return undef;			# The forked process will print a result
}


# create_issue_process -- process that creates an issue on GitHub
sub create_issue_process($$$$$$)
{
  my ($body, $self, $channel, $owner, $repo, $text, $who) = @_;
  my ($res, $content, $login, $s);

  # This is not a method, but a routine that is run as a background
  # process by create_issue(). Output to STDERR is meant for the log.
  # Output to STDOUT goes to IRC, via handle_process_output().

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  $login = $self->name_to_login($who);
  $login = '@'.$login if $login ne $who;
  $s = "Opened by $login via IRC channel $channel on $self->{server}";

  $res = $self->{ua}->post(
    "https://api.github.com/repos/$owner/$repo/issues",
    'Content' => encode_json({title => $text, body => $s}));

  print STDERR "Channel $channel, new issue \"$text\" in $owner/$repo -> ",
      $res->code, "\n";

  if ($res->code == 403) {
    print "say Cannot create issue. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "say Cannot create issue. I have insufficient (or expired) authorization.\n";
  } elsif ($res->code == 404) {
    print "say Cannot create issue.  Please, check that I have write access to $owner/$repo.\n";
  } elsif ($res->code == 410) {
    print "say Cannot create issue. The repository $owner/$repo is gone.\n";
  } elsif ($res->code == 422) {
    print "say Cannot create issue. Validation failed.\n";
  } elsif ($res->code == 503) {
    print "say Cannot create issue. Service unavailable.\n";
  } elsif ($res->code != 201) {
    print "say Cannot create issue. Error ", $res->code, "\n";
  } else {
    $content = decode_json($res->decoded_content);
    print "say Created -> issue #$content->{number} $content->{html_url}",
	" $content->{title}\n";
  }
}


# create_issue -- create a new issue
sub create_issue($$$$)
{
  my ($self, $channel, $text, $who) = @_;
  my ($repository, $owner, $repo);

  return "Sorry, I cannot create issues, because I am running without " .
      "an access token for GitHub." if !defined $self->{github_api_token};

  # Check that this channel has a repository and that it is on GitHub.
  $repository = $self->{repos}->{$channel}->[0] or
      return "Sorry, I don't know what repository to use.";
  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      return "Cannot create issues on $repository as it is not on github.com.";

  # Check the rate limit.
  $self->check_and_update_rate("$owner/$repo") or
      return "Sorry, for security reasons, I won't touch a repository more " .
      "than ".MAXRATE." times in ".RATEPERIOD." minutes. " .
      "Please, try again later.";

  $self->forkit(run => \&create_issue_process,
    handler => "handle_process_output", channel => $channel,
    arguments => [$self, $channel, $owner, $repo, $text, $who]);

  return undef;			# The forked process will print a result
}


# close_issue_process -- process that closes an issue on GitHub
sub close_issue_process($$$$$$$)
{
  my ($body, $self, $channel, $owner, $repo, $issuenr, $who) = @_;
  my ($res, $login, $comment, $q, $ref, $data, $url, $err, $id, $type);

  # This is not a method, but a routine that is run as a background
  # process by create_issue(). Output to STDERR is meant for the log.
  # Output to STDOUT goes to IRC, via handle_process_output().

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  # First get the object ID of the issue/pull-request/discussion with
  # the given number and find out if it is an issue, a pull request or
  # a dicussion.
  ($id, $type) =
      $self->get_github_id_and_type($owner, $repo, $issuenr, $who, $channel);

  if (! defined $id) {
    print STDERR "Channel $channel, failed to close $owner/$repo#$issuenr\n";
    print "say Issue #$issuenr not found\n";
    return;
  }

  # Add a comment saying who closed the issue.
  $login = $self->name_to_login($who);
  $login = '@'.$login if $login ne $who;
  $comment = "Closed by $login via IRC channel $channel on $self->{server}";

  # Different types need different GraphQL queries. The result has the
  # same structure, however, thanks to the aliases ("close:",
  # "item:").
  $q = "mutation {
      addComment(input: { subjectId: \"$id\", body: \"$comment\" }) {
	commentEdge { node { url } } }
      close: closeIssue(input: { issueId: \"$id\" }) {
	item: issue { url } } }" if $type eq 'issue';
  $q = "mutation {
      addComment(input: { subjectId: \"$id\", body: \"$comment\" }) {
	commentEdge { node { url } } }
      close: closePullRequest(input: { pullRequestId: \"$id\" }) {
	item: pullRequest { url } } }" if $type eq 'pr';
  $q = "mutation {
      addDiscussionComment(input: {discussionId: \"$id\", body: \"$comment\" }){
	comment { resourcePath } }
      close: closeDiscussion(input: { discussionId: \"$id\" }) {
	item: discussion { url } } }" if $type eq 'discussion';

  $res = $self->{ua}->post("https://api.github.com/graphql",
    'Content' => encode_json({query => $q}));
  if ($res->code != 200) {
    print STDERR "Channel $channel, cannot close $owner/$repo#$issuenr -> ",
	$res->code, "\n";
    print "say Cannot close $type #$issuenr. Error ", $res->code, "\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  $err = $ref->{errors};
  $data = $ref->{data};

  if (! defined $data->{close}) {
    print STDERR "Channel $channel, cannot close $owner/$repo#$issuenr",
	" -> $err->[0]->{message}\n";
    print "say Cannot close $type #$issuenr -> $err->[0]->{message}\n";
    return;
  }

  $url = $data->{close}->{item}->{url};

  print STDERR "Channel $channel, closed $type $owner/$repo#$issuenr\n";
  print "say Closed -> $type #$issuenr $url\n";
}


# close_issue -- close an issue
sub close_issue($$$$)
{
  my ($self, $channel, $text, $who) = @_;
  my ($repository, $issue, $owner, $repo);

  return "Sorry, I cannot close issues, because I am running without " .
      "an access token for GitHub." if !defined $self->{github_api_token};

  # Parse the reference and infer the full repository URL.
  ($repository, $issue) = $self->find_repository_for_issue($channel, $text);
  return "Sorry, I don't know what repository to use for $text"
      if ! defined $issue;

  # Check that it is under "https://github.com/" and then remove that part.
  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      return "Cannot close issues on $repository as it is not on github.com.";

  # Check the rate limit.
  $self->check_and_update_rate("$owner/$repo") or
      return "Sorry, for security reasons, I won't touch a repository more " .
      "than ".MAXRATE." times in ".RATEPERIOD." minutes. " .
      "Please, try again later.";

  $self->forkit(run => \&close_issue_process,
    handler => "handle_process_output", channel => $channel,
    arguments => [$self, $channel, $owner, $repo, $issue, $who]);

  return undef;			# The forked process will print a result
}


# look_for_due_date -- find a due date, if any, in the given text
sub look_for_due_date($$)
{
  my ($self, $body) = @_;

  # A due date, if any, must be on a line of its own and look like
  # "Due: yyyy-mm-dd" with optionally something in parentheses after
  # it and optionally a full stop. For backward compatibility with
  # very early versions, "due dd mmmm yyyy" at the start of the body
  # is also supported.
  return " due $1" if $body =~
   /^[ \t]*Due:[ \t]+([0-9]{4}-[0-9]{2}-[0-9]{2})[ \t]*(?:\(.*\))?[. \t\r]*$/mi;
  return " due $1" if $body =~ /^due ([1-3 ]?[0-9] [a-z]{3} [0-9]{4}\b)/si;
  return '';
}


# reopen_issue_process -- process that reopens an issue on GitHub
sub reopen_issue_process($$$$$$)
{
  my ($body, $self, $channel, $owner, $repo, $issuenr, $who) = @_;
  my ($res, $comment, $login, $q, $ref, $err, $data, $url, $title, $id, $type);

  # This is not a method, but a routine that is run as a background
  # process by create_issue(). Output to STDERR is meant for the log.
  # Output to STDOUT goes to IRC, via handle_process_output().

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  # First get the object ID of the issue/pull-request/discussion with
  # the given number and find out if it is an issue, a pull request or
  # a dicussion.
  ($id, $type) =
      $self->get_github_id_and_type($owner, $repo, $issuenr, $who, $channel);

  if (! defined $id) {
    print STDERR "Channel $channel, failed to reopen $owner/$repo#$issuenr\n";
    print "say Issue #$issuenr not found\n";
    return;
  }

  # Add a comment saying who reopened the issue.
  $login = $self->name_to_login($who);
  $login = '@'.$login if $login ne $who;
  $comment = "Reopened by $login via IRC channel $channel on $self->{server}";

  # Different types need different GraphQL queries. The three queries
  # return the same structure, because the objects are given aliases
  # ("reopen:" and "item:").
  $q = "mutation {
      addComment(input: { subjectId: \"$id\", body: \"$comment\" }) {
	__typename }
      reopen: reopenIssue(input: { issueId: \"$id\" }) {
	item: issue { url title } } }" if $type eq 'issue';
  $q = "mutation {
      addComment(input: { subjectId: \"$id\", body: \"$comment\" }) {
	__typename }
      reopen: reopenPullRequest(input: { pullRequestId: \"$id\" }) {
	item: pullRequest { url title } } }" if $type eq 'pr';
  $q = "mutation {
      addDiscussionComment(input: {discussionId: \"$id\", body: \"$comment\" }){
	__typename }
      reopen: reopenDiscussion(input: { discussionId: \"$id\" }) {
	item: discussion { url title } } }" if $type eq 'discussion';

  $res = $self->{ua}->post("https://api.github.com/graphql",
    'Content' => encode_json({query => $q}));
  if ($res->code != 200) {
    print STDERR "Channel $channel, cannot reopen $owner/$repo#$issuenr -> ",
	$res->code, "\n";
    print "say Cannot reopen $type #$issuenr. Error ", $res->code, "\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  $err = $ref->{errors};
  $data = $ref->{data};

  if (! defined $data->{reopen}) {
    print STDERR "Channel $channel, cannot reopen $owner/$repo#$issuenr",
	" -> $err->[0]->{message}\n";
    print "say Cannot reopen $type #$issuenr -> $err->[0]->{message}\n";
    return;
  }

  $url = $data->{reopen}->{item}->{url};
  $title = $data->{reopen}->{item}->{title};

  print STDERR "Channel $channel, reopened $type $owner/$repo#$issuenr\n";
  print "say Reopened -> $type #$issuenr $url $title\n";
}


# reopen_issue -- reopen an issue
sub reopen_issue($$$$)
{
  my ($self, $channel, $text, $who) = @_;
  my ($repository, $issue, $owner, $repo);

  return "Sorry, I cannot open issues, because I am running without " .
      "an access token for GitHub." if !defined $self->{github_api_token};

  # Parse the reference and infer the full repository URL.
  ($repository, $issue) = $self->find_repository_for_issue($channel, $text);
  return "Sorry, I don't know what repository to use for $text"
      if ! defined $issue;

  # Check that it is under "https://github.com/" and then remove that part.
  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      return "Cannot open issues on $repository as it is not on github.com.";

  $self->check_and_update_rate("$owner/$repo") or
      return "Sorry, for security reasons, I won't touch a repository more " .
      "than ".MAXRATE." times in ".RATEPERIOD." minutes. " .
      "Please, try again later.";

  $self->forkit(run => \&reopen_issue_process,
    handler => "handle_process_output", channel => $channel,
    arguments => [$self, $channel, $owner, $repo, $issue, $who]);

  return undef;			# The forked process will print a result
}


# comment_on_issue_process -- process that adds a comment to an issue on GitHub
sub comment_on_issue_process($$$$$$$$)
{
  my ($body, $self, $channel, $owner, $repo, $issue, $comment, $who) = @_;
  my ($res, $login, $q, $ref, $err, $data, $id, $type, $url);

  # This is not a method, but a routine that is run as a background
  # process by create_issue(). Output to STDERR is meant for the log.
  # Output to STDOUT goes to IRC, via handle_process_output().

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  $login = $self->name_to_login($who);
  $login = '@'.$login if $login ne $who;

  $comment =~ s/"/\\"/g;
  $comment = "Comment by $login via IRC channel $channel on $self->{server}" .
      "\n\n$comment";

  # First find out if the issue number refers an issue, a pull request
  # or a discussion, and what its ID is.
  ($id, $type) =
      $self->get_github_id_and_type($owner, $repo, $issue, $who, $channel);

  if (! defined $id) {
    print STDERR "Channel $channel, failed to find $owner/$repo#$issue\n";
    print "say Issue #$issue not found\n";
    return;
  }

  # Different types need different GraphQL queries.
  $q = "mutation {
      addComment(input: { subjectId: \"$id\", body: \"$comment\" }) {
	commentEdge { node { url } } } }" if $type eq 'issue';
  $q = "mutation {
      addComment(input: { subjectId: \"$id\", body: \"$comment\" }) {
	commentEdge { node { url } } } }" if $type eq 'pr';
  $q = "mutation {
      addDiscussionComment(input: {discussionId: \"$id\", body: \"$comment\" }){
	comment { url } } }" if $type eq 'discussion';

  $res = $self->{ua}->post("https://api.github.com/graphql",
    'Content' => encode_json({query => $q}));
  if ($res->code != 200) {
    print STDERR "Channel $channel, cannot add comment to $owner/$repo#$issue",
	" -> ", $res->code, "\n";
    print "say Cannot add a comment to $type #$issue. Error ", $res->code, "\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  $err = $ref->{errors};
  $data = $ref->{data};

  if (! defined $data->{addComment} &&
    ! defined $data->{addComment} &&
    ! defined $data->{addDiscussionComment}) {
    print STDERR "Channel $channel, cannot add comment to $owner/$repo#$issue",
	" -> $err->[0]->{message}\n";
    print "say Cannot add a comment to $type #$issue -> $err->[0]->{message}\n";
    return;
  }

  $url = $type eq 'issue' ? $data->{addComment}->{commentEdge}->{node}->{url} :
      $type eq 'pr' ? $data->{addComment}->{commentEdge}->{node}->{url} :
      'https://github.com' .
      $data->{addDiscussionComment}->{comment}->{resourcePath};

  print STDERR "Channel $channel, added comment -> $url\n";
  print "say Added -> comment $url\n";
}


# comment_on_issue -- add a comment to an existing issue or action
sub comment_on_issue($$$$$)
{
  my ($self, $channel, $text, $comment, $who) = @_;
  my ($repository, $issue, $owner, $repo);

  return "Sorry, I cannot add comments to issues, because I am running with" .
      "out an access token for GitHub." if !defined $self->{github_api_token};

  # Parse the reference and infer the full repository URL.
  ($repository, $issue) = $self->find_repository_for_issue($channel, $text);
  return "Sorry, I don't know what repository to use for $issue"
      if ! defined $issue;

  # Check that it is under "https://github.com/" and then remove that part.
  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      return "Cannot add a comment to $repository as it is not on github.com.";

  $self->check_and_update_rate("$owner/$repo") or
      return "Sorry, for security reasons, I won't touch a repository more " .
      "than ".MAXRATE." times in ".RATEPERIOD." minutes. " .
      "Please, try again later.";

  $self->forkit(run => \&comment_on_issue_process,
    handler => "handle_process_output", channel => $channel,
    arguments => [$self, $channel, $owner, $repo, $issue, $comment, $who]);

  return undef;			# The forked process will print a result
}


# account_info_process -- process that looks up the GitHub account we are using
sub account_info_process($$$)
{
  my ($body, $self, $channel) = @_;
  my ($res, $content, $issuenumber);

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  $res = $self->{ua}->get("https://api.github.com/user",
    'Accept' => 'application/json');

  print STDERR "Channel $channel, user account -> ", $res->code, "\n";

  if ($res->code == 403) {
    print "say Cannot read account. Forbidden.\n";
  } elsif ($res->code == 401) {
    print "say Cannot read account. Insufficient or expired authorization.\n";
  } elsif ($res->code == 404) {
    print "say Cannot read account. Account not found.\n";
  } elsif ($res->code == 410) {
    print "say Cannot read account. Account is gone.\n";
  } elsif ($res->code == 422) {
    print "say Cannot read account. Validation failed.\n";
  } elsif ($res->code == 503) {
    print "say Cannot read account. Service unavailable.\n";
  } elsif ($res->code != 200) {
    print "say Cannot read account. Error ".$res->code."\n";
  } else {
    $content = decode_json($res->decoded_content);
    print "say I am using GitHub login ", $content->{login}, "\n";
  }
}


# account -- get info about the GitHub account, if any, that the bot runs under
sub account_info($$)
{
  my ($self, $channel) = @_;

  return "I am not using a GitHub account." if !$self->{github_api_token};

  $self->forkit(run => \&account_info_process,
    handler => "handle_process_output",
    channel => $channel, arguments => [$self, $channel]);
  return undef;		     # The forked process willl print a result
}


# get_issue_summary_process -- try to retrieve info about an issue/pull request
sub get_issue_summary_process($$$$$$)
{
  my ($body, $self, $channel, $repository, $issue, $who) = @_;
  my ($owner, $repo, $res, $ref, $comment, $d1, $d2, $q);

  # This is not a method, but a function that is called by forkit() to
  # run as a background process. It prints text for the channel to
  # STDOUT (which is handled by handle_process_output()) and log
  # entries to STDERR.

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  if (!defined $self->{ua}) {
    print "say $repository/issues/$issue -> #$issue\n";
    print STDERR "Channel $channel, info $repository#$issue\n";
    return;
  }

  ($owner, $repo) =
      $repository =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      print "say $repository/issues/$issue -> #$issue\n" and
      print STDERR "Channel $channel, info $repository/issues/$issue\n" and
      return;

  $q = "query {
      repository(owner: \"$owner\", name: \"$repo\") {
	discussion(number: $issue) {
	  title
	  labels(first: 100) { edges { node { name } } }
	  closed
	  author { login } }
	issue(number: $issue) {
	  title
	  labels(first: 100) { edges { node { name } } }
	  state
	  author { login }
	  bodyText
	  assignees(first: 100) { edges { node { login } } } }
	pullRequest(number: $issue) {
	  title
	  labels(first: 100) { edges { node { name } } }
	  state
	  author { login } } } }";
  $res = $self->{ua}->post("https://api.github.com/graphql",
    'Content' => encode_json({query => $q}));

  print STDERR "Channel $channel, info $repository#$issue -> ",$res->code,"\n";

  # TODO: What are the possible status codes in reply to a GraphQL call?
  if ($res->code != 200) {
    print STDERR "  ", $res->decoded_content, "\n";
    print "say $repository/issues/$issue -> #$issue\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  $d1 = $ref->{data}->{repository};

  if (defined $d1->{discussion}) {
    # It's a discussion.
    $d2 = $d1->{discussion};
    print "say $repository/discussions/$issue -> ",
	($d2->{closed} ? 'CLOSED ' : ''),
	"Discussion $issue $d2->{title} (by $d2->{author}->{login})",
	map(" [$_->{node}->{name}]", @{$d2->{labels}->{edges}}), "\n";


  } elsif (defined $d1->{pullRequest}) {
    # It's a pull request.
    $d2 = $d1->{pullRequest};
    print "say $repository/pull/$issue -> ",
	($d2->{state} ne 'OPEN' ? "$d2->{state} " : ''),
	"Pull Request $issue $d2->{title} (by $d2->{author}->{login})",
	map(" [$_->{node}->{name}]", @{$d2->{labels}->{edges}}), "\n";

  } elsif (defined $d1->{issue} &&
    grep($_->{node}->{name} eq 'action', @{$d1->{issue}->{labels}->{edges}})) {
    # It's an issue that is also an action.
    $d2 = $d1->{issue};
    $comment = $self->look_for_due_date($d2->{bodyText} // '');
    print "say $repository/issues/$issue -> ",
	($d2->{state} eq 'CLOSED' ? 'CLOSED ' : ''),
	"Action $issue $d2->{title} (on ",
	join(', ', map($_->{node}->{login}, @{$d2->{assignees}->{edges}})),
	")$comment\n";

  } elsif (defined $d1->{issue}) {
    # It's an issue, but not an action.
    $d2 = $d1->{issue};
    print "say $repository/issues/$issue -> ",
	($d2->{state} eq 'CLOSED' ? 'CLOSED ' : ''),
	"Issue $issue $d2->{title} (by $d2->{author}->{login})",
	map(" [$_->{node}->{name}]", @{$d2->{labels}->{edges}}), "\n";

  } else {
    # No issue, pull request or discussion with this number found.
    # (The issue may have been deleted, but the GraphQL API doesn't
    # distinguish between deleted and never created.)
    print "say Issue $issue not found\n";
  }
}


# maybe_expand_references -- return URLs for the issues and names in $text
sub maybe_expand_references($$$$$)
{
  my ($self, $text, $channel, $addressed, $who) = @_;
  my ($linenr, $delay, $do_issues, $do_names, $response, $repository, $nrefs);
  my ($ref, $issue, $name, $need_expansion);
  my ($do_lookups);

  $linenr = $self->{linenumber}->{$channel};		    # Current line#
  $delay = $self->{delays}->{$channel} // DEFAULT_DELAY;
  $do_issues = !$self->{suspend_issues}->{$channel};
  $do_names = !$self->{suspend_names}->{$channel};
  $do_lookups = defined $self->{ua};
  $response = '';

  # Look for #number, prefix#number and @name.
  $nrefs = 0;

  while ($text =~
    m{(?:(?:^|[^`])\K(`+)[^`](?:.*?[^`])?\g{-1}(?=[^`]|$)
      |\b(https://github\.com/([a-z0-9._-]+/[a-z0-9._-]+))/(?:issues|pull|discussions)/([0-9]+)
      |(?:^|[^a-z0-9._@\#/:-])\K((?:[a-z0-9._-]+(?:/[a-z0-9._-]+)?)?\#[0-9]+)
      |(?:^|[^a-z0-9._@\#/:-])\K(@([\w-]+))
      )(?=\W|$)}xig) {

    if ($1) {			# `...` (literal text, as in MarkDown)
      next;
    } elsif ($6) {		# @name
      ($ref, $name) = ($6, $7);
    } elsif ($2) {		# Full URL of an issue
      $need_expansion = 0;	# Full URL already given
      ($repository, $issue, $ref) = ($2, $4, "$3#$4");
    } else {			# owner/repo#n, repo#n, or #n
      $need_expansion = 1;	# Full URL needs to be printed
      $ref = $5;
      ($repository, $issue) = $self->find_repository_for_issue($channel, $ref);
    }

    my $previous = $self->{history}->{$channel}->{$ref} // -$delay;

    if ($ref !~ /^@/		# It's a reference to an issue.
      && ($addressed || ($do_issues && $linenr > $previous + $delay))) {
      if (! defined $issue) {
	$self->log("Channel $channel, cannot infer a repository for $ref");
	$response .= "I don't know which repository to use for $ref\n"
	    if $addressed;
	next;
      }
      # $self->log("Channel $channel $repository/issues/$issue");
      if ($do_lookups) {
	$self->forkit(run => \&get_issue_summary_process,
	  handler => "handle_process_output", channel => $channel,
	  arguments => [$self, $channel, $repository, $issue, $who]);
      } elsif ($need_expansion) {
	# We don't have a UA, and the issue was not already a full URL.
	$response .= "$repository/issues/$issue -> #$issue\n";
	$self->log("Channel $channel, info $repository#$issue");
      }
      $self->{history}->{$channel}->{$ref} = $linenr;

    } elsif ($ref =~ /^@/		# It's a reference to a GitHub user name
      && ($addressed || ($do_names && $linenr > $previous + $delay))) {
      $self->log("Channel $channel, name https://github.com/$name");
      $response .= "https://github.com/$name -> \@$name\n";
      $self->{history}->{$channel}->{$ref} = $linenr;

    } else {
      $self->log("Channel $channel, skipping $ref");
    }
    $nrefs++;
  }

  # If we were explicitly addressed, but there were no references,
  # that's probaby a mistake. Maybe a misspelled command. So issue a
  # warning. Otherwise, return the results or errors from expanding
  # the references.
  return $addressed && $nrefs == 0
      ? "sorry, I don't understand what you want me to do. Maybe try \"help\"?"
      : $response;
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


# set_maxlines -- set the number of full issues to display at a time
sub set_maxlines($$$)
{
  my ($self, $channel, $n) = @_;

  return "the number of lines cannot be greater than 100." if $n > 100;
  if (! defined $self->{maxlines}->{$channel} ||
    $self->{maxlines}->{$channel} != $n) {
    $self->{maxlines}->{$channel} = $n;
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
  $s .= ', full issues are printed ' .
      ($self->{maxlines}->{$channel} // DEFAULT_MAXLINES) . ' at a time';

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
      if $on && $self->{suspend_names}->{$channel};
  return 'names were already on.'
      if !$on && !$self->{suspend_names}->{$channel};

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
  my ($msg1, $msg2);

  $msg1 = $self->set_suspend_issues($channel, $on);
  $msg2 = $self->set_suspend_names($channel, $on);
  return 'OK.' if $msg1 eq 'OK.' || $msg2 eq 'OK.';
  return 'issues and names were already off.';
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
	if fc($self->{github_names}->{fc $who} // '') eq fc $github_login;
    $self->{github_names}->{fc $who} = $github_login;
  }
  $self->write_mapfile();
  return "OK.";
}


# find_issues_process -- process to get a list of issues/actions with criteria
sub find_issues_process($$$$)
{
  my ($body, $self, $channel, $who) = @_;
  my ($owner_repo, $res, $ref, $q, $s, $type);

  # This is not a method, but a function that is called by forkit() to
  # run as a background process. It prints text for the channel to
  # STDOUT (handled by handle_process_output()) and log entries to
  # STDERR.

  binmode(STDOUT, ":utf8");
  binmode(STDERR, ":utf8");

  $owner_repo = $self->{query_repo}->{$channel};
  $q = $self->{query}->{$channel};
  $q .= "&page=" . $self->{query_page}->{$channel};

  $res = $self->{ua}->get(
    "https://api.github.com/repos/$owner_repo/issues?$q");

  print STDERR "Channel $channel, list $q in $owner_repo -> ",$res->code,"\n";

  if ($res->code == 404) {
    print "say Repository \"$owner_repo\" not found\n";
    return;
  } elsif ($res->code == 422) {
    print "say Validation failed\n";
    return;
  } elsif ($res->code != 200) {
    print STDERR "  ", $res->decoded_content, "\n";
    print "say Error ", $res->code, "\n";
    return;
  }

  $ref = decode_json($res->decoded_content);
  $type = $self->{query_type}->{$channel};
  if (!@$ref) {
    print "say Found no $type in $owner_repo\n";
  } elsif (! $self->{query_full}->{$channel}) {
    $s = join(", ", map("#".$_->{number}, @$ref));
    print "say Found $type in $owner_repo: $s\n";
  } else {
    get_issue_summary_process($body, $self, $channel,
      "https://github.com/$owner_repo", $_->{number}, $who) foreach @$ref;
  }
}


# find_issues -- get a list of issues or actions with criteria
sub find_issues($$$$$$$$$)
{
  my ($self, $channel, $who, $state, $type, $labels, $creator,
      $assignee, $repo, $full) = @_;
  use constant MAX => 100;	# Max # of issues to list. Must be <= 100
  my ($max, $q, $owner);

  $repo = $self->find_matching_repository($channel, $repo // '') or
      return "sorry, I don't know what repository to use.";

  ($owner, $repo) =
      $repo =~ /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)$/i or
      return "The repository must be on GitHub for searching to work.";

  return "Sorry, I cannot access GitHub, because I am running without " .
      "an access token." if ! defined $self->{github_api_token};

  $type = lc $type;
  $labels =~ s/ //g if $labels;
  $labels = $labels ? "$labels,action" : "action" if lc $type eq 'actions';
  $max = $full ? $self->{maxlines}->{$channel} // DEFAULT_MAXLINES : MAX;
  $q = "&per_page=$max";
  if ($state =~ /^open$/i) {$q .= "&state=open"}
  elsif ($state =~ /^closed$/i) {$q .= "&state=closed"}
  elsif ($state =~ /^all$/i) {$q .= "&state=all"}
  else {return "Sorry, you found a bug! (Unhandled \$state in find_issues.)"}
  $creator = $who if $creator && $creator =~ /^m[ey]$/i;
  $assignee = $who if $assignee && $assignee =~ /^m[ey]$/i;
  $q .= "&assignee=" . esc($self->name_to_login($assignee)) if $assignee;
  $q .= "&creator=" . esc($self->name_to_login($creator)) if $creator;
  $q .= "&labels=" . esc($labels) if $labels;

  # Store the query.
  $self->{query}->{$channel} = $q;
  $self->{query_repo}->{$channel} = "$owner/$repo";
  $self->{query_page}->{$channel} = 1;
  $self->{query_full}->{$channel} = $full;
  $self->{query_type}->{$channel} = $type;

  # Start a background process to run the query.
  $self->forkit(run => \&find_issues_process,
    handler => "handle_process_output", channel => $channel,
    arguments => [$self, $channel, $who]);
}


# find_next_issues -- get next list of issues or actions with criteria
sub find_next_issues($$$)
{
  my ($self, $channel, $who) = @_;

  return "I have not listed any issues or actions yet." if
      !$self->{query}->{$channel};
  $self->{query_page}->{$channel}++;
  $self->forkit(run =>\&find_issues_process,
    handler => "handle_process_output",
    channel => $channel, arguments => [$self, $channel, $who]);
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

  return if $channel eq 'msg';		# Do not react to private messages

  $self->{linenumber}->{$channel}++;

  # Lines like "s/foo/bar/" are probably commands for scribe.perl to
  # modify an earlier text. We don't look for issues or commands in
  # such lines, because they are unlikely to be meant for us.
  return undef
      if $text =~ /^(?:s|i)(\/|\|)(.*?)\1(.*?)(?:\1([gG])? *)?$/;

  return $self->part_channel($channel), undef
      if $addressed && $text =~ /^bye *\.? *$/i;

  return $self->add_repositories($channel, $1)
      if ($addressed &&
	$text =~ /^(?:discussing|discuss|use|using|take +up|taking +up|this +will +be|this +is) +([^ ].*?)$/i) ||
      $text =~ /^repo(?:s|sitory|sitories)? *(?:[:：]|\+[:：]?) *([^ ].*)$/i;

  return $self->remove_repositories($channel, $1)
      if ($addressed &&
	$text =~ /^(?:forget|drop|remove|don't +use|do +not +use) +([^ ].*)$/) ||
      $text =~ /^repo(?:s|sitory|sitories)? *-[:：]? *([^ ].*)$/i;

  return $self->clear_repositories($channel)
      if $text =~ /^repo(?:s|sitory|sitories)? *(?:[:：]|\+[:：]?)$/i;

  return $self->set_delay($channel, 0 + $1)
      if $addressed &&
      $text =~ /^(?:set +)?delay *(?: to |=| ) *([0-9]+) *\.? *$/i;

  return $self->set_maxlines($channel, 0 + $1)
      if $addressed &&
      $text =~ /^(?:set +)?lines *(?: to |=| ) *([0-9]+) *\.? *$/i;

  return $self->status($channel)
      if $addressed && $text =~ /^status *[?.]? *$/i;

  return $self->set_suspend_all($channel, 0)
      if $addressed && $text =~ /^on *\.? *$/i;

  return $self->set_suspend_all($channel, 1)
      if $addressed && $text =~ /^off *\.? *$/i;

  return $self->set_suspend_issues($channel, 0)
      if $addressed &&
      $text =~ /^(?:set +)?issues *(?: to |=| ) *(on|yes|true) *\.? *$/i;

  return $self->set_suspend_issues($channel, 1)
      if $addressed &&
      $text =~ /^(?:set +)?issues *(?: to |=| ) *(off|no|false) *\.? *$/i;

  return $self->set_suspend_names($channel, 0)
      if $addressed &&
      $text =~ /^(?:set +)?(?:names|persons|teams)(?: +to +| *= *| +)(on|yes|true) *\.? *$/i;

  return $self->set_suspend_names($channel, 1)
      if $addressed &&
      $text =~ /^(?:set +)?(?:names|persons|teams)(?: +to +| *= *| +)(off|no|false) *\.? *$/i;

  return $self->create_issue($channel, $1, $who)
      if ($addressed || $do_issues) && $text =~ /^issue *[:：] *(.*)$/i &&
      !$self->is_ignored_nick($channel, $who);

  return $self->close_issue($channel, $1, $who)
      if ($addressed || $do_issues) &&
      ($text =~ /^close +([a-zA-Z0-9\/._-]*#[0-9]+)(?=\W|$)/i ||
	$text =~ /^close +($githubissue)(?=\W|$)/i ||
	$text =~ /^([a-zA-Z0-9\/._-]*#[0-9]+) +closed?(?: *\.)?$/i ||
	$text =~ /^($githubissue) +closed?(?: *\.)?$/i) &&
      !$self->is_ignored_nick($channel, $who);

  return $self->reopen_issue($channel, $1, $who)
      if ($addressed || $do_issues) &&
      ($text =~ /^reopen +([a-zA-Z0-9\/._-]*#[0-9]+)(?=\W|$)/i ||
	$text =~ /^reopen +($githubissue)(?=\W|$)/i ||
	$text =~ /^([a-zA-Z0-9\/._-]*#[0-9]+) +reopen(?:ed)?(?: *\.)?$/i ||
	$text =~ /^($githubissue) +reopen(?:ed)?(?: *\.)?$/i) &&
      !$self->is_ignored_nick($channel, $who);

  return $self->comment_on_issue($channel, $1, $2, $who)
      if ($addressed || $do_issues) &&
      ($text =~ /^(?:note|comment) +(?:on +)?([a-zA-Z0-9\/._-]*#[0-9]+) *:? *(.*)/i ||
       $text =~ /^(?:note|comment) +(?:on +)?($githubissue) *:? *(.*)/i ||
       $text =~ /^([a-zA-Z0-9\/._-]*#[0-9]+) +(?:note|comment) *:? *(.*)/i ||
       $text =~ /^($githubissue) +(?:note|comment) *:? *(.*)/i) &&
      !$self->is_ignored_nick($channel, $who);

  return $self->create_action($channel, $1, $2, $who)
      if ($addressed || $do_issues) &&
      ($text =~ /^action +([^:：]+?) *[:：] *(.*)$/i ||
	$text =~ /^action *[:：] *(.*?)(?: +to | *[:：])(.*)$/i) &&
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

  return $self->find_issues($channel, $who, $5 // $2 // "open", $6 // "issues",
    $7, $8, $9 // $3, $10, $1 // $4 // $11 // $12)
      if $addressed &&
      $text =~ /^(verbosely +)?(?:find|look +up|get|search|search +for|list)(?:( +all)? +(my))?( +full)?(?: +(open|closed|all))?(?: +(issues|actions))?(?:(?: +with)? +labels? +([^ ]+(?: *, *[^ ]+)*)| +by +([^ ]+)| +for +([^ ]+)| +from +(?:repo(?:sitory)? +)?([^ ].*?)| +(with +descriptions?|in +full))*( +verbosely)? *\.? *$/i;

  return $self->find_next_issues($channel, $who)
      if $addressed &&
      $text =~ /^(?:(?:next|more)(?: +(?:find|look +up|get|search|search +for|list))?(?: +(?:issues|actions))?|(?:find|look +up|get|search|search +for|list) +(?:next|more)(?: +(?:issues|actions))?) *\.? *$/i;

  return $self->maybe_expand_references($text, $channel, $addressed, $who)
      if !$self->is_ignored_nick($channel, $who);
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
      "for help on commands, try \x02$me, help x\x02,\n" .
      "where x is one of:\n" .
      "#, @, use, discussing, discuss, using, take up, taking up,\n" .
      "this will be, this is, repo, repos, repository, repositories,\n" .
      "forget, drop, remove, don't use, do not use, issue, action, set,\n" .
      "delay, status, on, off, issues, names, persons, teams, invite,\n" .
      "list, search, find, get, look up, next, is, =, ignore,\n" .
      "don't ignore, do not ignore, who are you, account, user, login,\n" .
      "close, reopen, comment, note, bye.  Example: \x02$me, help #\x02."
      if $text =~ /\bcommands\b/i;

  return
      "when I see \x02xxx/yyy#nn\x02 or \x02yyy#nn\x02 or \x02#nn\x02 (where nn is\n" .
      "an issue number, yyy the name of a GitHub repository and xxx\n" .
      "the name of a repository owner), I will print the URL to that\n" .
      "issue and try to retrieve a summary.\n" .
      "See also \x02$me, help use\x02 for setting the default repositories.\n" .
      "Example: #1"
      if $text =~ /#/;

  return
      "when I see \x02\@abc\x02 (where abc is any name), I will print\n" .
      "the URL of the user or team of that name on GitHub.\n" .
      "Example: \@w3c"
      if $text =~ /@/;

  return
      "the command \x02$me, $1 xxx/yyy\x02 or \x02$me, $1 yyy\x02 adds\n" .
      "repository xxx/yyy to my list of known repositories and makes it\n" .
      "the default. If you create issues and action items, they will be\n" .
      "created in this repository. If you omit xxx, it will be copied\n" .
      "from the next repository in my list, or \x02w3c\x02 if there is\n" .
      "none. You can give more than one repository, separated by commas\n" .
      "or spaces. Aliases: use, discussing, discuss, using, take up\n" .
      "taking up, this will be, this is.\n" .
      "See also \x02$me, help repo\x02. Example: $me, $1 w3c/rdf-star"
      if $text =~ /\b(use|discussing|discuss|using|take +up|taking +up|this +will +be|this +is)\b/i;

  return
      "the command \x02$1: xxx/yyy\x02 or \x02$1: yyy\x02 adds repository\n" .
      "xxx/yyy to my list of known repositories and makes it the\n" .
      "default. If you create issues and action items, they will be\n" .
      "created in this repository. If you omit xxx, it will be the copied\n" .
      "from the next repository in my list, or \x02w3c\x02 if there is none.\n" .
      "You can give more than one repository. Use commas or\n" .
      "spaces to separate them. Aliases: repo, repos, repository,\n" .
      "repositories. See also \x02$me, help use\x02.\n" .
      "Example: $1: w3c/rdf-star"
      if $text =~ /\b(repo|repos|repository|repositories)\b/i;

  return
      "the command \x02$me, $1 xxx/yyy\x02 or \x02$me, $1 yyy\x02\n" .
      "removes repository xxx/yyy from my list of known\n" .
      "repositories. If you omit xxx, I remove the first in the list\n" .
      "whose name is xxx. If the removed repository was the default,\n" .
      "the second in the list will now be the default.\n" .
      "Aliases: forget, drop, remove, don't use, do not use."
      if $text =~ /\b(forget|drop|remove|don't +use|do +not +use)\b/i;

  return
      "the command \x02issue: ...\x02 creates a new issue in the default\n" .
      "repository on GitHub. See \x02$me, help use\x02 for how to set\n" .
      "the default repository. Example: issue: Section 1.1 is wrong"
      if $text =~ /\bissue\b/i;

  return
      "the command \x02action: john to ...\x02 or \x02action john: ...\x02\n" .
      "creates an action item (in fact, an issue with an assignee and\n" .
      "a due date) in the default repository on GitHub. You can\n" .
      "Separate multiple assignees with commas. If you end the\n" .
      "text with \x02due\x02 and a date, the due date will be that date.\n" .
      "Otherwise the due date will be one week after today.\n" .
      "The date can be specified in many ways, such as \x02Apr 2\x02 and\n" .
      "\x02next Thursday\x02. See \x02$me, help use\x02 for how to set the\n" .
      "default repository. See \x02$me, help is\x02 for defining aliases\n" .
      "for usernames.\n" .
      "Example: action john, kylie: solve #1 due in 2 weeks"
      if $text =~ /\baction\b/i;

  return
      "\x02set\x02 is used to set certain parameters, see\n" .
      "\x02$me, help delay\x02, \x02$me, help issues\x02 and\n" .
      "\x02$me, help names\x02."
      if $text =~ /\bset\b/i;

  return
      "normally, I will not look up an issue on GitHub if I\n" .
      "already did it less than 15 lines ago. The command\n" .
      "\x02$me, delay nn\x02, or \x02$me, delay = nn\x02, or\n" .
      "\x02$me, set delay nn\x02 or \x02$me, set delay to nn\x02\n" .
      "changes the number of lines from 15 to nn.\n" .
      "Example: $me, delay 0"
      if $text =~ /\bdelay\b/i;

  return
      "if you say \x02$me, status\x02 or \x02$me, status?\x02 I will print\n" .
      "my current list of repositories, the current delay, whether I'm\n" .
      "looking up issues, and which IRC users I'm ignoring.\n" .
      "Example: $me, status?"
      if $text =~ /\bstatus\b/i;

  return
      "the command \x02$me, on\x02 tells me to start creating and\n" .
      "looking up issues on GitHub again and to show URLs for\n" .
      "GitHub user names, if I was previously told to stop doing so\n" .
      "with \x02$me, off\x02. See also \x02$me, help issues\x02 and\n" .
      "\x02$me, help names\x02."
      if $text =~ /\bon\b/i;

  return
      "the command \x02$me, off\x02 tells me to stop creating and\n" .
      "looking up issues on GitHub and to stop showing URLs for\n" .
      "GitHub user names. Use \x02$me, on\x02 to tell me to start again.\n" .
      "See also \x02$me, help issues\x02 and \x02$me, help names\x02."
      if $text =~ /\boff\b/i;

  return
      "the command \x02$me, issues off\x02 or \x02$me, issues = off\x02\n" .
      "or \x02$me, set issues off\x02 or \x02$me, set issues to off\x02\n" .
      "tells me to stop creating and looking up issues on GitHub.\n" .
      "The same with \x02on\x02 instead of \x02off\x02 tells me to start again.\n" .
      "See also \x02$me, help on\x02, \x02$me, help off\x02 and\n" .
      "\x02$me, help names\x02."
      if $text =~ /\bissues\b/i;

  return
      "the command \x02$me, $1 off\x02 or\n" .
      "\x02$me, $1 = off\x02 or \x02$me, set $1 off\x02 or\n" .
      "\x02$me, set $1 to off\x02 tells me to stop showing URLs for\n" .
      "GitHub user names (such as \x02\@w3c\x02). Replace \x02off\x02\n" .
      "by \x02on\x02 to tell me to start again. See also\n" .
      "\x02$me, help on\x02, \x02$me, help off\x02 and \x02$me, help issues\x02."
      if $text =~ /\b(names|persons|teams)\b/i;

  return
      "the command \x02/invite $me\x02 (note the \x02/\x02) invites me\n" .
      "to join this channel. See also \x02$me, bye\x02 for how to\n" .
      "dismiss me from the channel."
      if $text =~ /\binvite\b/i;

  return
      "the command \x02$me, aaa $1 bbb\x02 defines that aaa is\n" .
      "an alias for the person with the username bbb on GitHub.\n" .
      "You can add \x02@\x02 in front of the GitHub username, if you wish.\n" .
      "Typically this command serves to define an equivalence\n" .
      "between an IRC nickname and a GitHub username, so that\n" .
      "you can say \x02action aaa:...\x02, where aaa is an IRC nick.\n" .
      "Aliases: is, =. Example: $me, denis $1 \@deniak"
      if $text =~ /(\bis\b|=)/i;

  return
      "the command \x02$me, $1 aaa\x02 tells me to stop\n" .
      "ignoring messages on IRC from user aaa.\n" .
      "See also \x02$me, help ignore\x02.\n" .
      "Example: $me, $1 agendabot"
      if $text =~ /\b(don't +ignore|do +not +ignore)\b/i;

  return
      "the command \x02$me, ignore aaa\x02 tells me to ignore\n" .
      "messages on IRC from user aaa.\n" .
      "See also \x02$me, help don't ignore\x02.\n" .
      "Example: $me, ignore rrsagent"
      if $text =~ /\bignore\b/i;

  return
      "I will respond to the command \x02$me, $1\x02\n" .
      "or \x02$me, $1?\x02 with the username that I use on GitHub.\n" .
      "Aliases: who are you, account, user, login."
      if $text =~ /\b(who +are +you|account|user|login)\b/i;

  return
      "the command \x02close #nn\x02 or \x02close yyy#nn\x02 or\n" .
      "\x02close xxx/yyy#nn\x02 or \x02yyy#nnn close\x02 tells me to close\n" .
      "GitHub issue number nn in repository xxx/yyy.\n" .
      "If you omit xxx or xxx/yyy, I will find\n" .
      "the repository in my list of repositories.\n" .
      "You can also give a URL: \x02close https://gith.../issues/nn\x02\n" .
      "See also \x02$me, help use\x02 for creating a list of repositories.\n" .
      "Example: close #1"
      if $text =~ /\bclose\b/i;

  return
      "the command \x02reopen #nn\x02 or \x02reopen yyy#nn\x02 or\n" .
      "\x02reopen xxx/yyy#nn\x02 tells me to reopen GitHub issue\n" .
      "number nn in repository xxx/yyy. If you omit xxx or xxx/yyy,\n" .
      "I will find the repository in my list of repositories.\n" .
      "You can also give a URL: \x02reopen https://gith.../issues/nn\x02\n" .
      "See also \x02$me, help use\x02 for creating a list of repositories.\n" .
      "Example: reopen #1"
      if $text =~ /\breopen\b/i;

  return
      "the command \x02$me, bye\x02 tells me to leave this channel.\n" .
      "See also \x02$me help invite\x02."
      if $text =~ /\bbye\b/i;

  return
      "the command \x02$me, $1\x02 lists at most 100 most recent open issues.\n" .
      "It can optionally be followed by \x02open\x02, \x02closed\x02 or \x02all\x02,\n" .
      "optionally followed by \x02issues\x02 or \x02actions\, followed by zero\n" .
      "or more conditions: \x02with labels label1, label2...\x02 or\n" .
      "\x02for name\x02 or \x02by name\x02 or \x02from repo\x02. I will list the\n" .
      "issues or actions that match those conditions.\n" .
      "See also \x02$me, next\x02.\n" .
      "Aliases: find, look up, get, search, search for, list.\n" .
      "Example: $me, list closed actions for pchampin from w3c/rdf-star"
      if $text =~ /\b(find|look +up|get|search|search +for|list)\b/i;

  return
      "the command \x02$1 #nn: text\x02 or\n" .
      "\x02$1 yyy#nn: text\x02 or \x02$1 xxx/yyy#nn: text\x02 or\n" .
      "\x02yyy#nn $1: text\x02 tells me to add some text to GitHub\n" .
      "issue nn in repository xxx/yyy.\n" .
      "The colon(:) is optional. If you omit xxx or xxx/yyy, I will\n" .
      "find the repository in my list of repositories.\n" .
      "You can also use a URL: \x02$1 https://gith.../issues/nn text\x02\n" .
      "See also \x02$me, help use\x02 for creating a list of repositories.\n" .
      "Aliases: comment, note.\n" .
      "Example: note #71: This is related to #70."
      if $text =~ /\b(comment|note)\b/i;

  return
      "the comment \x02$me, $1\x02 lists the next group of issues\n" .
      "if there are more than the previous find command could list.\n" .
      "See also \x02$me, find\x02."
      if $text =~ /\b(next)\b/i;

  return
      "I am a bot to look up and create GitHub issues and\n" .
      "action items. I am an instance of " .
      blessed($self) . " " . VERSION . ".\n" .
      "Try \x02$me, help commands\x02 or\n" .
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


# uniq -- return the list of distinct items in a list
sub uniq(@)
{
  my %seen;
  return grep {!$seen{$_}++} @_;
}


# esc -- escape characters for use in the value of a URL query parameter
sub esc($)
{
  my ($s) = @_;
  my ($octets);

  $octets = encode("UTF-8", $s);
  $octets =~ s/([^A-Za-z0-9._~!\$'()*,=:@\/-])/"%".sprintf("%02x",ord($1))/eg;
  return decode("UTF-8", $octets);
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

binmode(STDERR, ":utf8");

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
  nick => $opts{'n'} // 'gb',
  name => $opts{'N'} // 'GHURLBot '.VERSION.', '.HOME,
  channels => (defined $channel ? [$channel] : []),
  rejoinfile => $opts{'r'},
  mapfile => $opts{'m'} // 'ghurlbot.map',
  github_api_token => $opts{'t'},
  verbose => defined $opts{'v'});

$bot->run();



=encoding utf8

=head1 NAME

ghurlbot - IRC bot to manage GitHub issues or find their URLs

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

The nickname the bot runs under. Default is "gb".

=item B<-N> I<name>

The real name of the bot (for the purposes of the \whois command of
IRC). Default is "GHURLBot 0.1 see https://w3c.github.io/GHURLBot".

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

When the B<-r> option is used, B<ghurlbot> starts by trying to join
all channels in this file. It then updates the file whenever it leaves
or joins a channel. The file is a simple list of channel names, one
per line.

=back

=head1 BUGS

The I<map-file> and I<rejoin-file> only contain channel names, not the
names of IRC networks or IRC servers. B<ghurlbot> cannot check
that the channel names correspond to the IRC server it was started
with.

=head1 AUTHOR

Bert Bos E<lt>bert@w3.org>

=head1 SEE ALSO

L<Online manual|https://w3c.github.io/ghurlbot</manual.html>,
L<scribe.perl|https://w3c.github.io/scribe2/scribedoc.html>.

=cut
