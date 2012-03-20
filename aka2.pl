#!/usr/bin/env perl

# Copyright (C) 2012 brjannc <brjannc at gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use DBI;

my $NAME = "aka2";
my $VERSION = "0.3.2";
my $DESC = "also-known-as plugin for XChat";

my $DEBUG = 0;

my $database_handle = db_connect();
my $enabled_channels = load($database_handle);
my $hook_options = { data => [$database_handle, $enabled_channels] };

Xchat::register($NAME, $VERSION, $DESC, \&unload);
Xchat::hook_print("Join", \&on_join, $hook_options);
Xchat::hook_print("Change Nick", \&on_change_nick, $hook_options);
Xchat::hook_command("aka", \&on_command, $hook_options);

Xchat::print("* $NAME $VERSION loaded :)");

sub load {
    my ($dbh) = @_;
    my $channels = {};

    eval {
	$dbh->begin_work;
	db_init($dbh);
	$dbh->commit;

	vacuum($dbh);

	# load the enabled channels into a hash "set"
	$channels = $dbh->selectall_hashref(q/SELECT channel FROM channels/, "channel");
    };

    if ($@) {
	Xchat::print("* $NAME: initialization failed ($@)");
	eval { $dbh->rollback };
	die;
    }

    Xchat::print("* $NAME watching: " . join(" ", keys %$channels)) if scalar(keys %$channels);

    return $channels;
}

sub db_connect {
    my $dbf = $ENV{"HOME"} . "/.xchat2/aka2.sqlite3";
    my $db_options = { AutoCommit => 1, RaiseError => 1 }; 

    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbf", "", "", $db_options) or die;
    $dbh->do(q/PRAGMA auto_vacuum = NONE/);
    $dbh->do(q/PRAGMA foreign_keys = ON/);
    $dbh->do(q/PRAGMA synchronous = OFF/);

    return $dbh;
}

sub db_init {
    my ($dbh) = @_;

    $dbh->do(q/CREATE TABLE IF NOT EXISTS channels (channel STRING PRIMARY KEY)/);
    $dbh->do(q/CREATE TABLE IF NOT EXISTS hosts (host_id INTEGER PRIMARY KEY, host STRING UNIQUE NOT NULL)/);
    $dbh->do(q/CREATE TABLE IF NOT EXISTS nicks (nick_id INTEGER PRIMARY KEY, nick STRING UNIQUE NOT NULL, last_seen INTEGER NOT NULL DEFAULT (strftime('%s', 'now')))/);
    $dbh->do(q/CREATE TABLE IF NOT EXISTS hosts_nicks (host_id INTEGER, nick_id INTEGER, PRIMARY KEY (host_id, nick_id), FOREIGN KEY (host_id) REFERENCES hosts(host_id), FOREIGN KEY (nick_id) REFERENCES nicks(nick_id))/);

    # $dbh->do(q/CREATE INDEX IF NOT EXISTS host_idx ON hosts (host)/);
    # $dbh->do(q/CREATE INDEX IF NOT EXISTS nick_idx ON nicks (nick)/);
    # $dbh->do(q/CREATE INDEX IF NOT EXISTS hosts_nicks_idx ON hosts_nicks (host_id, nick_id)/);
}

sub other_nicks {
    my ($dbh, $host, $nick) = @_;
    my $sth = $dbh->prepare_cached(q/SELECT DISTINCT nick FROM nicks NATURAL JOIN hosts_nicks NATURAL JOIN hosts WHERE host = ? AND nick <> ?/);
    return $dbh->selectall_arrayref($sth, undef, ($host, $nick));
}

sub nick_id {
    my ($dbh, $nick) = @_;
    my $sth = $dbh->prepare_cached(q/SELECT nick_id FROM nicks WHERE nick = ? LIMIT 1/);
    my @row = $dbh->selectrow_array($sth, undef, $nick);
    return (@row ? $row[0] : 0);
}

sub host_id {
    my ($dbh, $host) = @_;
    my $sth = $dbh->prepare_cached(q/SELECT host_id FROM hosts WHERE host = ? LIMIT 1/);
    my @row = $dbh->selectrow_array($sth, undef, $host);
    return (@row ? $row[0] : 0);
}

sub update {
    my ($dbh, $host, $nick) = @_;
    my $msg = "";

    # make sure host and nick are defined and non-null
    unless ($host && $nick) {
	Xchat::print("* $NAME: update failed (null nick or host [$nick][$host])");
	return;
    }

    # ignore guest and shiny nicks
    if ($nick =~ /^Guest\d+$/ || $nick =~ /^\d/) {
	Xchat::print("* $NAME: ignoring guest/shiny nick") if $DEBUG;
	return;
    }

    # search for host and add if it's not found
    my $host_id = host_id($dbh, $host);
    unless ($host_id) {
	my $sth = $dbh->prepare_cached(q/INSERT INTO hosts (host) VALUES (?)/);
	$sth->execute($host);
	$host_id = $dbh->last_insert_id("", "", "", "");
	$msg = "[$host]";
    }

    # search for nick and add if it's not found; otherwise, update last-seen time
    my $nick_id = nick_id($dbh, $nick);
    unless ($nick_id) {
	my $sth = $dbh->prepare_cached(q/INSERT INTO nicks (nick, last_seen) VALUES (?, strftime('%s', 'now'))/);
	$sth->execute($nick);
	$nick_id = $dbh->last_insert_id("", "", "", "");
	$msg = "[$nick]" . $msg;
    } else {
	my $sth = $dbh->prepare_cached(q/UPDATE nicks SET last_seen = ? WHERE nick = ?/);
	$sth->execute(time, $nick);
    }
    
    # create relation between host and nick if it doesn't already exist
    if ($host_id && $nick_id) {
	my $sth = $dbh->prepare_cached(q/INSERT OR IGNORE INTO hosts_nicks (host_id, nick_id) VALUES (?, ?)/);
	$sth->execute($host_id, $nick_id);
    }

    if ($msg ne "") {
	Xchat::print("* $NAME: --> $msg") if $DEBUG;
    }
}

