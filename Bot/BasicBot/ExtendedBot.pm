# Bot::BasicBot::ExtendedBot is a class to make writing IRC bots
# easier. Subclass it and override some methods to make your own IRC
# bot. See the documentation at the end.
#
# Author: Bert Bos <bert@w3.org>
# Created: 3 January 2021

package Bot::BasicBot::ExtendedBot;
use parent 'Bot::BasicBot';
$Bot::BasicBot::ExtendedBot::VERSION = '0.1';

use strict;
use warnings;
use utf8;
use POE::Kernel;
use POE::Session;


# run -- start the event loop
sub run
{
  my $self = shift;

  # create the callbacks to the object states
  POE::Session->create(
    object_states => [
      $self => {
	_start           => "start_state",
	die              => "die_state",

	irc_001          => "irc_001_state",
	irc_msg          => "irc_said_state",
	irc_public       => "irc_said_state",
	irc_ctcp_action  => "irc_emoted_state",
	irc_notice       => "irc_noticed_state",

	irc_disconnected => "irc_disconnected_state",
	irc_error        => "irc_error_state",

	irc_invite       => "irc_invite_state",
	irc_whois        => "irc_whois_state",
	irc_join         => "irc_chanjoin_state",
	irc_part         => "irc_chanpart_state",
	irc_kick         => "irc_kicked_state",
	irc_nick         => "irc_nick_state",
	irc_quit         => "irc_quit_state",

	irc_mode         => "irc_mode_state",

	fork_close       => "fork_close_state",
	fork_error       => "fork_error_state",

	irc_366          => "names_done_state",

	irc_332          => "topic_raw_state",
	irc_topic        => "topic_state",

	irc_shutdown     => "shutdown_state",

	irc_433          => "err_nicknameinuse_state",

	irc_raw          => "irc_raw_state",
	irc_raw_out      => "irc_raw_out_state",

	tick             => "tick_state",
      }
    ]
      );

  # and say that we want to receive said messages
  $poe_kernel->post($self->{IRCNAME}, 'register', 'all');

  # run
  $poe_kernel->run() if !$self->{no_run};
  return;
}


# invited -- do something when we are invited
sub invited { return }


# got_whois -- handle a whois reply. Can be overridden. Default does nothing.
sub got_whois { return }


# disconnected -- handle a server disconnect. Can be overridden.
sub disconnected
{
  my ($self, $server) = @_;
  $self->log("Lost connection to server $server.");
}


# nickname_in_use_error -- handle a nickname-in-use error. Can be overridden.
sub nickname_in_use_error
{
  my ($self, $message) = @_;
  $self->log("Error: $message");
}


# forkit -- start a background process, return a process object
sub forkit
{
  my $self = shift;
  my $args;

  # This method is the same as the inherited one, except that it
  # returns the created process rather than undef. (It returns undef
  # only if called with incorrect arguments.)

  if (ref($_[0])) {
    $args = shift;
  } else {
    my %args = @_;
    $args = \%args;
  }

  return undef if !$args->{run};

  $args->{handler}   = $args->{handler}   || "_fork_said";
  $args->{arguments} = $args->{arguments} || [];

  # Install a new handler in the POE kernel pointing to
  # $self->{$args{handler}}
  $poe_kernel->state($args->{handler}, $args->{callback} || $self);

  my $run;
  if (ref($args->{run}) =~ /^CODE/) {
    $run = sub {
      $args->{run}->($args->{body}, @{ $args->{arguments} })
    };
  } else {
    $run = $args->{run};
  }

  my $wheel = POE::Wheel::Run->new(
    Program      => $run,
    StdoutFilter => POE::Filter::Line->new(),
    StderrFilter => POE::Filter::Line->new(),
    StdoutEvent  => "$args->{handler}",
    StderrEvent  => "fork_error",
    CloseEvent   => "fork_close"
    );

  # Use a signal handler to reap dead processes
  $poe_kernel->sig_child($wheel->PID, "got_sigchld");

  # Store the wheel object in our bot, so we can retrieve/delete easily

  $self->{forks}{ $wheel->ID } = {
    wheel => $wheel,
    args  => {
      channel => $args->{channel},
      who     => $args->{who},
      address => $args->{address}
    }
  };
  return $wheel;
}


