#!/usr/bin/env perl -T

use strict;
use warnings;

use Test::More;

SKIP: {
    skip 'Skipping release tests', 1 unless $ENV{RELEASE_TESTING};

    require Test::Pod::Coverage;
    Test::Pod::Coverage->import();
    all_pod_coverage_ok({ trustme => [qr/BUILDARGS/] });
}

done_testing();
