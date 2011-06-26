use strict;
use warnings;

package BarnOwl::Module::Jabber;

=head1 NAME

BarnOwl::Module::Jabber

=head1 DESCRIPTION

This module implements Jabber support for barnowl.

=cut

use BarnOwl;
use BarnOwl::Hooks;
use BarnOwl::Message::Jabber;
use BarnOwl::Module::Jabber::AccountManager;
use BarnOwl::Completion::Util qw(complete_flags);

use Getopt::Long;
Getopt::Long::Configure(qw(no_getopt_compat prefix_pattern=-|--));

use AnyEvent;
use AnyEvent::XMPP::IM::Message;
use AnyEvent::XMPP::IM::Presence;
use AnyEvent::XMPP::Namespaces qw(xmpp_ns);
use AnyEvent::XMPP::Util qw(split_jid join_jid res_jid node_jid
                            bare_jid cmp_bare_jid is_bare_jid
                            dump_twig_xml);

use utf8;

our $VERSION = 0.1;

no warnings 'redefine';

################################################################################
# owl perl jabber support
#
# XXX Todo:
# Rosters for MUCs
# More user feedback
#  * joining MUC
#  * parting MUC
#  * presence (Roster and MUC)
# Implementing formatting and logging callbacks for C
# Appropriate callbacks for presence subscription messages.
#
################################################################################

our $accounts;
$accounts //= BarnOwl::Module::Jabber::AccountManager->new;
our $auto_away_timer;
our %completion_jids;

sub onStart {
    if ( *BarnOwl::queue_message{CODE} ) {
        register_owl_commands();
        register_keybindings();
        register_filters();
        $BarnOwl::Hooks::getBuddyList->add("BarnOwl::Module::Jabber::onGetBuddyList");
        $BarnOwl::Hooks::getQuickstart->add("BarnOwl::Module::Jabber::onGetQuickstart");
	BarnOwl::new_variable_bool("jabber:show_offline_buddies",
				   { default => 1,
				     summary => 'Show offline or pending buddies.'});
	BarnOwl::new_variable_bool("jabber:show_logins",
				   { default => 0,
				     summary => 'Show login/logout messages.'});
	BarnOwl::new_variable_bool("jabber:spew",
				   { default => 0,
				     summary => 'Display unrecognized Jabber messages.'});
	BarnOwl::new_variable_int("jabber:auto_away_timeout",
				  { default => 5,
				    summary => 'After minutes idle, auto away.',
				  });
	BarnOwl::new_variable_int("jabber:auto_xa_timeout",
				  { default => 15,
				    summary => 'After minutes idle, auto extended away.'
				});
	BarnOwl::new_variable_bool("jabber:reconnect",
				  { default => 1,
				    summary => 'Auto-reconnect when disconnected from servers.'
				});
	BarnOwl::new_variable_bool("jabber:verify_certificate",
				   { default => 1,
				     summary => 'Verify the server\'s certificate.'});
	# Default borrowed from Net::Jabber-based implementation.
	BarnOwl::new_variable_int("jabber:connect_timeout",
				   { default => 10,
				     summary => 'Seconds to wait before timing out of a connect.'});
    } else {
        # Our owl doesn't support queue_message. Unfortunately, this
        # means it probably *also* doesn't support BarnOwl::error. So just
        # give up silently.
    }
}

$BarnOwl::Hooks::startup->add("BarnOwl::Module::Jabber::onStart");

sub ensure_auto_away_timer {
    return if defined($auto_away_timer);
    $auto_away_timer = AnyEvent->timer(after => 5,
                                       interval => 5,
                                       cb => \&do_auto_away);
}

sub do_auto_away {
    if ( !$accounts->connected() ) {
        # We don't need this timer any more.
        undef $auto_away_timer;
        return;
    }

    # TODO: Instead of polling, provide the necessary hooks for perl
    # to (sanely) track idle time. AIM probably could use this too.

    my $auto_away = BarnOwl::getvar('jabber:auto_away_timeout');
    my $auto_xa = BarnOwl::getvar('jabber:auto_xa_timeout');
    my $idletime = BarnOwl::getidletime();

    my $auto_status = '';
    if ($auto_xa != 0 && $idletime >= (60 * $auto_xa)) {
        $auto_status = 'xa';
    } elsif ($auto_away != 0 && $idletime >= (60 * $auto_away)) {
        $auto_status = 'away';
    }

    foreach my $acc ($accounts->accounts) {
        $acc->auto_away($auto_status);
    }
}

#     foreach my $jid ( $conn->getJIDs() ) {
#         next unless $conn->jidActive($jid);
#
#         my $client = $conn->getConnectionFromJID($jid);
#         unless($client) {
#             $conn->removeConnection($jid);
#             BarnOwl::error("Connection for $jid undefined -- error in reload?");
#         }
#         my $status = $client->Process(0); # keep-alive
#         if ( !defined($status) ) {
#             $conn->scheduleReconnect($jid);
#         }
#         if ($::shutdown) {
#             do_logout($jid);
#             next;
#         }
#
#         if ($vars{status_changed}) {
#            my $p = new Net::Jabber::Presence;
#            $p->SetShow($vars{show}) if $vars{show};
#            $p->SetStatus($vars{status}) if $vars{status};
#            $client->Send($p);
#         }
#     }

sub blist_listBuddy {
    my $buddy  = shift;
    my $showOffline = shift;
    my $blistStr .= "    ";

    my $name = $buddy->name // node_jid($buddy->jid);

    $blistStr .= sprintf '%-15s %s', $name, $buddy->jid;

    my $presence = $buddy->get_priority_presence();
    if (defined $presence) {
        $blistStr .= " [" . ( $presence->show ? $presence->show : 'online' ) . "]";
        $blistStr .= " " . $presence->status if defined $presence->status;
        $blistStr = BarnOwl::Style::boldify($blistStr) if $showOffline;
    }
    else {
        return '' unless $showOffline;
	if ($buddy->subscription_pending) {
            $blistStr .= " [pending]";
	}
	elsif ($buddy->subscription eq 'none' || $buddy->subscription eq 'from') {
	    $blistStr .= " [not subscribed]";
	}
	else {
	    $blistStr .= " [offline]";
	}
    }
    return $blistStr . "\n";
}

# Sort, ignoring markup.
sub blistSort {
    return uc(BarnOwl::ztext_stylestrip($a)) cmp uc(BarnOwl::ztext_stylestrip($b));
}

