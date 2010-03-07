#!/usr/bin/perl -w

# Copyright (c) 2010 Selena Deckelmann
# See LICENSE for license information
# Implemented using this great guide: http://josephsmarr.com/2010/03/01/implementing-pubsubhubbub-subscriber-support-a-step-by-step-guide/
# And some help from: http://pubsubhubbub.googlecode.com/svn/trunk/pubsubhubbub-core-0.3.html

use Carp;
use DBI;
use URI;
use LWP::UserAgent;
use HTML::TokeParser;
use Getopt::Long;
use Pod::Usage;
use strict;

use vars qw/%opt/;

GetOptions(\%opt,
        "help",
        "verbose",
        "init",
        "callback=s",
        "target=s",
        "timeout=i",
        "token=i",
        "unsubscribe",
) or pod2usage(2);

pod2usage(1) if $opt{help};

my $VERBOSE   = $opt{verbose};
my $init      = $opt{init};
my $callback  = $opt{callback} || "http://localhost:8080/publish.cgi";
my $target    = $opt{target}   || "http://pubsubhubbub-example-app.appspot.com/";
my $timeout   = $opt{timeout}  || 10;
my $token     = $opt{token}    || 'blargyblargblarg';

my $dbh = store();
create_feeds_table($dbh) if ($init);
my $ua = LWP::UserAgent->new();
$ua->timeout($timeout);

## Discovery! Can we find a push_feed?
my ($push_feed, $topic) = find_push_feed($ua, $target);
exit unless ($push_feed);

store_push_feed($dbh, $push_feed, $topic, $token);

## If we said we wanted to unsubscribe, do it.
## Otherwise, subscribe!
($opt{unsubscribe}) ? go("unsubscribe") 
                    : go("subscribe");


sub find_push_feed {
    my ($ua, $url) = @_;
    ## Verify that url is valid
    my $result;
    my $self;
    
    print "Fetching $url\n";
    carp "Error: $url is not valid URI\n" and return 
        unless (verify($url));

    $result = $ua->get($url);

    my $content = $result->decoded_content;
    my $stream = HTML::TokeParser->new(\$content);

    while (my $token = $stream->get_token) {
        ## Find links
        next unless ($token->[0] eq 'S' and ($token->[1] eq 'link' or $token->[1] eq 'atom:link'));

        my ($attr) = @$token[2];
        next unless (exists $attr->{rel});
        my @rels = split(' ', $attr->{rel});

        for my $rel (@rels) {
            if ($rel eq 'hub') {
                print join (' ', $token->[1], $attr->{'href'}, "\n");
                return ($attr->{'href'}, $self);
            }
            elsif ($rel eq 'self') {
                $self = $attr->{href};
            }
            ## XXX: Do I really need to check type?
            elsif (($attr->{type} eq 'application/atom+xml'
                 or $attr->{type} eq 'application/rss+xml')
                and $rel eq 'alternate') {    

                ## Check if the reference is relative or not
                ## XXX: Probably should specify a maxdepth
                my $feed = $attr->{'href'};
                ($feed =~ m/^http/) ? return find_push_feed($ua, $feed)
                                    : return find_push_feed($ua, $url . $feed);
            }
        }
    }

    # Didn't find any useful links :(
    return;
}

sub verify {
    my ($url) = @_;
    my $uri;

    eval {
        $uri = URI->new($url);
    };
    if ($@) {
        $VERBOSE and carp "Error: $@\n";
        return 0;
    }

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

sub create_feeds_table {

    my ($dbh) = @_;

    eval {
        $dbh->do('CREATE TABLE feeds (url TEXT PRIMARY KEY, pushfeed TEXT NOT NULL, token TEXT, subscribed TEXT, last_seen timestamp NOT NULL)');
        $dbh->commit;
    };

    eval {
        $dbh->do('CREATE TABLE updates (id INTEGER PRIMARY KEY AUTOINCREMENT, feed TEXT NOT NULL, myupdate TEXT NOT NULL, FOREIGN KEY(feed) REFERENCES feeds(url))');
        $dbh->commit;
    };
}

sub store_push_feed {

    my ($dbh, $pushfeed, $topic, $token) = @_;

    my $result;
    my $SQL = " INSERT INTO feeds (url, pushfeed, token, last_seen) VALUES(?, ?, ?, ?) ";
    my $sth = $dbh->prepare($SQL);
    my $now = localtime(time);

    eval {
        $result = $sth->execute($topic, $pushfeed, $token, $now);
    };
    
    if ($@) {
        #$dbh->rollback;
        # insert failed
        $SQL = " UPDATE feeds SET url = ?, pushfeed = ?, token = ?, last_seen = ? WHERE url = ? ";
        my $sth2 = $dbh->prepare($SQL);
        eval {
            $sth2->execute($topic, $pushfeed, $token, $now, $topic);
        };
    }
    $dbh->commit;
}

sub update_feed_status {
    my ($url, $mode) = @_;
    my $result;
    my $SQL = " UPDATE feeds SET subscribed = '$mode sent' WHERE url = ? ";
    my $sth = $dbh->prepare($SQL);
    eval {
       $sth->execute($url);
   };
   $dbh->commit;
}


sub go {

    my ($mode) = @_;

    ## XXX: can $push_feed ever be relative?
    my %form = (
        'hub.callback' => $callback . '?feed=' . $topic,
        'hub.mode' => $mode,
        'hub.topic' => $topic,
        'hub.verify' => 'async',
        'hub.verify_token' => $token,
    );

    # Sent a POST and get a response
    my $response = $ua->post($push_feed, \%form);

    if ($response->is_success) {
         $VERBOSE and print join(" ", $response->code, $response->decoded_content, "\n");  # or whatever
         ## Unsubscribe may have succeeded, so...
         update_feed_status($topic, $mode);
    } else {
         carp $response->status_line;
         carp $response->decoded_content;
    }
}

1;

__END__

=head1 NAME

pubhubsubbub.pl -- Example subscription script for pubhubsubbub providers

=head1 SYNOPSIS

pubhubsubbub.pl [options]

    --help              print this help out
    --verbose           print some debugging information
    --init              initialize the subscription tracking database (sqlite)
    --callback=[URL]    specify the callback URL for the Hub to confirm with a GET request
    --target=[URL]      specify the URL to scan and subscribe to
    --timeout=[SECONDS] specify the time before timing out on a request
    --unsubscribe       Unsubscribe from the target feed/site

=cut
