use warnings;
use strict;
use utf8;

=head1 NAME

BarnOwl::Module::Jabber::Account

=head1 DESCRIPTION

An account class for use in the Jabber module. Based on
AnyEvent::XMPP::IM::Account. An account stores data pertaining to an
active bare JID; the connection itself may change as we disconnect and
reconnect.

=cut

package BarnOwl::Module::Jabber::Account;

use AnyEvent::XMPP::Ext::Disco;
use AnyEvent::XMPP::Ext::MUC;
use AnyEvent::XMPP::IM::Connection;
use Object::Event;
use Scalar::Util;

our @ISA = qw(Object::Event);

sub new {
    my $class = shift;
    my ($jid, $password, $args) = @_;

    my $self = bless { }, $class;
    $self->{jid} = $jid;
    $self->{password} = $password;
    $self->{args} = $args;

    # Create extensions
    $self->{ext}->{disco} = AnyEvent::XMPP::Ext::Disco->new;
    $self->{ext}->{muc} =
	AnyEvent::XMPP::Ext::MUC->new(disco => $self->{ext}->{disco});

    # Forward MUC events so functions have easy access to the account.
    for my $ev (qw(message error subject_change locked)) {
	$self->_forward_event($self->{ext}->{muc}, $ev, 'muc_' . $ev);
    }

    $self->{session_ready} = 0;

    $self->set_user_presence(undef, undef);
    return $self;
}

sub connection { $_[0]->{con} }

sub is_connected {
    my ($self) = @_;
    return $self->{con} && $self->{con}->is_connected;
}

sub is_session_ready {
    my ($self) = @_;
    return $self->{session_ready};
}

sub connect {
    my ($self) = @_;
    unless (defined $self->{con}) {
	$self->{session_ready} = 0;
	$self->{con} = AnyEvent::XMPP::IM::Connection->new(
	    jid => $self->{jid},
	    password => $self->{password},
	    # We'll send our own initial presence. AnyEvent::XMPP
	    # doesn't let you stuff away, etc. in there.
	    initial_presence => undef,
	    %{$self->{args} || {}});
	Scalar::Util::weaken $self;
	# Register callbacks we care about.
	$self->{con}->reg_cb(
	    session_ready => sub {
		$self->_on_session_ready(@_) if defined($self);
	    },
	    disconnect => sub {
		$self->_on_disconnect(@_) if defined($self);
	    },
	    bind_error => sub {
		$self->_on_bind_error(@_) if defined($self);
	    },
	    );

	# Others we just forward
	for my $ev (qw(message message_error
                       debug_recv debug_send
                       presence_xml presence_error
                       sasl_error iq_auth_error
                       contact_request_subscribe contact_subscribed
                       contact_did_unsubscribe contact_unsubscribed
                       roster_update)) {
	    $self->_forward_event($self->{con}, $ev);
	}

	for my $ext (values %{$self->{ext}}) {
	    $self->{con}->add_extension($ext);
	}

	$self->{con}->connect;
	$self->event(open_connection => $self->{con});
    }
}

sub _forward_event {
    my ($self, $obj, $obj_event, $acc_event) = @_;
    $acc_event = $obj_event unless defined($acc_event);
    Scalar::Util::weaken $self;
    $obj->reg_cb(
	$obj_event => sub {
	    my $obj = shift; # Don't forward the sender.
	    $self->event($acc_event => @_) if defined $self;
	},
    );
}

sub disconnect {
    my ($self, $msg) = @_;
    $self->{con}->disconnect($msg) if defined($self->{con});
    # This will emit a disconnect event and call _on_disconnect.
}

sub jid {
    my ($self) = @_;
    if ($self->is_connected) {
	return $self->{con}->jid;
    }
    return $self->{jid};
}

sub get_roster {
    my ($self) = @_;
    if (defined $self->{con}) {
	return $self->{con}->get_roster;
    }
    return undef;
}

sub muc {
    my ($self) = @_;
    return $self->{ext}->{muc};
}

sub _on_session_ready {
    my ($self, $conn) = @_;
    $self->{session_ready} = 1;
    # Send any presence we may have. Initial presence priority of 1
    # from Net::Jabber-based implementation.
    $self->_send_presence(priority => 1);
    my $jid = $self->jid;
    $self->event(connected => $jid);
}

sub _on_disconnect {
    my ($self, $conn, $host, $port, $message) = @_;
    if ($self->{session_ready}) {
	# We got disconnected after a successful connection.
	$self->{session_ready} = 0;
	delete $self->{con};
	$self->event(disconnect => $host, $port, $message);
    } else {
	# The connection never got through.
	delete $self->{con};
	$self->event(connect_error => $host, $port, $message);
    }
}

sub _on_bind_error {
    my ($self, $conn, $error, $resource) = @_;
    # TODO: Try to rebind without a resource.
    $self->disconnect;
}

sub _send_presence {
    my ($self, %args) = @_;
    my $show = $self->{show};
    my $status = $self->{status};
    # Treat '' and undef as equivalent in these to avoid pointless
    # undefined value warnings when comparing $show values. '' is not
    # a valid value anyway, so this is okay.
    undef $show if defined($show) && $show eq '';
    if ($self->is_session_ready) {
	$self->connection->send_presence(
	    undef, undef,
	    (defined $show ? (show => $show) : ()),
	    (defined $status ? (status => $status) : ()),
	    %args);
    }
}

sub _set_presence {
    my ($self, $show, $status) = @_;
    $self->{show} = defined($show) ? $show : '';
    $self->{status} = $status;
    $self->_send_presence();
}

sub set_user_presence {
    my ($self, $show, $status) = @_;
    # Save this for auto-away.
    $self->{user_show} = defined($show) ? $show : '';
    $self->_set_presence($show, $status);
}

sub auto_away {
    my ($self, $show) = @_;
    $show = '' unless defined($show);
    # If the user's presence is more away than the auto one, use that.
    if ($show eq '') {
	$show = $self->{user_show};
    } elsif ($show eq 'away') {
	$show = $self->{user_show} if $self->{user_show} eq 'xa';
    } elsif ($show eq 'xa') {
	# $show = 'xa';
    } else {
	die "Invalid value for \$show: $show";
    }
    # Only do anything if this would set a new status.
    $self->_set_presence($show, $self->{status}) unless $show eq $self->{show};
}

=head1 SEE ALSO

L<BarnOwl::Module::Jabber>

=cut

1;