sub getSingleBuddyList {
    my $acc = shift;
    my $showOffline = shift;
    my $blist = "";
    my $roster = $acc->get_roster();
    if ($roster) {
        my $jid = $acc->jid;
        $blist .= BarnOwl::Style::boldify("Jabber roster for $jid\n");

        # Process the roster into groups
        my %groups;
        my @ungrouped;
        for my $contact ($roster->get_contacts()) {
            if ($contact->groups()) {
                for my $group ($contact->groups()) {
                    push @{$groups{$group}}, $contact;
                }
            } else {
                push @ungrouped, $contact;
            }
        }

        # Show the grouped entries
        my @gTexts = ();
        foreach my $group (sort blistSort (keys %groups)) {
            my @bTexts = ();
            foreach my $buddy ( @{$groups{$group}} ) {
                push(@bTexts, blist_listBuddy($buddy, $showOffline));
            }
            push(@gTexts, "  Group: $group\n".join('',sort blistSort @bTexts));
        }

        if (@ungrouped) {
            my @bTexts = ();
            foreach my $buddy (@ungrouped) {
                push(@bTexts, blist_listBuddy($buddy, $showOffline));
            }
            push(@gTexts, "  [unsorted]\n".join('',sort blistSort @bTexts));
        }
        $blist .= join('', @gTexts);
    }
    return $blist;
}

sub onGetBuddyList {
    my $showOffline = BarnOwl::getvar('jabber:show_offline_buddies') eq 'on';
    my $blist = "";
    foreach my $acc ($accounts->accounts()) {
        $blist .= getSingleBuddyList($acc, $showOffline);
    }
    return $blist;
}

sub onGetQuickstart {
    return <<'EOF'
@b(Jabber:)
Type ':jabberlogin @b(username@mit.edu)' to log in to Jabber. The command
':jroster sub @b(somebody@gmail.com)' will request that they let you message
them. Once you get a message saying you are subscribed, you can message
them by typing ':jwrite @b(somebody@gmail.com)' or just 'j @b(somebody)'.
EOF
}

################################################################################
### Owl Commands
sub register_owl_commands() {
    BarnOwl::new_command(
        jabberlogin => \&cmd_login,
        {
            summary => "Log in to Jabber",
            usage   => "jabberlogin <jid> [<password>] [-h host] [-p port]"
        }
    );
    BarnOwl::new_command(
        jabberlogout => \&cmd_logout,
        {
            summary => "Log out of Jabber",
            usage   => "jabberlogout [-A|<jid>]",
            description => "jabberlogout logs you out of Jabber.\n\n"
              . "If you are connected to one account, no further arguments are necessary.\n\n"
              . "-A            Log out of all accounts.\n"
              . "<jid>         Which account to log out of.\n"
        }
    );
    BarnOwl::new_command(
        jwrite => \&cmd_jwrite,
        {
            summary => "Send a Jabber Message",
            usage   => "jwrite <jid> [-t <thread>] [-s <subject>] [-a <account>] [-m <message>]"
        }
    );
    BarnOwl::new_command(
        jaway => \&cmd_jaway,
        {
            summary => "Set Jabber away / presence information",
            usage   => "jaway [-s online|dnd|...] [-a <account>] [<message>]"
        }
    );
    BarnOwl::new_command(
        jlist => \&cmd_jlist,
        {
            summary => "Show your Jabber roster.",
            usage   => "jlist"
        }
    );
    BarnOwl::new_command(
        jmuc => \&cmd_jmuc,
        {
            summary     => "Jabber MUC related commands.",
            description => "jmuc sends Jabber commands related to MUC.\n\n"
              . "The following commands are available\n\n"
              . "join <muc>[/<nick>]\n"
              . "            Join a MUC (with a given nickname, or otherwise your JID).\n\n"
              . "part <muc>  Part a MUC.\n"
              . "            The MUC is taken from the current message if not supplied.\n\n"
              . "invite <jid> [<muc>]\n"
              . "            Invite <jid> to <muc>.\n"
              . "            The MUC is taken from the current message if not supplied.\n\n"
              . "configure [<muc>]\n"
              . "            Configures a MUC.\n"
              . "            Necessary to initalize a new MUC.\n"
              . "            At present, only the default configuration is supported.\n"
              . "            The MUC is taken from the current message if not supplied.\n\n"
              . "presence [<muc>]\n"
              . "            Shows the roster for <muc>.\n"
              . "            The MUC is taken from the current message if not supplied.\n\n"
              . "presence -a\n"
              . "            Shows rosters for all MUCs you're participating in.\n\n",
            usage => "jmuc <command> [<args>]"
        }
    );
    BarnOwl::new_command(
        jroster => \&cmd_jroster,
        {
            summary     => "Jabber roster related commands.",
            description => "jroster sends Jabber commands related to rosters.\n\n"
              . "The following commands are available\n\n"
              . "sub <jid>     Subscribe to <jid>'s presence. (implicit add)\n\n"
              . "add <jid>     Adds <jid> to your roster.\n\n"
              . "unsub <jid>   Unsubscribe from <jid>'s presence.\n\n"
              . "remove <jid>  Removes <jid> from your roster. (implicit unsub)\n\n"
              . "auth <jid>    Authorizes <jid> to subscribe to your presence.\n\n"
              . "deauth <jid>  De-authorizes <jid>'s subscription to your presence.\n\n"
              . "The following arguments are supported for all commands\n\n"
              . "-a <jid>      Specify which account to make the roster changes on.\n"
              . "              Required if you're signed into more than one account.\n\n"
              . "The following arguments only work with the add and sub commands.\n\n"
              . "-g <group>    Add <jid> to group <group>.\n"
              . "              May be specified more than once, will not remove <jid> from any groups.\n\n"
              . "-p            Purge. Removes <jid> from all groups.\n"
              . "              May be combined with -g.\n\n"
              . "-n <name>     Sets <name> as <jid>'s short name.\n\n"
              . "Note: Unless -n is used, you can specify multiple <jid> arguments.\n",
            usage       => "jroster <command> <args>"
        }
    );
}

sub register_keybindings {
    BarnOwl::bindkey(qw(recv j command start-command), 'jwrite ');
}

sub register_filters {
    BarnOwl::filter(qw(jabber type ^jabber$));
}

