#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

my @METRICS = qw(cold_boot warm_boot ssh_ready shutdown build_workload);
my @STATS = qw(median_seconds p95_seconds failure_rate);
my @METADATA = qw(revision cli_sha256 guest_artifact_sha256 nix_version macos_version hardware_model host_arch iterations cores memory_mb disk_size timeout_seconds workload_label);
my @FIXED_METADATA = qw(guest_artifact_sha256 nix_version macos_version hardware_model host_arch iterations cores memory_mb disk_size timeout_seconds workload_label);
my %MIN_ATTEMPTS = (build_workload => 10);
$MIN_ATTEMPTS{$_} = 30 for qw(cold_boot warm_boot ssh_ready shutdown);

sub usage {
    die "usage: benchmark-report.pl collect SAMPLES.tsv METADATA.json OUTPUT.json\n"
      . "       benchmark-report.pl compare BASELINE.json CANDIDATE.json [MAX_REGRESSION_PERCENT]\n";
}

sub percentile {
    my ($values, $fraction) = @_;
    return undef unless @$values;
    my @sorted = sort { $a <=> $b } @$values;
    my $index = int($fraction * @sorted + 0.999999) - 1;
    $index = 0 if $index < 0;
    return 0 + sprintf('%.6f', $sorted[$index]);
}

sub median {
    my ($values) = @_;
    return undef unless @$values;
    my @sorted = sort { $a <=> $b } @$values;
    my $middle = int(@sorted / 2);
    my $value = @sorted % 2
        ? $sorted[$middle]
        : ($sorted[$middle - 1] + $sorted[$middle]) / 2;
    return 0 + sprintf('%.6f', $value);
}

sub read_json {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    local $/;
    return decode_json(<$fh>);
}

sub is_number {
    return defined($_[0]) && !ref($_[0]) && $_[0] =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
}

my $mode = shift @ARGV // usage();
if ($mode eq 'collect') {
    @ARGV == 3 or usage();
    my ($samples_path, $metadata_path, $output_path) = @ARGV;
    my $metadata = read_json($metadata_path);
    open my $samples_fh, '<', $samples_path or die "cannot read $samples_path: $!\n";
    my (%values, %attempts, %failures, @samples);
    while (my $line = <$samples_fh>) {
        chomp $line;
        next if $line eq '';
        my ($iteration, $metric, $seconds, $success, $status) = split /\t/, $line, 5;
        $status //= $success ? 'success' : 'failure';
        defined($success) && $iteration =~ /^\d+$/ && $metric =~ /^(?:cold_boot|warm_boot|ssh_ready|shutdown|build_workload)$/
          && $seconds =~ /^\d+(?:\.\d+)?$/ && $success =~ /^(?:0|1)$/
          && $status =~ /^(?:success|failure|prerequisite_failure)$/
          or die "invalid sample row\n";
        $attempts{$metric}++;
        $failures{$metric}++ unless $success;
        push @{$values{$metric}}, 0 + $seconds if $success;
        push @samples, {
            iteration => 0 + $iteration, metric => $metric,
            seconds => 0 + $seconds, success => $success ? JSON::PP::true : JSON::PP::false,
            status => $status,
        };
    }
    my %summary;
    for my $metric (@METRICS) {
        my $attempt_count = $attempts{$metric} // 0;
        my $failure_count = $failures{$metric} // 0;
        $summary{$metric} = {
            attempts => $attempt_count,
            failures => $failure_count,
            failure_rate => $attempt_count ? 0 + sprintf('%.6f', $failure_count / $attempt_count) : undef,
            median_seconds => median($values{$metric} // []),
            p95_seconds => percentile($values{$metric} // [], 0.95),
        };
    }
    my $report = {
        schema_version => 2, metadata => $metadata, summary => \%summary, samples => \@samples,
    };
    open my $output_fh, '>', $output_path or die "cannot write $output_path: $!\n";
    print {$output_fh} JSON::PP->new->ascii->canonical->pretty->encode($report);
    close $output_fh or die "cannot close $output_path: $!\n";
    exit 0;
}

if ($mode eq 'compare') {
    @ARGV >= 2 && @ARGV <= 3 or usage();
    my ($baseline_path, $candidate_path, $threshold) = @ARGV;
    defined($threshold) && $threshold !~ /^\d+(?:\.\d+)?$/ and die "threshold must be non-negative\n";
    my $baseline = read_json($baseline_path);
    my $candidate = read_json($candidate_path);
    for my $named ([baseline => $baseline], [candidate => $candidate]) {
        my ($name, $report) = @$named;
        ref($report) eq 'HASH' && ($report->{schema_version} // 0) == 2
          or die "$name report has unsupported schema_version\n";
        ref($report->{metadata}) eq 'HASH' && ref($report->{summary}) eq 'HASH'
          or die "$name report is missing metadata or summary\n";
        for my $key (@METADATA) {
            defined($report->{metadata}{$key}) && $report->{metadata}{$key} ne ''
              or die "$name report is missing metadata.$key\n";
        }
        for my $metric (@METRICS) {
            ref($report->{summary}{$metric}) eq 'HASH'
              or die "$name report is missing summary.$metric\n";
            my $attempts = $report->{summary}{$metric}{attempts};
            defined($attempts) && !ref($attempts) && $attempts =~ /^\d+$/
              or die "$name report has invalid summary.$metric.attempts\n";
            $attempts >= $MIN_ATTEMPTS{$metric}
              or die "$name report has too few $metric attempts\n";
            for my $stat (@STATS) {
                is_number($report->{summary}{$metric}{$stat})
                  or die "$name report has invalid summary.$metric.$stat\n";
            }
            my $failure_rate = $report->{summary}{$metric}{failure_rate};
            $failure_rate >= 0 && $failure_rate <= 1
              or die "$name report has invalid summary.$metric.failure_rate\n";
        }
    }
    for my $key (@FIXED_METADATA) {
        $baseline->{metadata}{$key} eq $candidate->{metadata}{$key}
          or die "metadata mismatch for $key\n";
    }
    my (%metrics, $regressed);
    for my $metric (@METRICS) {
        for my $stat (@STATS) {
            my $before = $baseline->{summary}{$metric}{$stat};
            my $after = $candidate->{summary}{$metric}{$stat};
            my $percent = $before == 0 ? undef : 100 * ($after - $before) / $before;
            my $absolute = $after - $before;
            my $status = $after > $before ? 'regressed' : $after < $before ? 'improved' : 'unchanged';
            $metrics{$metric}{$stat} = {
                baseline => $before, candidate => $after,
                change_percent => defined($percent) ? 0 + sprintf('%.6f', $percent) : undef,
                absolute_change => 0 + sprintf('%.6f', $absolute),
                comparison_status => $status,
            };
            if (defined($threshold)) {
                $regressed = 1 if $before == 0 ? $after > 0 : $percent > $threshold;
            }
        }
    }
    my $result = {
        schema_version => 2, mode => 'compare', metrics => \%metrics,
        threshold_percent => defined($threshold) ? 0 + $threshold : undef,
        verdict => !defined($threshold) ? 'informational' : ($regressed ? 'regression' : 'within_threshold'),
    };
    print JSON::PP->new->ascii->canonical->pretty->encode($result);
    exit($regressed ? 1 : 0);
}

usage();
