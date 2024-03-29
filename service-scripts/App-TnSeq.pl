#
# The TnSeq application.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::AppConfig;

use strict;
use Data::Dumper;
use File::Basename;
use File::Slurp;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run qw(run);
use Cwd;
use Clone;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError) ;

my $script = Bio::KBase::AppService::AppScript->new(\&process_tnseq, \&preflight);

my $rc = $script->run(\@ARGV);

exit $rc;

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $time = 86400;

    my $pf = {
	cpu => 1,
	memory => "32G",
	runtime => $time,
	storage => 0,
	is_control_task => 0,
    };
    return $pf;
}


sub process_tnseq
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc tnseq ", Dumper($app_def, $raw_params, $params);

    my $token = $app->token();
    my $output_folder = $app->result_folder();

    #
    # Create an output directory under the current dir. App service is meant to invoke
    # the app script in a working directory; we create a folder here to encapsulate
    # the job output.
    #
    # We also create a staging directory for the input files from the workspace.
    #

    my $cwd = getcwd();
    my $work_dir = "$cwd/work";
    my $stage_dir = "$cwd/stage";

    -d $work_dir or mkdir $work_dir or die "Cannot mkdir $work_dir: $!";
    -d $stage_dir or mkdir $stage_dir or die "Cannot mkdir $stage_dir: $!";

    my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;
    my $dat = { data_api => $data_api };
    my $sstring = encode_json($dat);

    #
    # Read parameters and discover input files that need to be staged.
    #
    # Make a clone so we can maintain a list of refs to the paths to be
    # rewritten.
    #
    my %in_files;

    my $params_to_app = Clone::clone($params);
    my @to_stage;

    for my $repname (keys %{$params_to_app->{read_files}})
    {
	my $replist = $params_to_app->{read_files}->{$repname};
	for my $repinst (@{$replist->{replicates}})
	{
	    #
	    # Hack to patch mismatch between UI and tool
	    #
	    if (exists($repinst->{read}))
	    {
		$repinst->{read1} = delete $repinst->{read};
	    }

	    for my $rd (qw(read1 read2))
	    {
		if (exists($repinst->{$rd}))
		{
		    my $nameref = \$repinst->{$rd};
		    $in_files{$$nameref} = $nameref;
		    push(@to_stage, $$nameref);
		}
	    }
	}
    }
    warn Dumper(\%in_files, \@to_stage);
    my $staged = $app->stage_in(\@to_stage, $stage_dir, 1);
    while (my($orig, $staged_file) = each %$staged)
    {
	my $path_ref = $in_files{$orig};
	$$path_ref = $staged_file;
    }

	my @my_files = ();
	while (my($orig, $staged_file) = each %$staged)
    {
    	open (READS, $staged_file) || die "Couldn't open $staged_file: $!";
    	my $la = <READS>;
    	my $hex_string = unpack "H*", substr($la, 0, 2);
    	if ($hex_string eq "1f8b") { # magic constant to check for gzip compression.
    		if ($staged_file =~ /\.gz\z/) {
    			my $staged_file_new = substr $staged_file, 0, length($staged_file)-3;
    			my $z = gunzip $staged_file => $staged_file_new or die "gunzip failed: $GunzipError\n";
    			unlink($staged_file) or warn "Unable to unlink $staged_file: $!";
    			$staged_file = $staged_file_new;
    		} else {
    			my $z = new IO::Uncompress::Gunzip $staged_file or die "gunzip failed: $GunzipError\n";
    		}
    	}
    	if ($staged_file =~ /\.gz\z/) {
    		my $staged_file_new = substr $staged_file, 0, length($staged_file)-3;
    		rename($staged_file, $staged_file_new) || die ( "Error in renaming" );
    		$staged_file = $staged_file_new;
    	}
		push(@my_files, $staged_file);
    }
    #
    # Write job description.
    #
    my $jdesc = "$cwd/jobdesc.json";
    open(JDESC, ">", $jdesc) or die "Cannot write $jdesc: $!";
    print JDESC JSON::XS->new->pretty(1)->encode($params_to_app);
    close(JDESC);

    my @cmd = ("p3_tnseq", "--jfile", $jdesc, "--sstring", $sstring, "-o", $work_dir);

    warn Dumper(\@cmd, $params_to_app);

    my $ok = run(\@cmd);

    # my $ok = run(\@cmd,
	# 	 ">", "$work_dir/tnseq.out.txt",
	# 	 "2>", "$work_dir/tnseq.err.txt");
    if (!$ok)
    {
	die "Command failed: @cmd\n";
    }


    my @output_suffixes = ([qr/\.bam$/, "bam"],
			   [qr/\.bam\.bai$/, "bam"],
			   [qr/\.counts$/, "txt"],
			   [qr/\.tn_stats$/, "txt"],
			   [qr/\.txt$/, "txt"],
			   [qr/\.wig$/, "wig"]);

    my $outfile;
    opendir(D, $work_dir) or die "Cannot opendir $work_dir: $!";
    my @files = sort { $a cmp $b } grep { -f "$work_dir/$_" } readdir(D);

    # Get the receipe to try to pull the overall output file.
    my $recipe = $params->{recipe};
    my $output;
    for my $file (@files)
    {
	if ($recipe && $file =~ /^$recipe.*transit.txt/)
	{
	    $output = read_file("$work_dir/$file");
	}
	for my $suf (@output_suffixes)
	{
	    if ($file =~ $suf->[0])
	    {
		my $path = "$output_folder/$file";
		my $type = $suf->[1];

		$app->workspace->save_file_to_file("$work_dir/$file", {}, "$output_folder/$file", $type, 1,
					       (-s "$work_dir/$file" > 10_000 ? 1 : 0), # use shock for larger files
					       $token);
	    }
	}
    }

    #
    # Clean up staged input files.
    #
    # while (my($orig, $staged_file) = each %$staged)
    foreach my $staged_file (@my_files)
    {
	unlink($staged_file) or warn "Unable to unlink $staged_file: $!";
    }

    return $output;
}