sub cmd_login {
    my $cmd = shift;
    local @ARGV = @_;
    my $getopt = Getopt::Long::Parser->new;
    my ($host, $port);

    $getopt->configure('pass_through', 'no_getopt_compat');
    $getopt->getoptions(
        'host=s' => \$host,
        'port=i' => \$port
    );
    my ($jid, $password) = @ARGV;

    my ($uid, $componentname, $resource) = split_jid($jid);

    if ( !$uid || !$componentname ) {
        die("usage: $cmd JID\n");
    }

    $resource ||= 'barnowl';
    $jid = join_jid($uid, $componentname, $resource);

    if (defined($accounts->get_account($jid))) {
	die("Already logged in as " . bare_jid($jid) . "\n");
    }

    if (defined($password)) {
	return do_login($jid, $password, $host, $port);
    }

    BarnOwl::start_password("Password for $jid: ", sub { do_login($jid, $_[0], $host, $port); });
}

sub do_login {
    my ($jid, $password, $host, $port) = @_;

    my $connect_timeout = BarnOwl::getvar('jabber:connect_timeout');
    my $verify_cert = BarnOwl::getvar('jabber:verify_certificate') eq 'on';
    my $acc = $accounts->add_account($jid, $password,
                                     { connect_timeout => $connect_timeout,
				       verify_cert => $verify_cert,
				       (defined $host ? (host => $host) : ()),
				       (defined $port ? (port => $port) : ()),
				     });
    if (!$acc) {
	# This shouldn't happen because we also check earlier.
	die("Already logged in as " . bare_jid($jid) . "\n");
    }
    $acc->reg_cb(
	connected => \&on_connected,
	connect_error => \&on_connect_error,
	disconnect => \&on_disconnect,

	message => \&on_message,
	message_error => \&on_message_error,

        presence_xml => \&on_presence_xml,
	presence_error => \&on_presence_error,

	contact_request_subscribe => \&on_contact_request_subscribe,
	contact_did_unsubscribe => \&on_contact_did_unsubscribe,
	contact_subscribed => \&on_contact_subscribed,
	contact_unsubscribed => \&on_contact_unsubscribed,

        roster_update => \&on_roster_update,

        debug_send => \&on_debug_send,
        debug_recv => \&on_debug_recv,

        muc_message => \&on_muc_message,
        muc_subject_change => \&on_muc_subject_change,
        muc_locked => \&on_muc_locked,
        muc_error => \&on_muc_error,
        );
    $acc->connect;

    ensure_auto_away_timer();

    return;
}

sub do_logout {
    my $acc = shift;
    my $jid = $acc->jid;
    my $disconnected = $accounts->remove_account($acc);
    queue_admin_msg("Jabber disconnected ($jid).") if $disconnected;
}

sub cmd_logout {
    return "You are not logged into Jabber." unless $accounts->connected();
    # Logged into multiple accounts
    if ( $accounts->connected() > 1 ) {
        # Logged into multiple accounts, no account specified.
        if ( !$_[1] ) {
            my $errStr =
              "You are logged into multiple accounts. Please specify an account to log out of.\n";
            foreach my $acc ($accounts->accounts()) {
                $errStr .= "\t" . $acc->jid . "\n";
            }
            queue_admin_msg($errStr);
        }
        # Logged into multiple accounts, account specified.
        else {
            if ( $_[1] eq '-A' )    #All accounts.
            {
		foreach my $acc ($accounts->accounts()) {
                    do_logout($acc);
                }
            }
            else                    #One account.
            {
                my $acc = $accounts->get_account($_[1]);
                do_logout($acc) if defined($acc);
            }
        }
    }
    else                            # Only one account logged in.
    {
        do_logout(($accounts->accounts())[0]);
    }
    return "";
}

sub cmd_jlist {
    if (!$accounts->connected) {
        die("You are not logged in to Jabber.\n");
    }
    BarnOwl::popless_ztext( onGetBuddyList() );
}

sub cmd_jwrite {
    if ( !$accounts->connected() ) {
        die("You are not logged in to Jabber.\n");
    }

    my $jwrite_to;
    my $jwrite_from;
    my $jwrite_thread;
    my $jwrite_subject;
    my $jwrite_body;
    my ($to, $from);
    my $jwrite_type    = "chat";

    my @args = @_;
    shift;
    local @ARGV = @_;
    my $gc;
    GetOptions(
        'thread=s'  => \$jwrite_thread,
        'subject=s' => \$jwrite_subject,
        'account=s' => \$from,
        'message=s' => \$jwrite_body,
    ) or die("Usage: jwrite <jid> [-t <thread>] [-s <subject>] [-a <account>]\n");

    if ( scalar @ARGV != 1 ) {
        die("Usage: jwrite <jid> [-t <thread>] [-s <subject>] [-a <account>]\n");
    }
    else {
      $to = shift @ARGV;
    }

    my @candidates = guess_jwrite($from, $to);
    # TODO: only connected accounts or something?

    unless(scalar @candidates) {
        die("Unable to resolve JID $to\n");
    }

    @candidates = grep {defined $_->[0]} @candidates;

    unless(scalar @candidates) {
        if(!$from) {
            die("You must specify an account with -a\n");
        } else {
            die("Unable to resolve account $from\n");
        }
    }

    my $acc;
    ($acc, $jwrite_to, $jwrite_type) = @{$candidates[0]};
    $jwrite_from = $acc->jid;

    my $jwrite_data = {
        to      => $jwrite_to,
        from    => $jwrite_from,
        subject => $jwrite_subject,
        thread  => $jwrite_thread,
        type    => $jwrite_type
    };

    if (defined($jwrite_body)) {
        process_owl_jwrite($jwrite_data, $jwrite_body);
        return;
    }

    if(scalar @candidates > 1) {
        BarnOwl::message(
            "Warning: Guessing account and/or destination JID"
           );
    } else  {
        BarnOwl::message(
            "Type your message below.  End with a dot on a line by itself.  ^C will quit."
           );
    }

    my @cmd = ('jwrite', $jwrite_to, '-a', $jwrite_from);
    push @cmd, '-t', $jwrite_thread if $jwrite_thread;
    push @cmd, '-s', $jwrite_subject if $jwrite_subject;

    BarnOwl::start_edit_win(BarnOwl::quote(@cmd),
			    sub { process_owl_jwrite($jwrite_data, $_[0]); });
}