# say -- send text to a channel
sub say
{
  # Override the inherited method, because (1) we want to allow line
  # breaks also at hyphens, (2) we want a three-dot ellipsis, and (3)
  # we want to address somebody as "nick," instead of "nick:".

  # If we're called without an object ref, then we're handling saying
  # stuff from inside a forked subroutine, so we'll freeze it, and toss
  # it out on STDOUT so that POE::Wheel::Run's handler can pick it up.
  if (!ref $_[0]) {
    print $_[0], "\n";
    return 1;
  }

  # Otherwise, this is a standard object method

  my $self = shift;
  my $args;
  if (ref $_[0]) {
    $args = shift;
  } else {
    my %args = @_;
    $args = \%args;
  }

  my $body = $args->{body};

  # add the "Foo, bar" at the start
  if ($args->{channel} ne "msg" && defined $args->{address}) {
    $body = "$args->{who}, $body";
  }

  # work out who we're going to send the message to
  my $who = $args->{channel} eq "msg" ? $args->{who} : $args->{channel};

  if (!defined $who || !defined $body) {
    $self->log("Can't send a message without target and body\n"
	       . " called from "
	       . ( [caller]->[0] )
	       . " line "
	       . ( [caller]->[2] ) . "\n"
	       . " who = '$who'\n body = '$body'\n");
    return;
  }

  # If we have a long body, split it up..
  local $Text::Wrap::columns = 300;
  local $Text::Wrap::unexpand = 0; # no tabs
  local $Text::Wrap::break = qr/\s|(?<=-)/;
  local $Text::Wrap::separator2 = "\n";
  my $wrapped = Text::Wrap::wrap('', '… ', $body); #  =~ m!(.{1,300})!g;
  # I think the Text::Wrap docs lie - it doesn't do anything special
  # in list context
  my @bodies = split /\n+/, $wrapped;

  # Allows to override the default "PRIVMSG". Used by notice()
  my $irc_command = defined $args->{irc_command} &&
      $args->{irc_command} eq 'notice' ? 'notice' : 'privmsg';

  # Post an event that will send the message
  for my $body (@bodies) {
    my ($enc_who, $enc_body) = $self->charset_encode($who, $body);
    #warn "$enc_who => $enc_body\n";
    $poe_kernel->post($self->{IRCNAME}, $irc_command, $enc_who, $enc_body);
  }

  return;
}


# whois -- send a whois command to the server, argument is a nick
sub whois
{
  my $self = shift;
  my $nick = shift;
  $self->{IRCOBJ}->yield('whois', $nick);
}


