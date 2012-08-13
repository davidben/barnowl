=head1 NAME

AnyEvent::XMPP::Socket - fork of AnyEvent::Socket

=head1 SYNOPSIS

   use AnyEvent::XMPP::Socket;
   
   tcp_connect "gameserver.deliantra.net", 13327, sub {
      my ($fh) = @_
         or die "gameserver.deliantra.net connect failed: $!";
   
      # enjoy your filehandle
   };
   
=head1 DESCRIPTION

This module is a fork of tcp_connect and resolve_addr from
AnyEvent::Socket 6.1. The fork is so tcp_connect returns the host
obtained from the SRV record.

=over 4

=cut

package AnyEvent::XMPP::Socket;

use Carp ();
use Errno ();
use Socket qw(AF_INET AF_UNIX SOCK_STREAM SOCK_DGRAM SOL_SOCKET SO_REUSEADDR);

use AnyEvent (); BEGIN { AnyEvent::common_sense }
use AnyEvent::Util qw(guard fh_nonblocking AF_INET6);
use AnyEvent::DNS ();

use AnyEvent::Socket qw(
   parse_ipv4
   parse_ipv6
   parse_address
   getprotobyname
   address_family
   format_address
);

use base 'Exporter';

our @EXPORT = qw(
   resolve_sockaddr
   tcp_connect
);

# used in cases where we may return immediately but want the
# caller to do stuff first
sub _postpone {
   my ($cb, @args) = (@_, $!);

   my $w; $w = AE::timer 0, 0, sub {
      undef $w;
      $! = pop @args;
      $cb->(@args);
   };
}

sub pack_sockaddr($$) {
   AnyEvent::Socket::pack_sockaddr($_[0], $_[1]);
}

sub unpack_sockaddr($) {
   AnyEvent::Socket::unpack_sockaddr($_[0]);
}

=item resolve_sockaddr $node, $service, $proto, $family, $type, $cb->([$family, $type, $proto, $sockaddr], ...)

Tries to resolve the given nodename and service name into protocol families
and sockaddr structures usable to connect to this node and service in a
protocol-independent way. It works remotely similar to the getaddrinfo
posix function.

For internet addresses, C<$node> is either an IPv4 or IPv6 address, an
internet hostname (DNS domain name or IDN), and C<$service> is either
a service name (port name from F</etc/services>) or a numerical port
number. If both C<$node> and C<$service> are names, then SRV records
will be consulted to find the real service, otherwise they will be
used as-is. If you know that the service name is not in your services
database, then you can specify the service in the format C<name=port>
(e.g. C<http=80>).

If a host cannot be found via DNS, then it will be looked up in
F</etc/hosts> (or the file specified via C<< $ENV{PERL_ANYEVENT_HOSTS}
>>). If they are found, the addresses there will be used. The effect is as
if entries from F</etc/hosts> would yield C<A> and C<AAAA> records for the
host name unless DNS already had records for them.

For UNIX domain sockets, C<$node> must be the string C<unix/> and
C<$service> must be the absolute pathname of the socket. In this case,
C<$proto> will be ignored.

C<$proto> must be a protocol name, currently C<tcp>, C<udp> or
C<sctp>. The default is currently C<tcp>, but in the future, this function
might try to use other protocols such as C<sctp>, depending on the socket
type and any SRV records it might find.

C<$family> must be either C<0> (meaning any protocol is OK), C<4> (use
only IPv4) or C<6> (use only IPv6). The default is influenced by
C<$ENV{PERL_ANYEVENT_PROTOCOLS}>.

C<$type> must be C<SOCK_STREAM>, C<SOCK_DGRAM> or C<SOCK_SEQPACKET> (or
C<undef> in which case it gets automatically chosen to be C<SOCK_STREAM>
unless C<$proto> is C<udp>).

The callback will receive zero or more array references that contain
C<$family, $type, $proto> for use in C<socket>, a binary
C<$sockaddr> for use in C<connect> (or C<bind>), and C<$host> from
the SRV record followed.

The application should try these in the order given.

Example:

   resolve_sockaddr "google.com", "http", 0, undef, undef, sub { ... };

=cut

our %HOSTS;
our $HOSTS;

if (
   open my $fh, "<",
      length $ENV{PERL_ANYEVENT_HOSTS} ? $ENV{PERL_ANYEVENT_HOSTS}
      : AnyEvent::WIN32                ? "$ENV{SystemRoot}/system32/drivers/etc/hosts"
      :                                  "/etc/hosts"
) {
   local $/;
   binmode $fh;
   $HOSTS = <$fh>;
} else {
   $HOSTS = "";
}

