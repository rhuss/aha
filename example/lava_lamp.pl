#!/usr/bin/perl 

=head1 NAME

   lava_lamp.pl --mode [watch|list|notify] --type [problem|recovery] \
                --name [AIN|switch name] --label <label> --debug

=head1 DESCRIPTION

Simple example how to use L<"AHA"> for controlling AVM AHA switches. I.e. 
it is used for using a Lava Lamp as a Nagios Notification handler.

It also tries to check that:

=over

=item * 

The lamp can be switched on only during certain time periods

=item *

The lamp doesn't run longer than a maximum time (e.g. 6 hours) 
(C<$LAMP_MAX_TIME>)

=item *

That the lamp is not switched on again after being switched off within a
certain time period (C<$LAMP_REST_TIME>)

=item *

That manual switches are detected and recorded

=back

This script knows three modes:

=over

=item watch

The "watch" mode is used for ensuring that the lamp is not switched on for
certain time i.e. during the night. The Variable C<$LAMP_ON_TIME_TABLE> can be
used to customize the time ranges on a weekday basis. 

=item notify

The "notify" mode is used by a notification handler, e.g. from Nagios or from
Jenkins. In this mode, the C<type> parameter is used for signaling whether the
lamp should be switched on ("problem") or off ("recovery").

=item list

This scripts logs all activities in a log file C<$LOG_FILE>. With the "list"
mode, all history entries can be viewed. 

=back

=cut

# ===========================================================================
# Configuration section

# AVM AHA Host for controlling the devices
my $AHA_HOST = "fritz.box";

# AVM AHA Password for connecting to the $AHA_HOST
my $AHA_PASSWORD = "s!cr!t";

# AVM AHA user role (undef if no roles are in use)
my $AHA_USER = undef;

# Name of AVM AHA switch
my $AHA_SWITCH = "Lava Lamp";

# Time how long the lamp should be at least be kept switched off (seconds)
my $LAMP_REST_TIME = 60 * 60;

# Maximum time a lamp can be on 
my $LAMP_MAX_TIME = 5 * 60 * 60; # 5 hours

# When the lamp can be switched on. The values can contain multiple time
# windows defined as arrays
my $LAMP_ON_TIME_TABLE = 
    {
     "Sun" => [ ["7:55",  "23:00"] ],
     "Mon" => [ ["6:55",  "23:00"] ],
     "Tue" => [ ["13:55", "23:00"] ],
     "Wed" => [ ["13:55", "23:00"] ],
     "Thu" => [ ["13:55", "23:00"] ],
     "Fri" => [ ["6:55",  "23:00"] ],
     "Sat" => [ ["7:55",  "23:00"] ],     
    };

# File holding the lamp's status
my $STATUS_FILE = "/var/run/lamp.status";

# Log file where to log to 
my $LOG_FILE = "/var/log/lamp.log";

# Stop file, when, if exists, keeps the lamp off
my $OFF_FILE = "/tmp/lamp_off";

# Time back in passed assumed when switching was done manually (seconds)
# I.e. if a manual state change is detected, it is assumed that it was back 
# that amount of seconds in the past (5 minutes here)
my $MANUAL_DELTA = 5 * 60;

# ============================================================================
# End of configuration

use AHA;
use Storable qw(fd_retrieve store_fd store);
use Data::Dumper;
use feature qw(say);
use Fcntl qw(:flock);
use Getopt::Long;
use strict;

my %opts = ();
GetOptions(\%opts, 'type=s','mode=s','debug!','name=s','label=s');

my $DEBUG = $opts{debug};

my $status = init_status();

my $mode = $opts{'mode'} || "list";

# Read in status and lock file
open (STATUS,"+<$STATUS_FILE") || die "Cannot open $STATUS_FILE: $!";
$status = fd_retrieve(*STATUS) || die "Cannot read $STATUS_FILE: $!";
flock(STATUS,2);

my ($aha,$switch,$is_on);

if ($mode ne "list") {
    # Name and connection parameters
    my $name = $opts{name} || $AHA_SWITCH;
    $aha = new AHA($AHA_HOST,$AHA_PASSWORD,$AHA_USER);
    $switch = new AHA::Switch($aha,$name);

    # Check current switch state    
    $is_on = $switch->is_on;

    # Log a manual switch which might has happened in between checks or notification
    log_manual_switch($status,$is_on);
}