# join_channel -- join a channel, the channel name is given as argument
sub join_channel
{
  my ($self, $channel, $key) = @_;
  $self->log("Trying to join '$channel'");
  $poe_kernel->post($self->{IRCNAME}, 'join', $self->charset_encode($channel),
		    $self->charset_encode($key // ''));
}


# part_channel -- leave a channel, the channel name is given as argument
sub part_channel
{
  my ($self, $channel) = @_;
  $self->log("Trying to part '$channel'\n");
  $poe_kernel->post($self->{IRCNAME}, 'part', $self->charset_encode($channel));
}


# invite -- invite somebody to a channel
sub invite
{
  my ($self, $nick, $channel) = @_;

  $poe_kernel->post($self->{IRCNAME}, 'invite', $self->charset_encode($nick),
		    $self->charset_encode($channel));
}


# connect_server -- connect to the previously set server, port, nick, etc.
sub connect_server
{
  my $self = shift;

  $poe_kernel->post(
    $self->{IRCNAME},
    'connect', {
      Nick      => $self->nick,
      Server    => $self->server,
      Port      => $self->port,
      Password  => $self->password,
      UseSSL    => $self->ssl,
      Flood     => $self->flood,
      LocalAddr => $self->localaddr,
      useipv6   => $self->useipv6,
      $self->charset_encode(
	Nick     => $self->nick,
	Username => $self->username,
	Ircname  => $self->name)});
}


# eval_error -- get or set a remembered error message
sub eval_error
{
  my $self = shift;
  $self->{eval_error} = shift if @_;
  return $self->{eval_error};
}


# die_state -- handle a DIE event
sub die_state
{
  my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
  $self->eval_error($ex->{error_str});
  warn $ex->{error_str};
  $self->{IRCOBJ}->yield('shutdown');
  $kernel->sig_handled();
  return;
}


# irc_disconnected_state -- handle disconnect event, call disconnected() method
sub irc_disconnected_state
{
  my ($self, $kernel, $server) = @_[OBJECT, KERNEL, ARG0];
  $self->disconnected($server);
  return;
}


# irc_said_state -- handle a normal message
sub irc_said_state
{
  irc_received_state( 'said', 'say', @_ );
  return;
}


# irc_emoted_state -- handle a /me message
sub irc_emoted_state
{
  irc_received_state( 'emoted', 'emote', @_ );
  return;
}


# irc_noticed_state -- handle a notice
sub irc_noticed_state
{
  irc_received_state( 'noticed', 'emote', @_ );
  return;
}


# irc_received_state -- handle certain message events
sub irc_received_state
{
  my $received = shift;
  my $respond  = shift;
  my ($self, $nick, $to, $body) = @_[OBJECT, ARG0, ARG1, ARG2];

  # This method is the same as the inherited one, but stricter when
  # deciding whether we are personally addressed: When our name is foo
  # and somebody says "foo," we assume we are addressed. But not if
  # somebody says "foo:", "foo-" or even "fool".

  ($nick, $to, $body) = $self->charset_decode($nick, $to, $body);

  my $return;
  my $mess = {};

  # Pass the raw body through
  $mess->{raw_body} = $body;

  # Work out who it was from
  $mess->{who} = $self->nick_strip($nick);
  $mess->{raw_nick} = $nick;

  # Right, get the list of places this message was sent to and work
  # out the first one that we're either a member of or is our nick.
  # The IRC protocol allows messages to be sent to multiple targets,
  # which is pretty clever. However, noone actually /does/ this, so we
  # can get away with this:

  my $channel = $to->[0];
  if (lc($channel) eq lc($self->nick)) {
    $mess->{channel} = "msg";
    $mess->{address} = "msg";
  } else {
    $mess->{channel} = $channel;
  }

  # Okay, work out if we're addressed or not

  $mess->{body} = $body;
  if ($mess->{channel} ne "msg") {
    my $own_nick = $self->nick;

    if ($mess->{body} =~ s/^(\Q$own_nick\E)\s*,\s*//i) {
      $mess->{address} = $1;
    }

    for my $alt_nick ($self->alt_nicks) {
      last if $mess->{address};
      if ($mess->{body} =~ s/^(\Q$alt_nick\E)\s*,\s*//i) {
	$mess->{address} = $1;
      }
    }
  }

  # Strip off whitespace before and after the message
  $mess->{body} =~ s/^\s+//;
  $mess->{body} =~ s/\s+$//;

  # Check if someone was asking for help
  if ($mess->{address} && $mess->{body} =~ /^help\b/i) {
    $mess->{body} = $self->help($mess) or return;
    $self->say($mess);
    return;
  }

  # Okay, call the said/emoted method
  $return = $self->$received($mess);

  ### What did we get back?

  # Nothing? Say nothing then
  return if !defined $return;

  # A string? Say it how we were addressed then
  if (!ref $return && length $return) {
    $mess->{body} = $return;
    $self->$respond($mess);
    return;
  }
}


# irc_invite_state -- handle an invite event, call our invited() method
sub irc_invite_state
{
  my ($self, $who, $channel) = @_[OBJECT, ARG0, ARG1];
  my $nick = $self->nick_strip($who);
  $self->invited({who => $nick, raw_nick => $who, channel => $channel});
}


# irc_whois_state -- handle a whois reply event, call our got_whois() method
sub irc_whois_state
{
  my ($self, $info) = @_[OBJECT, ARG0];
  $self->got_whois($info);
}


# fork_error_state -- handle a line of a forked process's output to stderr
sub fork_error_state
{
  my ($self, $body, $wheel_id) = @_[OBJECT, ARG0, ARG1];

  # The inherited method does nothing. We instead let log() handle the
  # line. (The default log() method sends the line to stderr.)
  $self->log($body);
}


sub shutdown_state
{
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  # $self->log("In shutdown_state");
  # $self->SUPER::shutdown_state(@_);
  $kernel->alias_remove($self->{ALIASNAME});
  for my $fork (values %{ $self->{forks} }) {
    $fork->{wheel}->kill('TERM');
  }
  $self->{forks} = {};
  # $self->log("Leaving shutdown_state");
  return;
}


sub err_nicknameinuse_state
{
  my ($self, $kernel, $server, $message) = @_[OBJECT, KERNEL, ARG0, ARG1];
  $self->nickname_in_use_error($message);
}


1;

=head1 NAME

Bot::BasicBot::ExtendedBot - simple irc bot baseclass

=head1 SYNOPSIS

  #!/usr/bin/perl
  use strict;
  use warnings;

  # Subclass Bot::BasicBot::ExtendedBot to provide event-handling methods.
  package UppercaseBot;
  use parent Bot::BasicBot::ExtendedBot;

  sub said
  {
    my $self      = shift;
    my $arguments = shift;    # Contains the message that the bot heard.

    # The bot will respond by uppercasing the message and echoing it back.
    $self->say(
        channel => $arguments->{channel},
        body    => uc $arguments->{body},
    );

    # The bot will shut down after responding to a message.
    $self->shutdown('I have done my job here.');
  }

  # Create an object of your Bot::BasicBot::ExtendedBot subclass and
  # call its run method.
  package main;

  my $bot = UppercaseBot->new(
      server      => 'irc.example.com',
      port        => '6667',
      channels    => ['#bottest'],
      nick        => 'UppercaseBot',
      name        => 'John Doe',
      ignore_list => [ 'laotse', 'georgeburdell' ],
  );
  $bot->run();

=head1 DESCRIPTION

The ExtendedBot class is designed to make writing an IRC bot
easy. Your bot would typically subclass ExtendedBot and override some
of the methods that correspond to events on IRC (somebody said
something, somebody joined, etc.)

ExtendedBot itself is a subclass of BasicBot. You should read its
documentation and look at its examples.

=head1 METHODS TO OVERRIDE

See the superclass, Bot::BasicBot, for the following methods: C<init>,
C<said>, C<emoted>, C<noticed>, C<chanjoin>, C<chanpart>,
C<got_names>, C<topic>, C<nick_change>, C<mode_change>, C<kicked>,
C<tick>, C<help>, C<connected>, C<userquit>, C<irc_raw> and
C<irc_raw_out>.

ExtendedBot defines the following additional methods that can be
overridden:

=head2 C<invited>

This method is called when we are invited to a channel. The default
does nothing, but your subclass can override it. It is called with a
hashref as argument that contains:

=over

=item * 'who', the nick of the IRC user that invited us.

=item * 'raw_nick', the nick and hostname of the IRC user that invited
us, which looks like "nick!hostname".

=item * 'channel', the name of the channel we are invited to.

=back

=head2 C<got_whois>

If the server sends a reply to our whois request, this method is
called. The default does nothing, but a subclass can override it. The
method is called with a hashref as argument. It is defined by
POE:Component::IRC and currently contains:

=over

=item * 'nick', the users nickname;

=item * 'user', the users username;

=item * 'host', their hostname;

=item * 'real', their real name;

=item * 'idle', their idle time in seconds;

=item * 'signon', the epoch time they signed on (will be undef if ircd
does not support this);

=item * 'channels', an arrayref listing visible channels they are on,
the channel is prefixed with '@','+','%' depending on whether they
have +o +v or +h;

=item * 'server', their server (might not be useful on some networks);

=item * 'oper', whether they are an IRCop, contains the IRC operator
string if they are, undef if they aren't.

=item * 'actually', some ircds report the user's actual ip address,
that'll be here;

=item * 'identified'. if the user has identified with NICKSERV (ircu,
seven, Plexus)

=item * 'modes', a string describing the user's modes (Rizon)

=back

=head2 C<disconnected>

This method is called when the connection to the server is lost. It
has one argument: the name of the server. The default method just
calls log(), but a subclass can override it.

=head2 C<nickname_in_use_error>

This method is called when the server sends a message that a nickname
is already in use, typically when we are trying to connect to the
server. It has one argument: the error message. The default method
just calls log(), but a subclass can override it.

=head1 BOT METHODS

See Bot::BasicBot for the methods C<schedule_tick>, C<say>, C<emote>,
C<notice>, C<reply>, C<pocoirc> and C<channel_state>.

Below are the methods that are not in BasicBot or that work (slightly)
differently:

=head2 C<forkit>

This method allows you to fork arbitrary background processes. They
will run concurrently with the main bot, returning their output to a
handler routine. You should call C<forkit> in response to specific
events in your C<said> routine, particularly for longer running
processes like searches, which will block the bot from receiving or
sending on channel whilst they take place if you don't fork them.

Inside the subroutine called by forkit, you can send output back to the
channel by printing lines (followd by C<\n>) to STDOUT. This has the same
effect as calling L<C<< Bot::BasicBot->say >>|say>.

The subroutine can also print lines to STDERR. This has the same
effect ad calling L<C<< Bot::BasicBot->log >>|log>. (The default log()
method simply writes to STDERR, btu you can override it.)

C<forkit> takes the following arguments:

=over 4

=item run

A coderef to the routine which you want to run. Bear in mind that the
routine doesn't automatically get the text of the query - you'll need
to pass it in C<arguments> (see below) if you want to use it at all.

Apart from that, your C<run> routine just needs to print its output to
C<STDOUT>, and it will be passed on to your designated handler.

=item handler

Optional. A method name within your current package which we can
return the routine's data to. Defaults to the built-in method
C<say_fork_return> (which simply sends data to channel).

=item callback

Optional. A coderef to execute in place of the handler. If used, the value
of the handler argument is used to name the POE event. This allows using
closures and/or having multiple simultaneous calls to forkit with unique
handler for each call.

=item body

Optional. Use this to pass on the body of the incoming message that
triggered you to fork this process. Useful for interactive processes
such as searches, so that you can act on specific terms in the user's
instructions.

=item who

The nick of who you want any response to reach (optional inside a
channel.)

=item channel

Where you want to say it to them in.  This may be the special channel
"msg" if you want to speak to them directly

=item address

Optional.  Setting this to a true value causes the person to be
addressed (i.e. to have "Nick: " prepended to the front of returned
message text if the response is going to a public forum.

=item arguments

Optional. This should be an anonymous array of values, which will be
passed to your C<run> routine. Bear in mind that this is not
intelligent - it will blindly spew arguments at C<run> in the order
that you specify them, and it is the responsibility of your C<run>
routine to pick them up and make sense of them.

=back

C<forkit> returns a POE::Wheel::Run object that encapsulates the
background process. You can, e.g., kill the process by calling the
C<kill> method on the object:

  my $process = $self->forkit({run => \&my_function});
  ...
  $process->kill();

C<forkit> returns C<undef> in case there was an error in the
arguments, notably a missing C<run> argument.

=head2 C<whois>

Call this method to send a whois query to the server. The argument
must be a nick name.

=head2 join_channel

Call this method to join a channel. The argument is the name of a
channel.

If the channel could indeed be joined, it will be added to the list of
channels that was passed to the C<new> method, which means the bot
will rejoin the channel when it next reconnects to the server (i.e.,
when you call the C<connect_server> method).

=head2 C<part_channel>

Call this method to leave a channel. The argument is the name of a
channel. When successful, the channel will be removed from the list of
channels passed to the C<new> method, so that the bot will not rejoin
the channel on the next .

=head2 C<invite>

Call this method to invite somebody to a channel. The arguments are a
nickname and the name of a channel..

=head2 C<connect_server>

Call this method to connect to a server. The method has no
arguments. The server, port, nick, etc. are those previously set (or
those passed to C<new>.) Note that calling C<run> causes the bot to
connect to a server, so the C<connect_server> is only useful if the
connection is lost.

=head1 ATTRIBUTES

See the superclass, Bot::BasicBot, for a description of the attributes
C<server>, C<port>, C<password>, C<ssl>, C<localaddr>, C<useipv6>,
C<nick>, C<alt_nicks>, C<username>, C<name>, C<channels>,
C<quit_message>, C<ignore_list>, C<charset>, C<flood>, C<no_run> and
C<webirc>.

=head2 C<eval_error>

If the bot calls C<die>, the error message is stored and can be
retrieved later with this method.

 my $bot = Bot::BasicBot::ExtendedBot->new(...);
 $bot->run();
 print $bot->eval_error() if $bot->eval_error();
 exit defined $bot->eval_error();

=head1 OTHER METHODS

See the superclass, Bot::BasicBot, for the methods C<AUTOLOAD>,
C<log>, C<ignore_nick>, C<nick_strip>, C<charset_decode> and
C<charset_encode>.

=head1 AUTHOR

Bert Bos C<< <bert@w3.org> >>.

=head1 CREDITS

The code was heavily inspired by Bot::BasicBot, which was originally
created by Mark Fowler, is currently maintained by David Precious
(BIGPRESH) C<< <davidp@preshweb.co.uk> >> and before that by Tom
Insam, Simon Kent E<lt>simon@hitherto.netE<gt> and Hinrik E<Ouml>rn
SigurE<eth>sson (L<hinrik.sig@gmail.com>)