sub cmd_jmuc {
    die "You are not logged in to Jabber" unless $accounts->connected();
    my $ocmd = shift;
    my $cmd  = shift;
    if ( !$cmd ) {

        #XXX TODO: Write general usage for jmuc command.
        return;
    }

    my %jmuc_commands = (
        join      => \&jmuc_join,
        part      => \&jmuc_part,
        invite    => \&jmuc_invite,
        configure => \&jmuc_configure,
        presence  => \&jmuc_presence
    );
    my $func = $jmuc_commands{$cmd};
    if ( !$func ) {
        die("jmuc: Unknown command: $cmd\n");
    }

    {
        local @ARGV = @_;
        my $jid;
        my $muc;
        my $m = BarnOwl::getcurmsg();
        if ( $m && $m->is_jabber && $m->{jtype} eq 'groupchat' ) {
            $muc = $m->{room};
            $jid = $m->{to};
        }

        my $getopt = Getopt::Long::Parser->new;
        $getopt->configure('pass_through', 'no_getopt_compat');
        $getopt->getoptions( 'account=s' => \$jid );
        # FIXME: jmuc presence -a doesn't work with multiple accounts
        # here. Also, we've changed default JID logic (probably for
        # the better).
        my $acc = resolveConnectedJID($jid);
        die $acc->jid . " is not connected" unless $acc->is_session_ready;
        return $func->( $acc, $muc, @ARGV );
    }
}

sub jmuc_join {
    my ( $acc, $muc, @args ) = @_;
    local @ARGV = @args;
    my $password;
    GetOptions( 'password=s' => \$password );

    $muc = shift @ARGV
      or die("Usage: jmuc join <muc> [-p <password>] [-a <account>]\n");

    die("Error: Must specify a fully-qualified MUC name (e.g. barnowl\@conference.mit.edu)\n")
        unless $muc =~ /@/;

    my $room = bare_jid($muc);
    my $nick = res_jid($muc) // bare_jid($acc->jid);

    # FIXME: This probably doesn't work if we want to change nicks.
    $acc->muc->join_room($acc->connection, $room, $nick,
                         history => { chars => 0 },
                         create_instant => 0,
                         password => $password);
    $completion_jids{$room} = 1;
    return;
}

sub jmuc_part {
    my ( $acc, $muc, @args ) = @_;

    $muc = shift @args if scalar @args;
    die("Usage: jmuc part [<muc>] [-a <account>]\n") unless $muc;

    my $room = $acc->muc->get_room($acc->connection, $muc);
    if (defined($room)) {
        my $jid = $acc->jid;
        $room->send_part(undef, sub { queue_admin_msg("$jid has left $muc."); });
    } else {
        die("Error: Not joined to $muc\n");
    }
}

sub jmuc_invite {
    my ( $acc, $muc, @args ) = @_;

    my $invite_jid = shift @args;
    $muc = shift @args if scalar @args;

    die("Usage: jmuc invite <jid> [<muc>] [-a <account>]\n")
      unless $muc && $invite_jid;

    my $room = $acc->muc->get_room($acc->connection, $muc);
    if (defined($room)) {
        my $msg = AnyEvent::XMPP::IM::Message->new(
            connection => $acc->connection,
            to => $room->jid,
        );
        $msg->append_creation(sub {
            my ($w) = @_;
            $w->addPrefix(xmpp_ns('muc_user'), '');
            $w->startTag([xmpp_ns('muc_user'), 'x']);
              $w->startTag([xmpp_ns('muc_user'), 'invite'],
                           to => $invite_jid);
                # TODO: Allow adding a reason?
              $w->endTag();
            $w->endTag();
        });
        $msg->send();
        queue_admin_msg($acc->jid . " has invited $invite_jid to $muc.");
    } else {
        die("Error: Not joined to $muc\n");
    }
}

sub jmuc_configure {
    my ( $acc, $muc, @args ) = @_;
    $muc = shift @args if scalar @args;
    die("Usage: jmuc configure [<muc>]\n") unless $muc;

    my $room = $acc->muc->get_room($acc->connection, $muc);
    unless (defined($room)) {
        my $jid = $acc->jid;
        die "Account $jid is not joined to $muc\n";
    }
    $room->make_instant(sub {
        my ($self, $err) = @_;
        if (defined($self)) {
            queue_admin_msg("Accepted default configuration for $muc");
            $room->event(enter => $room, $room->get_me);
        } else {
            queue_admin_msg("Failed to configure $muc: " . $err->string);
            $room->event(join_error => $room, $err);
        }
    });
}

sub jmuc_presence_single {
    my $room = shift;
    my @users = $room->get_users();

    my $presence = "JIDs present in " . $room->jid;
    $completion_jids{$room->jid} = 1;
    unless (@users) {
        # Net::Jabber's logic for anonymous MUCs was merely if they
        # had sent presence information yet. It's possible we can do
        # better and do a disco query for muc_nonanonymous.
        $presence .= " [anonymous MUC]";
    }
    $presence .= "\n\t";
    $presence .= join("\n\t", map {pp_muc_user($room, $_);} @users) . "\n";
    return $presence;
}

sub pp_muc_user {
    my ($room, $user) = @_;
    
    my $nick = $user->nick;
    my $full = $user->real_jid;
    if (defined($full) && $full ne $nick) {
        return "$nick ($full)";
    } else {
        return "$nick";
    }
}

sub jmuc_presence {
    my ( $acc, $muc, @args ) = @_;

    $muc = shift @args if scalar @args;
    die("Usage: jmuc presence [<muc>]\n") unless $muc;

    if ($muc eq '-a') {
        my $str = "";
        foreach my $acc ($accounts->accounts) {
            my $jid = $acc->jid;
            $str .= BarnOwl::Style::boldify("Conferences for $jid:\n");
            foreach my $room ($acc->muc->get_rooms($acc->connection)) {
                $str .= jmuc_presence_single($room)."\n";
            }
        }
        BarnOwl::popless_ztext($str);
    }
    else {
        my $room = $acc->muc->get_room($acc->connection, $muc);
        die("No such muc: $muc\n") unless defined($room);
        BarnOwl::popless_ztext(jmuc_presence_single($room));
    }
}


