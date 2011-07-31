use strict;
use warnings;

package BarnOwl::Sepbar;

use AnyEvent;

my $count;
my $view;
my $start;
my $iter;
my $idle_source;

sub render {
    my $ret = '';

    $ret .= message_list_progress();

    my $append = BarnOwl::getvar("appendtosepbar");
    if ($append) {
        $ret .= " $append ";
    }
    return $ret;
}

sub message_list_progress {
    my $before = messages_before_point();
    my $count  = BarnOwl::message_list()->get_size();
    return "($before/$count)"
}


sub messages_before_point {
    BarnOwl::debug("redraw sepbar");
    if (!$view || $view ne BarnOwl::getview() ||
        !$iter->is_valid || !$start->is_valid) {
        $count = 1;
        $view  = BarnOwl::getview();
        $iter  = BarnOwl::curmsg_iterator();
        $start = BarnOwl::View::Iterator->new();
        $start->clone($iter);
    }
    my ($steps, $limit) = (0, 1000);
    my $point = BarnOwl::curmsg_iterator();

    my $step = sub {
        $steps++;
        return $steps <= $limit;
    };

    while (!$start->is_at_start && $step->()) {
        $start->prev;
        $count++;
    }
    while ($iter->cmp($point) < 0 && $step->()) {
        $iter->next;
        $count++;
    }
    while ($iter->cmp($point) > 0 && $step->()) {
        $iter->prev;
        $count--;
    }
    my $pfx = "";
    if ($steps >= $limit) {
        if (!$start->is_at_start) {
            $pfx = ">";
        } elsif ($iter->cmp($point) < 0) {
            $pfx = ">";
        } elsif ($iter->cmp($point) > 0) {
            $pfx = "<";
        }
        $idle_source ||= AnyEvent->idle(cb => sub {BarnOwl::command("nop")});
    } else {
        undef $idle_source;
    }
    return "$pfx$count";
}

1;