# Event: $1 is now known as $2
sub on_change_nick {
    my ($dbh, $channels) = @{$_[1]};

    # check to see if we're enabled for this channel
    my $channel = lc Xchat::context_info->{channel};

    unless (exists $channels->{$channel} || $DEBUG) {
	Xchat::print("* $NAME: ignoring $channel") if $DEBUG;
	return Xchat::EAT_NONE;
    }

    # get the user's nick and host
    my $nick = Xchat::strip_code($_[0][1]);
    my $host = Xchat::user_info($nick)->{host};

    eval { 
	$dbh->begin_work;
	update($dbh, $host, $nick);
	$dbh->commit;
    };

    if ($@) {
	Xchat::print("* $NAME: update failed ($@)");
	eval { $dbh->rollback };
    }
    
    # don't eat the event, just return
    return Xchat::EAT_NONE;
}

# Event: $1 ($3) has joined $2
sub on_join {
    my ($dbh, $channels) = @{$_[1]};
    my $channel = lc $_[0][1];

    # check to see if we're enabled for this channel
    unless (exists $channels->{$channel} || $DEBUG) {
    	Xchat::print("* $NAME: ignoring $channel") if $DEBUG;
    	return Xchat::EAT_NONE;
    }

    # get the user's nick and host
    my $nick = Xchat::strip_code($_[0][0]);
    my $host = lc $_[0][2];

    my $nicks = other_nicks($dbh, $host, $nick);

    eval {
	$dbh->begin_work;
	update($dbh, $host, $nick);
	$dbh->commit;
    };

    if ($@) {
	Xchat::print("* $NAME: update failed ($@)");
	eval { $dbh->rollback };
    }

    # if other nicks were found, update the join message
    if (@$nicks) {
	my $aka = join(", ", map $_->[0], @$nicks);
	$_[0][0] = "$nick ($aka)";
    }

    Xchat::emit_print('Join', @{$_[0]});
    return Xchat::EAT_XCHAT;
}

sub on_command {
    my $argv = $_[0];
    my $argc = scalar(@$argv);
    my ($dbh, $channels) = @{$_[2]};
    
    if ($argc < 2) {
	usage();
	return Xchat::EAT_ALL;
    }

    my $command = lc $argv->[1];

    if ($command eq "debug") {
	$DEBUG = !$DEBUG;
	Xchat::print("* $NAME: debugging " . ($DEBUG ? "on" : "off"));
	return Xchat::EAT_ALL;
    } elsif ($command eq "vacuum") {
	# /aka vacuum
	vacuum($dbh);
	Xchat::print("* $NAME: vacuum complete");
	return Xchat::EAT_ALL;
    }

    if ($argc < 3) {
	usage();
	return Xchat::EAT_ALL;
    }

    if ($command eq "whois") {
	# /aka whois <nick>
	whois($dbh, $argv->[2]);
    } elsif ($command eq "import") {
	# /aka import <file>
	import($dbh, $argv->[2]);
    } elsif ($command eq "watch") {
	# /aka watch <channel>
	watch($dbh, $argv->[2]);
    } elsif ($command eq "unwatch") {
	# /aka unwatch <channel>
	unwatch($dbh, $argv->[2]);
    } else {
	# /aka help
	usage();
    }

    return Xchat::EAT_ALL;
}

sub usage {
    my $usage = <<END;
usage:
  /aka help                show this help
  /aka watch <channel>     watch a channel
  /aka unwatch <channel>   unwatch a channel
  /aka whois <nick>        show a user's other known nicks
  /aka import <file>       import data from an external file
  /aka vacuum              vacuum the database
END
    Xchat::print($usage);
}

sub vacuum {
    my ($dbh) = @_;
    $dbh->do(q/VACUUM/);
    $dbh->do(q/ANALYZE/);
}

sub import {
    my ($dbh, $file) = @_;

    unless (open(FILE, "<$file")) {
	Xchat::print("* $NAME: couldn't open $file");
	return;
    }

    eval {
	my $count = 0;

	$dbh->begin_work;
	while (<FILE>) {
	    chomp;
	    my ($host, $nick) = split(/ +/, $_);
	    update($dbh, $host, $nick);
	    ++$count;
	}
	$dbh->commit;
	
	vacuum($dbh);
	Xchat::print("* $NAME: imported $count records");
    };

    if ($@) {
	Xchat::print("* $NAME: import failed ($@)");
	eval { $dbh->rollback };
    }

    close(FILE);
}

sub whois {
    my ($dbh, $nick) = @_;

    my $user_info = Xchat::user_info($nick);
    unless ($user_info) {
	Xchat::print("* $nick isn't here :(");
	return;
    }

    my $host = $user_info->{host};
    my $nicks = other_nicks($dbh, $host, $nick);

    if (@$nicks) {
	my $aka = join(", ", map $_->[0], @$nicks);
	Xchat::print("* known aliases for $nick: $aka");
    } else {
	Xchat::print("* no known aliases for $nick");
    }
}

sub watch {
    my ($dbh, $channel) = @_;
    Xchat::print("* $NAME: this function is not yet implemented");
}

sub unwatch {
    my ($dbh, $channel) = @_;
    Xchat::print("* $NAME: this function is not yet implemented");
}

sub unload {
    $database_handle->disconnect;
    Xchat::print("* $NAME $VERSION unloaded :(");
}
