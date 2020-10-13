#!/usr/bin/env perl -T

use strict;
use warnings;

use HTTP::Response;
use PagerDuty::Agent;
use Test::LWP::UserAgent;
use Test::More;
use File::Temp qw/ tempdir /;

my $ua = Test::LWP::UserAgent->new();
$ua->map_response(
    qr//,
    HTTP::Response->new(
        '202',
        undef,
        undef,
        '{ "dedup_key": "my dedup_key" }',
    ),
);

subtest 'keep_alive' => sub {
    ok(PagerDuty::Agent->new(routing_key => '123')->ua_obj()->conn_cache());
};

subtest 'timeout' => sub {
    my $agent = PagerDuty::Agent->new(routing_key => '123', ua_obj => $ua, timeout => 10);
    $agent->trigger_event('HELO');

    is($ua->last_useragent()->timeout(), 10);
};

subtest 'headers' => sub {
    my $agent = PagerDuty::Agent->new(routing_key => '123', ua_obj => $ua);

    my $dedup_key = $agent->trigger_event('HELO');
    my $request = $ua->last_http_request_sent();

    is($dedup_key, 'my dedup_key');
    is($request->method(), 'POST');

    is($request->header('Content-Type'), 'application/json');
    is($request->header('Authorization'), 'Token token=123');
};

subtest 'trigger' => sub {
    my $agent = PagerDuty::Agent->new(routing_key => '123', ua_obj => $ua);

    my $dedup_key = $agent->trigger_event('HELO');
    my $request = $ua->last_http_request_sent();

    is($dedup_key, 'my dedup_key');

    my $event = $agent->json_serializer()->decode($request->content());
    is($event->{event_action}, 'trigger');
    is($event->{payload}->{summary}, 'HELO');


    $agent->trigger_event(summary => 'HELO');
    $request = $ua->last_http_request_sent();
    is($event->{payload}->{summary}, 'HELO');
};

subtest 'acknowledge' => sub {
    my $agent = PagerDuty::Agent->new(routing_key => '123', ua_obj => $ua);

    my $dedup_key = $agent->acknowledge_event('my dedup_key');
    my $request = $ua->last_http_request_sent();

    is($dedup_key, 'my dedup_key');

    my $event = $agent->json_serializer()->decode($request->content());
    is($event->{event_action}, 'acknowledge');
    is($event->{dedup_key}, 'my dedup_key');


    $agent->acknowledge_event(summary => 'HELO', dedup_key => 'my dedup_key');
    $request = $ua->last_http_request_sent();
    is($event->{dedup_key}, 'my dedup_key');
};

subtest 'resolve' => sub {
    my $agent = PagerDuty::Agent->new(routing_key => '123', ua_obj => $ua);

    my $dedup_key = $agent->resolve_event('my dedup_key');
    my $request = $ua->last_http_request_sent();

    is($dedup_key, 'my dedup_key');

    my $event = $agent->json_serializer()->decode($request->content());
    is($event->{event_action}, 'resolve');
    is($event->{dedup_key}, 'my dedup_key');


    $agent->resolve_event(summary => 'HELO', dedup_key => 'my dedup_key');
    $request = $ua->last_http_request_sent();
    is($event->{dedup_key}, 'my dedup_key');
};

my $ua_defer = Test::LWP::UserAgent->new();
$ua_defer->map_response(
    qr//,
    HTTP::Response->new(
        '429',
        undef,
        undef,
        'Slow down buddy'
    ),
);

my $spool_dir = tempdir( CLEANUP => 1 );

subtest 'trigger_defer' => sub {
    my $agent = PagerDuty::Agent->new(
        routing_key => '123',
        ua_obj      => $ua_defer,
        spool       => $spool_dir,
    );

    my $result = $agent->trigger_event('HELO');

    is($result, 'defer');
};

subtest 'trigger_defer_again' => sub {
    my $agent = PagerDuty::Agent->new(
        ua_obj      => $ua_defer,
        spool       => $spool_dir,
    );

    my $result = $agent->flush();

    is($result->{count}{deferred}, 1);
};

subtest 'trigger_defer_enqueue' => sub {
    my $agent = PagerDuty::Agent->new(
        ua_obj      => $ua,
        spool       => $spool_dir,
    );

    my $result = $agent->flush();

    is($result->{count}{submitted}, 1);
    is($result->{dedup_keys}[0][0], 'my dedup_key');
    is($result->{dedup_keys}[0][1], 'submitted');
};

my $ua_server_error = Test::LWP::UserAgent->new();
$ua_server_error->map_response(
    qr//,
    HTTP::Response->new(
        '500',
        undef,
        undef,
        'A server error'
    ),
);

subtest 'trigger_server_error' => sub {
    my $agent = PagerDuty::Agent->new(
        routing_key => '123',
        ua_obj      => $ua_server_error,
        spool       => $spool_dir,
    );

    my $result = $agent->trigger_event('HELO');

    is($result, 'defer');
};

subtest 'trigger_server_error_again' => sub {
    my $agent = PagerDuty::Agent->new(
        ua_obj      => $ua_server_error,
        spool       => $spool_dir,
    );

    my $result = $agent->flush();

    is($result->{count}{deferred}, 1);
};

subtest 'trigger_server_error_enqueue' => sub {
    my $agent = PagerDuty::Agent->new(
        ua_obj      => $ua,
        spool       => $spool_dir,
    );

    my $result = $agent->flush();

    is($result->{count}{submitted}, 1);
    is($result->{dedup_keys}[0][0], 'my dedup_key');
    is($result->{dedup_keys}[0][1], 'submitted');
};

my $ua_client_error = Test::LWP::UserAgent->new();
$ua_client_error->map_response(
    qr//,
    HTTP::Response->new(
        '400',
        undef,
        undef,
        'Bad request'
    ),
);

subtest 'trigger_client_error' => sub {
    my $agent = PagerDuty::Agent->new(
        routing_key => '123',
        ua_obj      => $ua_client_error,
        spool       => $spool_dir,
    );

    my $result = $agent->trigger_event('HELO');

    is($result, undef);
};

# Should be nothing left, as the spooled file should be removed on a client
# error.
subtest 'trigger_client_error_yet_again' => sub {
    my $agent = PagerDuty::Agent->new(
        ua_obj      => $ua,
        spool       => $spool_dir,
    );

    my $result = $agent->flush();

    is($result->{count}{errors}, 0);
    is($result->{count}{submitted}, 0);
    is($result->{count}{deferred}, 0);
};

done_testing();