sub _parse_hosts() {
   #%HOSTS = ();

   for (split /\n/, $HOSTS) {
      s/#.*$//;
      s/^[ \t]+//;
      y/A-Z/a-z/;

      my ($addr, @aliases) = split /[ \t]+/;
      next unless @aliases;

      if (my $ip = parse_ipv4 $addr) {
         push @{ $HOSTS{$_}[0] }, $ip
            for @aliases;
      } elsif (my $ip = parse_ipv6 $addr) {
         push @{ $HOSTS{$_}[1] }, $ip
            for @aliases;
      }
   }

   undef $HOSTS;
}

sub resolve_sockaddr($$$$$$) {
   my ($node, $service, $proto, $family, $type, $cb) = @_;

   if ($node eq "unix/") {
      return $cb->() if $family || $service !~ /^\//; # no can do

      return $cb->([AF_UNIX, defined $type ? $type : SOCK_STREAM, 0, Socket::pack_sockaddr_un $service, undef]);
   }

   unless (AF_INET6) {
      $family != 6
         or return $cb->();

      $family = 4;
   }

   $cb->() if $family == 4 && !$AnyEvent::PROTOCOL{ipv4};
   $cb->() if $family == 6 && !$AnyEvent::PROTOCOL{ipv6};

   $family ||= 4 unless $AnyEvent::PROTOCOL{ipv6};
   $family ||= 6 unless $AnyEvent::PROTOCOL{ipv4};

   $proto ||= "tcp";
   $type  ||= $proto eq "udp" ? SOCK_DGRAM : SOCK_STREAM;

   my $proton = AnyEvent::Socket::getprotobyname $proto
      or Carp::croak "$proto: protocol unknown";

   my $port;

   if ($service =~ /^(\S+)=(\d+)$/) {
      ($service, $port) = ($1, $2);
   } elsif ($service =~ /^\d+$/) {
      ($service, $port) = (undef, $service);
   } else {
      $port = (getservbyname $service, $proto)[2]
              or Carp::croak "$service/$proto: service unknown";
   }

   # resolve a records / provide sockaddr structures
   my $resolve = sub {
      my @target = @_;

      my @res;
      my $cv = AE::cv {
         $cb->(
            map $_->[2],
            sort {
               $AnyEvent::PROTOCOL{$b->[1]} <=> $AnyEvent::PROTOCOL{$a->[1]}
                  or $a->[0] <=> $b->[0]
            }
            @res
         )
      };

      $cv->begin;
      for my $idx (0 .. $#target) {
         my ($node, $port) = @{ $target[$idx] };

         if (my $noden = parse_address $node) {
            my $af = address_family $noden;

            if ($af == AF_INET && $family != 6) {
               push @res, [$idx, "ipv4", [AF_INET, $type, $proton,
                           pack_sockaddr($port, $noden), $node]]
            }

            if ($af == AF_INET6 && $family != 4) {
               push @res, [$idx, "ipv6", [AF_INET6, $type, $proton,
                           pack_sockaddr($port, $noden), $node]]
            }
         } else {
            $node =~ y/A-Z/a-z/;

            my $hosts = $HOSTS{$node};

            # a records
            if ($family != 6) {
               $cv->begin;
               AnyEvent::DNS::a $node, sub {
                  push @res, [$idx, "ipv4", [AF_INET , $type, $proton, pack_sockaddr($port, parse_ipv4 $_), $node]]
                     for @_;

                  # dns takes precedence over hosts
                  push @res,
                     map [$idx, "ipv4", [AF_INET , $type, $proton, pack_sockaddr($port, $_), $node]],
                        @{ $hosts->[0] }
                     unless @_;

                  $cv->end;
               };
            }

            # aaaa records
            if ($family != 4) {
               $cv->begin;
               AnyEvent::DNS::aaaa $node, sub {
                  push @res, [$idx, "ipv6", [AF_INET6, $type, $proton, pack_sockaddr($port, parse_ipv6 $_), $node]]
                     for @_;

                  push @res,
                     map [$idx + 0.5, "ipv6", [AF_INET6, $type, $proton, pack_sockaddr($port, $_), $node]],
                        @{ $hosts->[1] }
                     unless @_;

                  $cv->end;
               };
            }
         }
      }
      $cv->end;
   };

   $node = AnyEvent::Util::idn_to_ascii $node
      if $node =~ /[^\x00-\x7f]/;

   # parse hosts
   if (defined $HOSTS) {
      _parse_hosts;
      undef &_parse_hosts;
   }

   # try srv records, if applicable
   if ($node eq "localhost") {
      $resolve->(["127.0.0.1", $port], ["::1", $port]);
   } elsif (defined $service && !parse_address $node) {
      AnyEvent::DNS::srv $service, $proto, $node, sub {
         my (@srv) = @_;

         if (@srv) {
            # the only srv record has "." ("" here) => abort
            $srv[0][2] ne "" || $#srv
               or return $cb->();

            # use srv records then
            $resolve->(
               map ["$_->[3].", $_->[2]],
                  grep $_->[3] ne ".",
                     @srv
            );
         } else {
            # no srv records, continue traditionally
            $resolve->([$node, $port]);
         }
      };
   } else {
      # most common case
      $resolve->([$node, $port]);
   }
}

