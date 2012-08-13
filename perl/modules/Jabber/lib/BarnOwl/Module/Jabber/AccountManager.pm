use warnings;
use strict;

=head1 NAME

BarnOwl::Module::Jabber::AccountManager

=head1 DESCRIPTION

A class to keep track of all the active accounts in the barnowl jabber
module

=cut

package BarnOwl::Module::Jabber::AccountManager;

use AnyEvent::XMPP::Util qw(prep_bare_jid);
use BarnOwl::Module::Jabber::Account;

our @ISA = qw(Object::Event);

# Based on AnyEvent::XMPP::Client.

sub new {
    my $class = shift;
    return bless { }, $class;
}

sub get_account {
    my ($self, $jid) = @_;
    my $bj = prep_bare_jid $jid;
    return $self->{$bj};
}

sub add_account {
    my ($self, $jid, $password, $args) = @_;
    my $bj = prep_bare_jid $jid;

    if (defined($self->{$bj})) {
	return undef;
    }

    my $acc = BarnOwl::Module::Jabber::Account->new($jid, $password,
						    $args);
    $self->{$bj} = $acc;
    my $self_weak = $self;
    Scalar::Util::weaken($self_weak);
    $acc->reg_cb(
        connect_error => sub { $self_weak->_remove_account($_[0]); },
        disconnect => sub { $self_weak->_remove_account($_[0]); },
        );
    return $acc;
}

sub _remove_account {
    my ($self, $acc) = @_;
    my $bj = prep_bare_jid $acc->jid;
    if (defined($self->{$bj}) && $self->{$bj} == $acc) {
        delete $self->{$bj};
    }
}

sub logout {
    my ($self, $acc) = @_;
    $acc->disconnect("Logged out");
    $self->_remove_account($acc);
}

sub connected {
    my $self = shift;
    return scalar keys %{ $self };
}

sub accounts {
    my ($self) = @_;
    return values %$self;
}

# TODO: Implement reconnect.

# sub scheduleReconnect {
#     my $self = shift;
#     my $jidStr = shift;
#     return 0 unless exists $self->{$jidStr};
#     BarnOwl::admin_message(Jabber => "Disconnected from jabber account $jidStr");

#     unless (BarnOwl::getvar('jabber:reconnect') eq 'on') {
#         return $self->removeConnection($jidStr);
#     }

#     BarnOwl::remove_io_dispatch($self->{$jidStr}->{Client}->{fileno}) if $self->{$jidStr}->{Client}->{fileno};
#     $self->{$jidStr}->{Client}->Disconnect()
#       if $self->{$jidStr}->{Client};

#     $self->{$jidStr}->{Status} = "reconnecting";
#     $self->{$jidStr}->{ReconnectBackoff} = 5;
#     $self->{$jidStr}->{ReconnectAt} = time + $self->{$jidStr}->{ReconnectBackoff};
#     return 1;
# }

# sub tryReconnect {
#     my $self = shift;
#     my $jidStr = shift;
#     my $force = shift;

#     return 0 unless exists $self->{$jidStr};
#     return 0 unless $self->{$jidStr}{Status} eq "reconnecting";
#     return 0 unless $force or (time > $self->{$jidStr}{ReconnectAt});

#     $self->{$jidStr}->{ReconnectBackoff} *= 2;
#     $self->{$jidStr}->{ReconnectBackoff} = 60*5
#         if $self->{$jidStr}->{ReconnectBackoff} > 60*5;
#     $self->{$jidStr}->{ReconnectAt} = time + $self->{$jidStr}->{ReconnectBackoff};

#     my $client = $self->{$jidStr}->{Client};
#     my $status = $client->Connect;
#     return 0 unless $status;

#     my @result = $client->AuthSend( %{ $self->{$jidStr}->{Auth} } );
#     if ( !@result || $result[0] ne 'ok' ) {
#         $self->removeConnection($jidStr);
#         BarnOwl::error( "Error in jabber reconnect: " . join( " ", @result ) );
#         return 0;
#     }
#     $self->{$jidStr}->{Roster} = $client->Roster();
#     $self->{$jidStr}->{Status} = "available";
#     $client->onConnect($self, $jidStr);
#     foreach my $muc ($client->MUCs()) {
#         $muc->Join($muc->{ARGS});
#     }

#     return 1;
# }

1;