if ($mode eq "list") {
    # List mode
    for my $hist (@{$status}) {
        print scalar(localtime($hist->[0])),": ",$hist->[1] ? "On " : "Off"," -- ",$hist->[2],"\n";
    }
} elsif ($mode eq "watch") {
   # Watchdog mode If the lamp is on but out of the period, switch it
    # off. Also, if it is running alredy for too long. $off_file can be used 
    # to switch it always off.
    if ($is_on && (-e $OFF_FILE || 
                   !check_on_period() || 
                   lamp_on_for_too_long($status))) {
        # Switch off lamp whether the stop file is switched on when we are off the
        # time window    
        $switch->off();
        update_status($status,0,$mode);
    } 
} elsif ($mode eq "notif") {
    my $type = $opts{type} || die "No notification type given";
    if (lc($type) =~ /^(problem|custom)$/ && !$is_on) {
        # If it is a problem and the lamp is not on, switch it on, 
        # but only if the lamp is not 'hot' (i.e. was not switch off only 
        # $LAMP_REST_TIME
        my $last_hist = get_last_entry($status);
        my $rest_time = time - $LAMP_REST_TIME;
        if (!$last_hist || $last_hist->[0] < $rest_time) {
            $switch->on();
            update_status($status,1,$mode,time,$opts{label});
        } else {
            info("Lamp not switched on because the lamp was switched off just before ",time - $last_hist->[0]," seconds");
        }
    } elsif (lc($type) eq 'recovery' && $is_on) {
        # If it is a recovery switch it off
        $switch->off();
        update_status($status,0,$mode,time,$opts{label});
    }
} else {
    die "Unknow mode '",$mode,"'";
}

if ($DEBUG) {
    info(Dumper($status));
}

# Store status and unlock
seek(STATUS, 0, 0); truncate(STATUS, 0);
store_fd $status,*STATUS;
close STATUS;

# ================================================================================================

sub info {
    if (open (F,">>$LOG_FILE")) {
        print F scalar(localtime),": ",join("",@_),"\n";
        close F;
    }
}

# Create empty status file if necessary
sub init_status {
    my $status = [];
    if (! -e $STATUS_FILE) {
        store $status,$STATUS_FILE;
    }
    return $status;
}

sub log_manual_switch {
    my $status = shift;
    my $is_on = shift;
    my $last = get_last_entry($status);
    if ($last && $is_on != $last->[1]) {
        # Change has been manualy in between the interval. Add an approx history entry
        update_status($status,$is_on,"manual",estimate_manual_time($status));
    }   
}

sub update_status {
    my $status = shift;
    my $is_on = shift;
    my $mode = shift;
    my $time = shift || time;
    my $label = shift;
    push @{$status},[ $time, $is_on, $mode];
    info($is_on ? "On " : "Off"," -- ",$mode, $label ? ": " . $label : "");
}

sub estimate_manual_time {
    my $status = shift;
    my $last_hist = get_last_entry($status);
    if ($last_hist) {
        my $now = time;
        my $last = $last_hist->[0];
        my $calc = $now - $MANUAL_DELTA;
        return $calc > $last ? $calc : $now - int(($now - $last) / 2);
    } else {
        return time - $MANUAL_DELTA;
    }
}

sub get_last_entry {
    my $status = shift;
    return $status && @$status ? $status->[$#{$status}] : undef;
}

sub check_on_period {
    my ($min,$hour,$wd) = (localtime)[1,2,6];
    my $day = qw(Sun Mon Tue Wed Thu Fri Sat)[$wd];
    my $periods = $LAMP_ON_TIME_TABLE->{$day};
    for my $period (@$periods) {
        my ($low,$high) = @$period;
        my ($lh,$lm) = split(/:/,$low);
        my ($hh,$hm) = split(/:/,$high);
        my $m = $hour * 60 + $min;
        return 1 if $m >= ($lh * 60 + $lm) && $m <= ($hh * 60 + $hm);
    }
    return 0;
}

sub lamp_on_for_too_long {
    my $status = shift;
    
    # Check if the lamp was on for more than max time in the duration now - max
    # time + 1 hour
    my $current = time;
    my $low_time = $current - $LAMP_MAX_TIME - $LAMP_REST_TIME;
    my $on_time = 0;
    my $i = $#{$status};
    while ($current > $low_time && $i >= 0) {
        my $t = $status->[$i]->[0];
        $on_time += $current - $t if $status->[$i]->[1];
        $current = $t;
        $i--;
    }
    if ($on_time >= $LAMP_MAX_TIME) {
        info("Lamp was on for " . $on_time . " in the last " . $LAMP_MAX_TIME + $LAMP_REST_TIME . 
             ". Not switching on therefore.");
        return 1;
    } else {
        return 0;
    }
}

=head1 LICENSE

lava_lampl.pl is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

lava_lamp.pl is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with lava_lamp.pl.  If not, see <http://www.gnu.org/licenses/>.

=head1 AUTHOR

roland@cpan.org

=cut