#XXX TODO: Consider merging this with jmuc and selecting off the first two args.
sub cmd_jroster {
    die "You are not logged in to Jabber" unless $accounts->connected();
    my $ocmd = shift;
    my $cmd  = shift;
    if ( !$cmd ) {

        #XXX TODO: Write general usage for jroster command.
        return;
    }

    my %jroster_commands = (
        sub      => \&jroster_sub,
        unsub    => \&jroster_unsub,
        add      => \&jroster_add,
        remove   => \&jroster_remove,
        auth     => \&jroster_auth,
        deauth   => \&jroster_deauth
    );
    my $func = $jroster_commands{$cmd};
    if ( !$func ) {
        die("jroster: Unknown command: $cmd\n");
    }

    {
        local @ARGV = @_;
        my $jid;
        my $name;
        my @groups;
        my $purgeGroups;
        my $getopt = Getopt::Long::Parser->new;
        $getopt->configure('pass_through', 'no_getopt_compat');
        $getopt->getoptions(
            'account=s' => \$jid,
            'group=s' => \@groups,
            'purgegroups' => \$purgeGroups,
            'name=s' => \$name
        );
        my $acc = resolveConnectedJID($jid);
        die $acc->jid . " is not connected" unless $acc->is_session_ready;
        return $func->( $acc, $name, \@groups, $purgeGroups,  @ARGV );
    }
}

sub cmd_jaway {
    my $cmd = shift;
    local @ARGV = @_;
    my $getopt = Getopt::Long::Parser->new;
    my ($jid, $show);

    $getopt->configure('pass_through', 'no_getopt_compat');
    $getopt->getoptions(
        'account=s' => \$jid,
        'show=s'    => \$show
    );
    my $acc = resolveConnectedJID($jid);

    my %valid = (away => 1, chat => 1, dnd => 1, xa => 1, online => 1);
    unless (!defined($show) || $valid{$show}) {
        die "Valid values for show are online, chat, dnd, away, xa\n";
    }

    undef $show if $show eq 'online';
    $acc->set_user_presence($show, @ARGV ? join(' ', @ARGV) : undef);
    return;
}


sub jroster_sub {
    my $acc = shift;
    my $name = shift;
    my @groups = @{ shift() };
    my $purgeGroups = shift;
    my $baseJID = bare_jid($acc->jid);

    my $roster = $acc->get_roster;

    # Adding lots of users with the same name is a bad idea.
    $name = "" unless (1 == scalar(@ARGV));

    foreach my $to (@ARGV) {
        # Update the contact in the roster, but only if we have
        # something to change to avoid pointless messages.
        my $contact = $roster->get_contact($to);
        if (!defined($contact) || !$contact->is_on_roster ||
            defined($name) || @groups || $purgeGroups) {
            jroster_add($acc, $name, \@groups, $purgeGroups, ($to));
        }

        # For simplicity, send this directly instead of waiting for
        # the jroster callback to give us back a Contact object. RFC
        # 6121 explicitly allows the client to send the roster set and
        # presence request in either order.
        $acc->connection->send_presence('subscribe', undef, to => $to);
        queue_admin_msg("You ($baseJID) have requested a subscription to ($to)'s presence.");
    }
}

sub jroster_unsub {
    my $acc = shift;
    my $name = shift;
    my @groups = @{ shift() };
    my $purgeGroups = shift;
    my $baseJID = bare_jid($acc->jid);

    foreach my $to (@ARGV) {
        $acc->connection->send_presence('unsubscribe', undef, to => $to);
        queue_admin_msg("You ($baseJID) have unsubscribed from ($to)'s presence.");
    }
}

sub jroster_add {
    my $acc = shift;
    my $name = shift;
    my @groups = @{ shift() };
    my $purgeGroups = shift;
    my $baseJID = bare_jid($acc->jid);

    my $roster = $acc->get_roster();

    # Adding lots of users with the same name is a bad idea.
    undef $name unless (1 == scalar(@ARGV));

    foreach my $to (@ARGV) {
        my $update_cb = sub {
            my ($contact, $err) = @_;
            if (defined($err)) {
                my $msg = "$baseJID: error adding $to to roster: " . $err->string;
                queue_admin_msg($msg);
            } else {
                my $msg = "$baseJID: "
                    . (defined($contact->name) ? $contact->name . ' ' : '')
                    . "(" . $contact->jid . ")"
                    . " is on your roster in the following groups: { "
                    . join(" , ", $contact->groups)
                    . " }";
                queue_admin_msg($msg);
            }
        };

        my $contact = $roster->get_contact($to);
        if (defined($contact)) {
            # Go through AnyEvent::XMPP because updating groups is
            # async and we want queries to take this into account
            # if, e.g., calling jroster add twice in a row.
            $contact->send_update($update_cb,
				  (defined($name) ? (name => $name) : ()),
                                  ($purgeGroups ? 'groups' : 'add_group')
                                  => \@groups);
        } else {
            $roster->new_contact($to, $name, \@groups, $update_cb);
        }
    }
}

sub jroster_remove {
    my $acc = shift;
    my $name = shift;
    my @groups = @{ shift() };
    my $purgeGroups = shift;
    my $baseJID = bare_jid($acc->jid);

    my $roster = $acc->get_roster();
    foreach my $to (@ARGV) {
        $roster->delete_contact($to, sub {
            my ($err) = @_;
            if (defined($err)) {
                my $msg = "$baseJID: error removing $to from roster: " . $err->string;
                queue_admin_msg($msg);
            } else {
                queue_admin_msg("You ($baseJID) have removed ($to) from your roster.");
            }
        });
    }
}

sub jroster_auth {
    my $acc = shift;
    my $name = shift;
    my @groups = @{ shift() };
    my $purgeGroups = shift;
    my $baseJID = bare_jid($acc->jid);

    foreach my $to (@ARGV) {
        $acc->connection->send_presence('subscribed', undef, to => $to);
        queue_admin_msg("($to) has been subscribed to your ($baseJID) presence.");
    }
}

sub jroster_deauth {
    my $acc = shift;
    my $name = shift;
    my @groups = @{ shift() };
    my $purgeGroups = shift;
    my $baseJID = bare_jid($acc->jid);

    foreach my $to (@ARGV) {
        $acc->connection->send_presence('unsubscribed', undef, to => $to);
        queue_admin_msg("($to) has been unsubscribed from your ($baseJID) presence.");
    }
}