=item $guard = tcp_connect $host, $service, $connect_cb[, $prepare_cb]

This is a convenience function that creates a TCP socket and makes a
100% non-blocking connect to the given C<$host> (which can be a DNS/IDN
hostname or a textual IP address, or the string C<unix/> for UNIX domain
sockets) and C<$service> (which can be a numeric port number or a service
name, or a C<servicename=portnumber> string, or the pathname to a UNIX
domain socket).

If both C<$host> and C<$port> are names, then this function will use SRV
records to locate the real target(s).

In either case, it will create a list of target hosts (e.g. for multihomed
hosts or hosts with both IPv4 and IPv6 addresses) and try to connect to
each in turn.

After the connection is established, then the C<$connect_cb> will be
invoked with the socket file handle (in non-blocking mode) as first, and
the peer ip (as a textual IP address) and peer port as second and third
arguments, respectively. The fourth argument is a code reference that you
can call if, for some reason, you don't like this connection, which will
cause C<tcp_connect> to try the next one (or call your callback without
any arguments if there are no more connections). In most cases, you can
simply ignore this argument. The fifth argument is the peer host, possibly
obtained from a SRV record.

   $cb->($filehandle, $ip, $port, $retry, $host)

If the connect is unsuccessful, then the C<$connect_cb> will be invoked
without any arguments and C<$!> will be set appropriately (with C<ENXIO>
indicating a DNS resolution failure).

The callback will I<never> be invoked before C<tcp_connect> returns, even
if C<tcp_connect> was able to connect immediately (e.g. on unix domain
sockets).

The file handle is perfect for being plugged into L<AnyEvent::Handle>, but
can be used as a normal perl file handle as well.

Unless called in void context, C<tcp_connect> returns a guard object that
will automatically cancel the connection attempt when it gets destroyed
- in which case the callback will not be invoked. Destroying it does not
do anything to the socket after the connect was successful - you cannot
"uncall" a callback that has been invoked already.

Sometimes you need to "prepare" the socket before connecting, for example,
to C<bind> it to some port, or you want a specific connect timeout that
is lower than your kernel's default timeout. In this case you can specify
a second callback, C<$prepare_cb>. It will be called with the file handle
in not-yet-connected state as only argument and must return the connection
timeout value (or C<0>, C<undef> or the empty list to indicate the default
timeout is to be used).

Note that the socket could be either a IPv4 TCP socket or an IPv6 TCP
socket (although only IPv4 is currently supported by this module).

Note to the poor Microsoft Windows users: Windows (of course) doesn't
correctly signal connection errors, so unless your event library works
around this, failed connections will simply hang. The only event libraries
that handle this condition correctly are L<EV> and L<Glib>. Additionally,
AnyEvent works around this bug with L<Event> and in its pure-perl
backend. All other libraries cannot correctly handle this condition. To
lessen the impact of this windows bug, a default timeout of 30 seconds
will be imposed on windows. Cygwin is not affected.

Simple Example: connect to localhost on port 22.

   tcp_connect localhost => 22, sub {
      my $fh = shift
         or die "unable to connect: $!";
      # do something
   };

