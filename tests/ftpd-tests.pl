#!/usr/bin/env perl
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.
use 5.014;  # strict, /r
use warnings;
use Data::Dumper ();
use File::Temp 'tempdir';
use Getopt::Std 'getopts';
use JSON::PP 'decode_json';
use Fcntl qw/ :flock :seek /;
use File::Spec::Functions qw/ no_upwards /;

sub pp { Data::Dumper->new(\@_)->Terse(1)->Purity(1)->Useqq(1)->Quotekeys(0)->Sortkeys(1)->Indent(1)->Dump =~ s/[\r\n]+$//r }

my $USAGE = "Usage: $0 [-h FTP_HOST] [-u FTP_USER] [-p FTP_PASS] -f SRV_FTP_DIR -l LOG_DIR [-L | -r LOGROTATE_CMD] [-v VALKEY_HOST]\n";
getopts('h:u:p:f:l:Lr:v:', \my %opts) or die $USAGE;
$opts{h} ||= 'localhost:21';
$opts{u} ||= 'test_user';
$opts{p} ||= 'PASS_WORD';
die $USAGE."-f and -l are required\n" unless -d $opts{f} && -d $opts{l};
# -L means "logs and upload.log are disabled"
die $USAGE."Can't use -L with -r\n" if $opts{L} && $opts{r};
die $USAGE if @ARGV;

# generate the test files
my $td = tempdir(CLEANUP=>1); my $tfh;
open $tfh, '>', "$td/Hello.txt" and print $tfh "World\n" and close $tfh or die $!;
open $tfh, '>', "$td/foo.txt"   and print $tfh "bar\n"   and close $tfh or die $!;

# if the user requested Valkey tests, let's make sure the server is up and running first
if ($opts{v}) {
    my $uploads;
    my $retry_count = 5;
    while (1) {
        last if `valkey-cli -h "$opts{v}" --raw PING` =~ /^PONG$/;
        die "Valkey didn't pong" unless $retry_count--;
        warn "Valkey not up yet, retying...\n";
        sleep 1;
    }
    say "Valkey server is up";
}

# upload the test files (using lftp because Net::FTP didn't work for me)
# lftp has a built-in auto-retry feature, so just use that in case the Docker container isn't quite ready yet
system('lftp','-u',"$opts{u},$opts{p}",$opts{h},'-e',
    "set ssl:verify-certificate no; set net:reconnect-interval-base 1; set net:reconnect-interval-multiplier 2; set net:max-retries 5;"
    ."put -e $td/Hello.txt; put -e $td/foo.txt; exit"
)==0 or die "lftp failed: \$!=$!, \$?=$?";

# check upload.log
my $upload_log_re = qr{\A
    [-0-9T:,+]+ \t \Q$opts{u}\E \t 6 \t \Q/srv/ftp/$opts{u}/Hello.txt\E \n
    [-0-9T:,+]+ \t \Q$opts{u}\E \t 4 \t \Q/srv/ftp/$opts{u}/foo.txt\E \n?
\z}x;
if ($opts{L}) {
    sleep 1;  # make sure it hasn't changed even after a short wait (see loop below)
    -s "$opts{f}/upload.log" and die "upload.log non-empty when it shouldn't be" or say "ok: upload.log doesn't exist or is empty";
}
else {
    # uploadscript.sh may need a few ms to finish executing
    my $retry_count = 5;
    while(1) {
        open my $fh, '<', "$opts{f}/upload.log" or die "open: $!";
        # the writer script flocks the upload.log too
        flock $fh, LOCK_SH or die "flock: $!";
        seek $fh, 0, SEEK_SET or die "seek: $!";
        my $upload_log = do { local $/, <$fh> };
        close $fh;
        last if $upload_log =~ $upload_log_re;
        die  "upload.log mismatch: ".pp($upload_log) unless $retry_count-->0;
        warn "upload.log mismatch - retrying...\n";
        sleep 1;
    }
    say "upload.log ok";
}

# check the uploaded files
my $hello_txt = do { open my $fh, '<', "$opts{f}/$opts{u}/Hello.txt" or die $!; local $/; <$fh> };
$hello_txt eq "World\n" and say "Hello.txt ok" or die "Hello.txt mismatch: ".pp($hello_txt);
my $foo_txt = do { open my $fh, '<', "$opts{f}/$opts{u}/foo.txt" or die $!; local $/; <$fh> };
$foo_txt eq "bar\n" and say "foo.txt ok" or die "foo.txt mismatch: ".pp($foo_txt);

# check the logs
my $ftpd_log_re = qr{
    \QNew connection from\E .+
    \Qtest_user is now logged in\E .+
    \Quploadscript.sh: Upload at \E[-0-9T:,+]+\Q file /srv/ftp/test_user/Hello.txt size 6 by test_user\E \n .+
    \Quploadscript.sh: Upload at \E[-0-9T:,+]+\Q file /srv/ftp/test_user/foo.txt size 4 by test_user\E \n .*
}sx;
if ($opts{L}) {
    my @files = list_files($opts{l});
    @files and die "Log files exist when they shouldn't: ".pp(\@files) or say "ok: No log files exist";
}
else {
    my $ftpd_log = do { open my $fh, '<', "$opts{l}/ftpd.log" or die $!; local $/; <$fh> };
    $ftpd_log =~ $ftpd_log_re and say "ftpd.log ok" or die "ftpd.log mismatch: ".pp($ftpd_log);
}

# if user asked to force log rotation, test that
if ($opts{r}) {
    system($opts{r})==0 or die "LOGROTATE_CMD failed: \$!=$!, \$?=$?";

    # check the file list
    my @files = list_files($opts{l});
    my @non_files = grep {!-f "$opts{l}/$_"} @files;
    die "Non-files in $opts{l}: ".pp(\@non_files) if @non_files;
    my @non_match = grep { !/\Aftpd\.log(?:\.[-0-9]+\.gz)?\z/ } @files;
    die "Strangely named files in $opts{l}: ".pp(\@non_match) if @non_match;
    die "Don't see one ftpd.log in $opts{l}: ".pp(\@files) unless grep({$_ eq 'ftpd.log'} @files)==1;
    die "Don't see any .gz files in $opts{l}: ".pp(\@files) unless grep {/\.gz$/} @files;
    say "ok: filenames in log dir look ok";

    # assume the latest log is the one we just rotated (should only fail in really unexpected cases)
    my $log_f = (sort grep {$_ ne 'ftpd.log'} @files)[-1];
    my $rot_log = `zcat "$opts{l}/$log_f"`;
    $rot_log =~ $ftpd_log_re and say "rotated ftpd log ok" or die "rotated log mismatch".pp($rot_log);

    -s "$opts{l}/ftpd.log" and say "ok: new log isn't empty"
        or die "new log is empty (maybe LOGROTATE_CMD didn't force a new log entry?)";
}

# valkey tests
if ($opts{v}) {
    my $uploads;
    my $retry_count = 5;
    while (1) {
        $uploads = decode_json `valkey-cli -h "$opts{v}" --quoted-json XRANGE pure-ftpd.uploads - +`;
        last if @$uploads>=2;
        die  "didn't get two valkey uploads: ".pp($uploads) unless $retry_count-->0;
        warn "don't have two valkey uploads yet, waiting...\n";
        sleep 1;
    }
    for my $x (@$uploads) {
        my $keys = join(',',@{$x->[1]}[0,2,4,6]);
        die "bad keys $keys" unless $keys eq 'time,user,size,name';
    }
    my $vk_up_log = join("\n", map { join "\t", @{$_->[1]}[1,3,5,7] } @$uploads);
    $vk_up_log =~ $upload_log_re and say "valkey uploads ok" or die "valkey uploads mismatch: ".pp($vk_up_log);

    my $logs = `valkey-cli -h "$opts{v}" --raw XRANGE pure-ftpd.log - +`;
    $logs =~ $ftpd_log_re and say "valkey logs ok" or die "valkey logs mismatch: ".pp($logs);
}

sub list_files {
    my $d = shift;
    opendir my $dh, $d or die $!;
    return no_upwards(readdir $dh);
}