################################################################################
### Owl Callbacks
sub process_owl_jwrite {
    my $fields = shift;
    my $body = shift;

    my $acc = $accounts->get_account($fields->{from});
    unless (defined($acc) && $acc->is_session_ready) {
	die $acc->jid . " is not connected.\n";
    }

    $body =~ s/\n\z//;
    my $msg = new AnyEvent::XMPP::IM::Message(
	to   => $fields->{to},
	from => $acc->jid, # Use the full JID from the account; we may
			   # have had a reconnect in the meantime.
	type => $fields->{type});
    $msg->thread($fields->{thread}) if defined($fields->{thread});
    $msg->add_subject($fields->{subject}) if defined($fields->{subject});
    $msg->add_body($body) if defined($body);

    if ( $fields->{type} ne 'groupchat') {
        # Queue an outgoing message for personals.
        my $m = message_to_obj($acc, $msg, { direction => 'out' } );
        BarnOwl::queue_message($m);
    }

    $msg->send($acc->connection);
    BarnOwl::message("");   # Kludge to make the ``type your message...'' message go away
}

### XMPP Callbacks

sub on_connected {
    my ($acc, $jid) = @_;
    BarnOwl::admin_message('Jabber', "Connected to jabber as " . $jid);
}

sub on_connect_error {
    my ($acc, $host, $port, $message) = @_;
    # If the account isn't there, then we logged out explicitly.
    return unless $accounts->get_account($acc->jid) == $acc;
    my $jid = $acc->jid;
    BarnOwl::error("Error in connecting to $jid: $message");
    $accounts->remove_account($acc);
}

sub on_disconnect {
    my ($acc, $host, $port, $message) = @_;
    # If the account isn't there, then we logged out explicitly.
    return unless $accounts->get_account($acc->jid) == $acc;
    my $jid = $acc->jid;
    $message //= '';
    BarnOwl::admin_message('Jabber', "Disconnected from $jid: $message");
    # TODO: Reconnect logic.
    $accounts->remove_account($acc);
}

sub on_message {
    my ($acc, $msg) = @_;
    if (defined($msg->any_body()) || BarnOwl::getvar('jabber:spew') eq 'on') {
        BarnOwl::queue_message(message_to_obj($acc, $msg, { direction => 'in' }));
    }
}

sub on_message_error {
    my ($acc, $error) = @_;
    BarnOwl::queue_message(message_error_to_obj($error, { direction => 'in' }));
}

sub on_presence_xml {
    my ($acc, $node) = @_;

    # We really want to use the presence_update event, but
    # unfortunately it's not really unusable. There's a bug where it
    # gets sent even for 'subscribed', etc. More importantly, on
    # 'unavailable', we don't even get the node, so we can't pull out
    # any logout statuses and such. Instead, watch for all presence
    # stanzas and react.
    #
    # Code based on AnyEvent::XMPP::IM::Connection::handle_presence.

    if (defined ($node->attr ('to')) && !cmp_bare_jid ($node->attr ('to'), $acc->jid)) {
        return; # ignore presence that is not for us
    }

    my $type = $node->attr('type');
    $type //= 'available';
    if ($type eq 'available' || $type eq 'unavailable') {
        my $to = $node->attr('to');
        my $from = $node->attr('from');
        return unless (BarnOwl::getvar('jabber:show_logins') eq 'on');

        # Create a presence object to parse most of this gunk.
        my $p = AnyEvent::XMPP::IM::Presence->new();
        $p->update($node);

        # Skip delayed messages. They're likely delayed unavailable
        # messages sent according to RFC 6121, section 4.3.2, step 3.
        return if $p->is_delayed();

        my %props = (
            to => $to,
            from => $from,
            recipient => bare_jid($to),
            sender => bare_jid($from),
            type => 'jabber',
            jtype => $type,
            defined($p->status()) ? (status => $p->status()) : (),
            defined($p->show()) ? (show => $p->show()) : (),
            xml => $node->as_string(),
            direction => 'in');

        if ($type eq 'available') {
            $props{body} = "$from is now online. ";
	    # TODO: Either include compat code in perlmessages or swap
	    # this to login when the time comes.
	    $props{loginout} = 'login';
        } else {
            $props{body} = "$from is now offline. ";
	    $props{loginout} = 'logout';
        }
        BarnOwl::queue_message(BarnOwl::Message->new(%props));
    }
}

sub on_presence_error {
    my ($acc, $err) = @_;

    my $code = $err->code // '';
    my $error = $err->text // '';
    # TODO: may as well pull out all the other fields.
    BarnOwl::error("Jabber: $code $error");
}

