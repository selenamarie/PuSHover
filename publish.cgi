#!/usr/bin/perl

# Copyright (c) 2010 Selena Deckelmann
# See LICENSE for license information
# Implemented using this great guide: http://josephsmarr.com/2010/03/01/implementing-pubsubhubbub-subscriber-support-a-step-by-step-guide/
# And some help from: http://pubsubhubbub.googlecode.com/svn/trunk/pubsubhubbub-core-0.3.html

use CGI::Minimal;
use DBI;
use Carp;
use strict;

my $dbh = store();

CGI::Minimal::allow_hybrid_post_get(1);
my $cgi = CGI::Minimal->new;
my %verify = ();
my $feed;

my $mode = $cgi->param('hub.mode');
my $feed = $cgi->param('feed');

if ($mode eq 'subscribe' or $mode eq 'unsubscribe') {
    for (qw/topic challenge verify_token/) {
       $verify{$_} = $cgi->param('hub.' . $_);
       fail() unless (exists $verify{$_});
    }

    if (topic_exists($dbh, $verify{topic}, $verify{verify_token})) {
        win($verify{challenge});
    } else {
        fail();
    }
} 
elsif ($mode eq 'publish') {
    ## not implemented
    fail();
} 
elsif ($feed) {
    ## Fat ping!
    my $payload = $cgi->raw();
    store_update($feed, $payload);
    win();
}
else {
    fail();
}

sub win {
    my $challenge = shift;
    print "Content-type: text/html\n\n";
    print $challenge;
}

sub fail {
    print "Content-type: text/html\n";
    print "Status: 400 Bad Request\n\n";
    print "Error: malformed request\n";
}

$dbh->rollback;

sub topic_exists {
    my ($dbh, $topic, $token) = @_;
    return 0 unless (defined $topic);
    my $result;

    my $SQL = "SELECT url from feeds where url = ? and token = ? ";
    my $sth = $dbh->prepare($SQL);

    eval {
        $result = $sth->execute($topic, $token);
    };

    if ($@) {
        carp "Could not find $topic and/or $token: $@\n";
        return 0;
    }
    ## Result should be 1
    return $result;
}

sub store_update {

    my ($feed, $update) = @_;
    my $result;

    my $SQL = " INSERT INTO updates (feed, myupdate) values(?, ?)";
    my $sth = $dbh->prepare($SQL);

    eval {
        $result = $sth->execute($feed, $update);
    };

    if ($@) {
        carp "Could not find $feed (or something): $@\n";
        return 0;
    }

    $dbh->commit;
    return 1;
}

sub store {
    my $dbname = "demo.db";
    my $dbargs = {AutoCommit => 0,
                  RaiseError => 1,
                  PrintError => 0};
    my $dbh = DBI->connect("dbi:SQLite:dbname=db/$dbname","","",$dbargs);
    return $dbh;
}

1;