Complex Example: connect to www.google.com on port 80 and make a simple
GET request without much error handling. Also limit the connection timeout
to 15 seconds.

   tcp_connect "www.google.com", "http",
      sub {
         my ($fh) = @_
            or die "unable to connect: $!";

         my $handle; # avoid direct assignment so on_eof has it in scope.
         $handle = new AnyEvent::Handle
            fh     => $fh,
            on_error => sub {
               AE::log error => "error $_[2]";
               $_[0]->destroy;
            },
            on_eof => sub {
               $handle->destroy; # destroy handle
               AE::log info => "done.";
            };

         $handle->push_write ("GET / HTTP/1.0\015\012\015\012");

         $handle->push_read (line => "\015\012\015\012", sub {
            my ($handle, $line) = @_;

            # print response header
            print "HEADER\n$line\n\nBODY\n";

            $handle->on_read (sub {
               # print response body
               print $_[0]->rbuf;
               $_[0]->rbuf = "";
            });
         });
      }, sub {
         my ($fh) = @_;
         # could call $fh->bind etc. here

         15
      };

Example: connect to a UNIX domain socket.

   tcp_connect "unix/", "/tmp/.X11-unix/X0", sub {
      ...
   }

=cut

sub tcp_connect($$$;$) {
   my ($host, $port, $connect, $prepare) = @_;

   # see http://cr.yp.to/docs/connect.html for some tricky aspects
   # also http://advogato.org/article/672.html

   my %state = ( fh => undef );

   # name/service to type/sockaddr resolution
   resolve_sockaddr $host, $port, 0, 0, undef, sub {
      my @target = @_;

      $state{next} = sub {
         return unless exists $state{fh};

         my $target = shift @target
            or return _postpone sub {
               return unless exists $state{fh};
               %state = ();
               $connect->();
            };

         my ($domain, $type, $proto, $sockaddr, $host) = @$target;

         # socket creation
         socket $state{fh}, $domain, $type, $proto
            or return $state{next}();

         fh_nonblocking $state{fh}, 1;
         
         my $timeout = $prepare && $prepare->($state{fh});

         $timeout ||= 30 if AnyEvent::WIN32;

         $state{to} = AE::timer $timeout, 0, sub {
            $! = Errno::ETIMEDOUT;
            $state{next}();
         } if $timeout;

         # now connect       
         if (
            (connect $state{fh}, $sockaddr)
            || ($! == Errno::EINPROGRESS # POSIX
                || $! == Errno::EWOULDBLOCK
                # WSAEINPROGRESS intentionally not checked - it means something else entirely
                || $! == AnyEvent::Util::WSAEINVAL # not convinced, but doesn't hurt
                || $! == AnyEvent::Util::WSAEWOULDBLOCK)
         ) {
            $state{ww} = AE::io $state{fh}, 1, sub {
               # we are connected, or maybe there was an error
               if (my $sin = getpeername $state{fh}) {
                  my ($port, $ip) = unpack_sockaddr $sin;

                  delete $state{ww}; delete $state{to};

                  my $guard = guard { %state = () };

                  $connect->(delete $state{fh}, format_address $ip, $port, sub {
                     $guard->cancel;
                     $state{next}();
                  }, $host);
               } else {
                  if ($! == Errno::ENOTCONN) {
                     # dummy read to fetch real error code if !cygwin
                     sysread $state{fh}, my $buf, 1;

                     # cygwin 1.5 continously reports "ready' but never delivers
                     # an error with getpeername or sysread.
                     # cygwin 1.7 only reports readyness *once*, but is otherwise
                     # the same, which is actually more broken.
                     # Work around both by using unportable SO_ERROR for cygwin.
                     $! = (unpack "l", getsockopt $state{fh}, Socket::SOL_SOCKET(), Socket::SO_ERROR()) || Errno::EAGAIN
                        if AnyEvent::CYGWIN && $! == Errno::EAGAIN;
                  }

                  return if $! == Errno::EAGAIN; # skip spurious wake-ups

                  delete $state{ww}; delete $state{to};

                  $state{next}();
               }
            };
         } else {
            $state{next}();
         }
      };

      $! = Errno::ENXIO;
      $state{next}();
   };

   defined wantarray && guard { %state = () }
}

=back

=head1 SECURITY CONSIDERATIONS

This module is quite powerful, with with power comes the ability to abuse
as well: If you accept "hostnames" and ports from untrusted sources,
then note that this can be abused to delete files (host=C<unix/>). This
is not really a problem with this module, however, as blindly accepting
any address and protocol and trying to bind a server or connect to it is
harmful in general.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