sub on_contact_request_subscribe {
    my ($acc, $roster, $contact, $message) = @_;
    my $from = $contact->jid;
    my $to = $acc->jid;
    my %props = (
        to => $to,
        from => $from,
        type => 'admin',
    # TODO: Get the XML node to attach to the message.
    #   xml => $p->GetXML(),
        adminheader => 'Jabber presence: subscribe',
        direction => 'in');
    # TODO: Do something with $message. (Although RFC 6121 says the
    # client MAY ignore it to help prevent "presence subscription
    # spam".)

    $props{body} = "Allow user ($from) to subscribe to your ($to) presence?\n" .
                   "(Answer with the `yes' or `no' commands)";
    $props{yescommand} = BarnOwl::quote('jroster', 'auth', $from, '-a', $to);
    $props{nocommand} = BarnOwl::quote('jroster', 'deauth', $from, '-a', $to);
    $props{question} = "true";
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_contact_did_unsubscribe {
    my ($acc, $roster, $contact, $message) = @_;
    my $from = $roster->jid;
    my $to = $acc->jid;
    my %props = (
        to => $to,
        from => $from,
    # TODO: Get the XML node to attach to the message.
    #   xml => $p->GetXML(),
        type => 'admin',
        adminheader => 'Jabber presence: unsubscribe',
        direction => 'in');
    # TODO: Do something with $message. (Although RFC 6121 says the
    # client MAY ignore it to help prevent "presence subscription
    # spam".)

    $props{body} = "The user ($from) has been unsubscribed from your ($to) presence.\n";
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_contact_subscribed {
    my ($acc, $roster, $contact, $message) = @_;
    if (BarnOwl::getvar('jabber:spew') eq 'on') {
	# TODO: Get the XML node to attach to the message as before.
	queue_admin_msg("ignoring: subscribed notice from "
			. $contact->jid . " to " . $acc->jid);
    }

    # RFC 3921 says we should respond to this with a "subscribe"
    # but this causes a flood of sub/sub'd presence packets with
    # some servers, so we won't. We may want to detect this condition
    # later, and have per-server settings.
    #
    # It also appears this has been removed in RFC 6121.
}

sub on_contact_unsubscribed {
    my ($acc, $roster, $contact, $message) = @_;
    if (BarnOwl::getvar('jabber:spew') eq 'on') {
	# TODO: Get the XML node to attach to the message as before.
	queue_admin_msg("ignoring: unsubscribed notice from "
			. $contact->jid . " to " . $acc->jid);
    }

    # RFC 3921 says we should respond to this with a "subscribe"
    # but this causes a flood of sub/sub'd presence packets with
    # some servers, so we won't. We may want to detect this condition
    # later, and have per-server settings.
    #
    # It also appears this has been removed in RFC 6121.
}

sub on_roster_update {
    my ($acc, $roster, $contacts) = @_;
    # Instead of adding every contact we ever see to the completion
    # list, just do it when we receive the roster.
    for my $contact (@$contacts) {
        # TODO: Just use the roster (and MUC list) itself as the
        # completion list?
        $completion_jids{$contact->jid} = 1;
        $completion_jids{$contact->name} = 1 if defined($contact->name);
    }
}

sub on_muc_message {
    my ($acc, $room, $msg, $is_echo) = @_;
    
    # TODO: Huh? What's this?
    # HACK IN PROGRESS (ignoring delayed messages)
    return if $msg->is_delayed();

    # TODO: Handle MUC invites here (or in AnyEvent::XMPP).
    if (defined($msg->any_body()) || BarnOwl::getvar('jabber:spew') eq 'on') {
        BarnOwl::queue_message(message_to_obj($acc, $msg, { direction => 'in' }));
    }
}

sub on_muc_subject_change {
    my ($acc, $room, $msg, $is_echo) = @_;

    # Just forward it to the normal message path. We distinguish
    # subject changes when serializing.
    BarnOwl::queue_message(message_to_obj($acc, $msg, { direction => 'in' }));
}

sub on_muc_locked {
    my ($acc, $room) = @_;

    my $room_jid = $room->jid;
    my %props = (
        room => $room_jid,
        to => $acc->jid,
        type => 'admin',
        adminheader => 'Jabber MUC: created',
        direction => 'in');

    $props{body} = "Created new room $room_jid. Accept default configuration?\n" .
                   "(Answer with the `yes' command)";
    $props{yescommand} = BarnOwl::quote('jmuc', 'configure', $room_jid, '-a', $acc->jid);
    # TODO: This is not likely to be implemented in the near future,
    # but when we get enough rope to present data forms, we should
    # allow arbitrary room configuration.
    # $props{nocommand} = UNIMPLEMENTED
    $props{question} = "true";
    BarnOwl::queue_message(BarnOwl::Message->new(%props));
}

sub on_muc_error {
    my ($acc, $room, $error) = @_;

    # Work around a quirk of conference.jabber.org. When creating a
    # new room, we receive both presence with 201 status code AND an
    # item-not-found error. Suppress the latter.
    if ($error->type eq 'room_locked' &&
        defined($room->get_me) &&
        $room->get_me->did_create_room &&
        BarnOwl::getvar('jabber::spew') ne 'on') {
        BarnOwl::debug("Suppressing room_locked error on a room we created.");
        return;
    }

    my $msg_error = $error->message_error();
    if (defined($msg_error)) {
        BarnOwl::queue_message(message_error_to_obj($msg_error, { direction => 'in' }));
    } else {
        BarnOwl::error("Jabber: " . $error->string);
    }
}

my $have_twig = 1;
sub dump_twig_xml_or_raw {
    # Pretty-printed XML is nice, but keep the XML::Twig dependency
    # optional.
    my $data = shift;
    eval { $data = dump_twig_xml($data); } if $have_twig;
    $have_twig = 0 if $@;
    return $data;
}

sub on_debug_recv {
    my ($acc, $data) = @_;
    return unless BarnOwl::getvar('debug') eq 'on';
    BarnOwl::debug(sprintf("XMPP recv>> %s\n%s",
                           $acc->jid, dump_twig_xml_or_raw($data)));
}

sub on_debug_send {
    my ($acc, $data) = @_;
    return unless BarnOwl::getvar('debug') eq 'on';
    BarnOwl::debug(sprintf("XMPP send>> %s\n%s",
                           $acc->jid, dump_twig_xml_or_raw($data)));
}

### Helper functions

sub message_to_obj {
    my $acc = shift;
    my $j   = shift;
    my %props = (type => 'jabber',
                 %{$_[0]});

    my $dir = $props{direction};

    my $jtype = $props{jtype} = $j->type();
    my $from = $j->from();
    my $to   = $j->to();

    $props{from} = $from;
    $props{to}   = $to;

    $props{recipient}  = bare_jid($to);
    $props{sender}     = bare_jid($from);
    # TODO: Support picking a language
    $props{subject}    = $j->any_subject() if defined($j->any_subject());
    $props{thread}     = $j->thread() if defined($j->thread());
    if ( defined $j->any_body() ) {
        $props{body}   = $j->any_body();
        $props{body}  =~ s/\xEF\xBB\xBF//g; # Strip stray Byte-Order-Marks.
    }
    if (defined $j->xml_node()) {
	# TODO: stringify outgoing messages too?
	$props{xml}        = $j->xml_node()->as_string();
    }

    # TODO: do something about delayed messages

    # TODO: See about using the various convenience methods
    # AnyEvent::XMPP::Ext::MUC::Message provides.
    if ($jtype eq 'groupchat') {
	# Only handle outgoing groupchat messages. We can duplicate
	# the code for serializing incoming groupchat messages if we
	# ever create them.
	die "Got outgoing groupchat message!" unless $dir eq 'in';

        my $nick = $props{nick} = res_jid($from);
        my $room = $props{room} = bare_jid($from);

        # Try to get the full JID of the user.
        my $room_obj = $acc->muc->get_room($acc->connection, $room);
        if (defined($room_obj)) {
            my $user = $room_obj->get_user($nick);
            if (defined($user)) {
                $props{from} = $user->real_jid // $props{from};
            }
        }

        $props{sender} = $nick // $room;
        $props{recipient} = $room;

        if ( defined($props{subject}) && !defined($props{body}) ) {
            $props{body} =
              '[' . $nick . " has set the topic to: " . $props{subject} . "]";
        }
    } elsif ($jtype eq 'error' || $jtype eq 'headline') {
	# Do nothing; 'error' should be instantiated as
	# AnyEvent::XMPP::Error::Message anyway and processed
	# elsewhere.
    } else {
        # 'chat', 'normal', or something unknown (which is assumed to
        # be 'normal')
        $props{private} = 1;

        # Check to see if we're doing personals with someone in a muc.
        # If we are, show the full jid because the base jid is the room.
        $props{sender} = $props{from}
          if (defined($acc->muc->get_room($acc->connection, $from)));
        $props{recipient} = $props{to}
          if (defined($acc->muc->get_room($acc->connection, $to)));

        # Populate completion.
        if ($dir eq 'in') {
            $completion_jids{ $props{sender} }= 1;
        }
        else {
            $completion_jids{ $props{recipient} } = 1;
        }
    }

    return BarnOwl::Message->new(%props);
}

sub message_error_to_obj {
    my $j   = shift;
    my %props = (type => 'admin',
                 %{$_[0]});

    my $dir = $props{direction};

    my ($from, $to);
    my $node = $j->xml_node();
    if (defined($node)) {
        # Unfortunately, these guys aren't completely pre-parsed.
        $from = $node->attr('from');
        $to   = $node->attr('to');
        $props{xml} = $node->as_string();
    }

    $props{from} = $from;
    $props{to}   = $to;
    $props{jtype} = 'error';

    $props{recipient}  = bare_jid($to);
    $props{sender}     = bare_jid($from);

    $props{error}      = $j->text();
    $props{error_code} = $j->code();
    $props{error_type} = $j->type();
    $props{error_condition} = $j->condition();

    if (defined($props{from})) {
        $props{body}     = sprintf("Error sending to %s: %s/%s (type %s)\n%s",
                                   $props{from} // '',
                                   $props{error_code} // '',
                                   $props{error_condition} // '',
                                   $props{error_type} // '',
                                   $props{error} // '');
    } else {
        $props{body}     = sprintf("Error: %s/%s (type %s)\n%s",
                                   $props{error_code} // '',
                                   $props{error_condition} // '',
                                   $props{error_type} // '',
                                   $props{error} // '');
    }
    return BarnOwl::Message->new(%props);
}

sub queue_admin_msg {
    my $err = shift;
    BarnOwl::admin_message("Jabber", $err);
}

# Matches the account with the given JID. Otherwise searches for a
# string match among all accounts.
# FIXME: The connected bit in this function is a lie.
sub resolveConnectedJID {
    my $givenJIDStr = shift;

    if (!defined($givenJIDStr)) {
        die "Not connected to Jabber.\n" unless $accounts->connected;
        # FIXME: This is somewhat a hack, but better than the old
        # code. It's probably not terrible asserting that every
        # command takes account with -a at this layer.
        die "You must specify an account with -a <jid>.\n" unless $accounts->connected == 1;
        return ($accounts->accounts())[0];
    }

    # Account fully specified.
    my $acc = $accounts->get_account($givenJIDStr);
    if (defined($acc)) {
	return $acc;
    }

    # String match
    else {
        my $strMatchingAcc;
        my $strMatches = "";
        my $strAmbiguous = 0;

        foreach my $acc ( $accounts->accounts() ) {
	    my $jid = $acc->jid;
            if ( $jid =~ /\Q$givenJIDStr\E/ ) {
                $strAmbiguous = 1 if defined($strMatchingAcc);
                $strMatchingAcc = $acc;
                $strMatches .= "\t$jid\n";
            }
        }

        # Need further disambiguation.
        if ($strAmbiguous) {
            my $errStr =
                "Ambiguous account reference. Please be more specific.\n";
            die($errStr.$strMatches);
        }

        # It's this one, by substring.
        elsif (defined($strMatchingAcc)) {
            return $strMatchingAcc;
        }

        # Not one of ours.
        else {
            die("Invalid account: $givenJIDStr\n");
        }

    }
    return;
}

sub resolveDestJID {
    my ($to, $acc) = @_;

    # If it already looks like a JID, return unconditionally.
    return $to if $to =~ /@/;

    # Otherwise, try to match by name on the roster.
    my $roster = $acc->get_roster();
    if (defined($roster)) {
        for my $contact ($roster->get_contacts()) {
            if ($contact->name eq $to) {
                return $contact->jid;
            }
            if (node_jid($contact->jid) eq $to) {
                return $contact->jid;
            }
        }
    }
    # Nope. No luck.
    return undef;
}

sub resolveType {
    my $to_jid = shift;
    my $from_acc = shift;
    return unless defined($from_acc);
    if (is_bare_jid($to_jid) &&
	defined($from_acc->muc->get_room($from_acc->connection, $to_jid))) {
	# Sending to a MUC has type groupchat.
        return 'groupchat';
    } else {
        return 'chat';
    }
}

sub guess_jwrite {
    # Heuristically guess what jids a jwrite was meant to be going to/from
    my ($from, $to) = (@_);
    my ($from_jid, $to_jid);
    my @matches;
    if (defined($from)) {
        my $from_acc = resolveConnectedJID($from);
        die("Unable to resolve account $from\n") unless defined $from_acc;
        $to_jid = resolveDestJID($to, $from_acc);
        push @matches, [$from_acc, $to_jid] if $to_jid;
    } else {
	for my $acc ($accounts->accounts) {
            $to_jid = resolveDestJID($to, $acc);
            if(defined($to_jid)) {
                push @matches, [$acc, $to_jid];
            }
        }
    }

    for my $m (@matches) {
        my $type = resolveType($m->[1], $m->[0]);
        push @$m, $type;
    }

    return @matches;
}

################################################################################
### Completion

sub complete_user_or_muc { return keys %completion_jids; }
sub complete_account { return map { bare_jid($_->jid) } $accounts->accounts; }

sub complete_jwrite {
    my $ctx = shift;
    return complete_flags($ctx,
                          [qw(-t -i -s)],
                          {
                              "-a" => \&complete_account,
                          },
                          \&complete_user_or_muc
        );
}

BarnOwl::Completion::register_completer(jwrite => sub { BarnOwl::Module::Jabber::complete_jwrite(@_) });

1;
