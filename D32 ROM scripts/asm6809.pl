#!/usr/bin/perl -wT

use strict;

# 6800/6801/6803/6809/6309 assembler
# by Ciaran Anscomb, 2010-2013

# A 3+ pass assembler.  Kind of.
# Pass 1: Read in text, store macros while reading.
# Pass 2: Divide text into sections.
# Pass 3: Assemble each section in turn, expanding any macro calls.
#         Repeat until addresses are stable.

# Disclaimer:
# Possibly not fit for any purpose.  You're free to use, copy, modify and
# redistribute so long as I don't get the blame for anything.

use Text::Tabs;
$tabstop = 8;

my $VERSION = "1.10";

my $output_format = 'binary';
my $output_filename = undef;
my $symbols_filename = undef;
my $listing_filename = undef;
my $isa = '6809';
my $syntax_extended = 0;
my $verbose = 0;
my $quiet = 0;
my $exec_label = undef;

sub helptext {
	print <<EOF;
Usage: $0 [OPTION]... SOURCE-FILE...
Assembles 6800/6801/6803/6809/6309 source code.

  -I PATH           add to include path

  -B, --bin         output to binary file (default)
  -H, --hex         output to (currently malformed) Intel hex record file
  -D, --dragondos   output to DragonDOS binary file
  -C, --coco        output to CoCo segmented binary file
  -e, --exec=ADDR   EXEC address (for output formats that support one)

  -0, --6800        use 6800 ISA
  -1, --6801,
      --6803        use 6801 ISA (6803 is identical)
  -8,
  -9, --6809        use 6809 ISA (default)
  -3, --6309        use 6309 ISA (6809 with extensions)
  -x, --extended    permit extended syntax

  -o, --output=FILE    set output filename
  -l, --listing=FILE   create listing file
  -s, --symbols=FILE   create symbol table

  -v, --verbose   show what assembler is doing at each stage
  -q, --quiet     suppress warnings
      --help      show this help and exit

If more than one SOURCE-FILE is specified, they are assembled as though
they were all in one file.
EOF
}

my @include_path = ( "." );
my @files = ();

while (@ARGV) {
	my $opt = $ARGV[0];
	if ($opt eq "--") {
		shift @ARGV; last;
	} elsif ($opt =~ /^-I(.+)$/) {
		push @include_path, $1;
	} elsif ($opt eq "-I") {
		shift @ARGV;
		if ($ARGV[0] =~ /^(.*)$/) {
			push @include_path, $1;  # de-taint
		}
	} elsif ($opt =~ /^--output=(.*)$/) {
		$output_filename = $1;
	} elsif ($opt eq "-o" || $opt eq "--output") {
		shift @ARGV;
		if ($ARGV[0] =~ /^(.*)$/) {
			$output_filename = $1;  # de-taint
		}
	} elsif ($opt =~ /^--symbols=(.*)$/) {
		$symbols_filename = $1;
	} elsif ($opt eq "-s" || $opt eq "--symbols") {
		shift @ARGV;
		if ($ARGV[0] =~ /^(.*)$/) {
			$symbols_filename = $1;  # de-taint
		}
	} elsif ($opt =~ /^--listing=(.*)$/) {
		$listing_filename = $1;
	} elsif ($opt eq "-l" || $opt eq "--listing") {
		shift @ARGV;
		if ($ARGV[0] =~ /^(.*)$/) {
			$listing_filename = $1;  # de-taint
		}
	} elsif ($opt eq "-B" || $opt eq "--bin") {
		$output_format = 'binary';
	} elsif ($opt eq "-H" || $opt eq "--hex") {
		$output_format = 'hex';
	} elsif ($opt eq "-D" || $opt eq "--dragondos") {
		$output_format = 'dragondos';
	} elsif ($opt eq "-C" || $opt eq "--coco") {
		$output_format = 'coco';
	} elsif ($opt eq "-e" || $opt eq "--exec") {
		shift @ARGV;
		if ($ARGV[0] =~ /^(.*)$/) {
			$exec_label = $1;  # de-taint
		}
	} elsif ($opt eq '-0' || $opt eq '--6800') {
		$isa = "6800";
	} elsif ($opt eq '-1' || $opt eq '--6801' || $opt eq '--6803') {
		$isa = "6801";
	} elsif ($opt eq '-8' || $opt eq '-9' || $opt eq '--6809') {
		$isa = '6809';
	} elsif ($opt eq "-3" || $opt eq "--6309") {
		$isa = '6309';
	} elsif ($opt eq "-x" || $opt eq "--extended") {
		$syntax_extended = 1;
	} elsif ($opt =~ /^--exec=(.*)$/) {
		$exec_label = $1;
	} elsif ($opt eq "-v" || $opt eq "--verbose") {
		$verbose++;
	} elsif ($opt eq "-q" || $opt eq "--quiet") {
		$quiet = 1;
	} elsif ($opt eq "--version") {
		print "asm6809.pl $VERSION\n";
		exit 0;
	} elsif ($opt eq "--help") {
		helptext();
		exit 0;
	} elsif ($opt =~ /^-/) {
		print STDERR "$0: unrecognised option '$opt'\n";
		print STDERR "Try '$0 --help' for more information.\n";
		exit 1;
	} else {
		push @files, $opt;
	}
	shift @ARGV;
}

# Append rest of command line to file list.
push @files, @ARGV;

if (!@files) {
	print STDERR "$0: source filename required\n";
	print STDERR "Try '$0 --help' for more information.\n";
	exit 1;
}

my $isa_6800 = ($isa eq '6800' || $isa eq '6801');
my $isa_6801 = ($isa eq '6801');
my $isa_6809 = ($isa eq '6809' || $isa eq '6309');
my $isa_6309 = ($isa eq '6309');

my %modes = (
	'includebin' => 'includebin',
	'export' => 'export',
	'org'   => 'equ',
	'put'   => 'equ',
	'equ'   => 'equ',
	'setdp' => 'setdp',
	'rmb'   => 'rmb',
	'rzb'   => 'rzb',
	'fill'  => 'fill',
	'fcb'	=> 'fcb',
	'fdb'	=> 'fdb',
	'fcc'	=> 'fcc',
);

my @opcodes_6800 = (

	nop => { inherent => '01' },
	tap => { inherent => '06' },
	tpa => { inherent => '07' },
	inx => { inherent => '08' },
	dex => { inherent => '09' },
	clv => { inherent => '0a' },
	sev => { inherent => '0b' },
	clc => { inherent => '0c' },
	sec => { inherent => '0d' },
	cli => { inherent => '0e' },
	sei => { inherent => '0f' },

	sba => { inherent => '10' },
	cba => { inherent => '11' },
	tab => { inherent => '16' },
	tba => { inherent => '17' },
	daa => { inherent => '19' },
	aba => { inherent => '1b' },

	bra => { relative => '20%b' },
	bhi => { relative => '22%b' },
	bls => { relative => '23%b' },
	bcc => { relative => '24%b' },
	bhs => { relative => '24%b' },
	bcs => { relative => '25%b' },
	blo => { relative => '25%b' },
	bne => { relative => '26%b' },
	beq => { relative => '27%b' },
	bvc => { relative => '28%b' },
	bvs => { relative => '29%b' },
	bpl => { relative => '2a%b' },
	bmi => { relative => '2b%b' },
	bge => { relative => '2c%b' },
	blt => { relative => '2d%b' },
	bgt => { relative => '2e%b' },
	ble => { relative => '2f%b' },

	tsx => { inherent => '30' },
	ins => { inherent => '31' },
	pula => { inherent => '32' },
	pulb => { inherent => '33' },
	des => { inherent => '34' },
	txs => { inherent => '35' },
	psha => { inherent => '36' },
	pshb => { inherent => '37' },
	rts => { inherent => '39' },
	rti => { inherent => '3b' },
	wai => { inherent => '3e' },
	swi => { inherent => '3f' },

	nega => { inherent => '40' },
	coma => { inherent => '43' },
	lsra => { inherent => '44' },
	rora => { inherent => '46' },
	asra => { inherent => '47' },
	lsla => { inherent => '48' },
	asla => { inherent => '48' },
	rola => { inherent => '49' },
	deca => { inherent => '4a' },
	inca => { inherent => '4c' },
	tsta => { inherent => '4d' },
	clra => { inherent => '4f' },

	negb => { inherent => '50' },
	comb => { inherent => '53' },
	lsrb => { inherent => '54' },
	rorb => { inherent => '56' },
	asrb => { inherent => '57' },
	lslb => { inherent => '58' },
	aslb => { inherent => '58' },
	rolb => { inherent => '59' },
	decb => { inherent => '5a' },
	incb => { inherent => '5c' },
	tstb => { inherent => '5d' },
	clrb => { inherent => '5f' },

	neg => { acc_op => 1, indexed00 => '60%i', extended => '70%w' },
	com => { acc_op => 1, indexed00 => '63%i', extended => '73%w' },
	lsr => { acc_op => 1, indexed00 => '64%i', extended => '74%w' },
	ror => { acc_op => 1, indexed00 => '66%i', extended => '76%w' },
	asr => { acc_op => 1, indexed00 => '67%i', extended => '77%w' },
	asl => { acc_op => 1, indexed00 => '68%i', extended => '78%w' },
	lsl => { acc_op => 1, indexed00 => '68%i', extended => '78%w' },
	rol => { acc_op => 1, indexed00 => '69%i', extended => '79%w' },
	dec => { acc_op => 1, indexed00 => '6a%i', extended => '7a%w' },
	inc => { acc_op => 1, indexed00 => '6c%i', extended => '7c%w' },
	tst => { acc_op => 1, indexed00 => '6d%i', extended => '7d%w' },
	jmp => { indexed00 => '6e%i', extended => '7e%w' },
	clr => { acc_op => 1, indexed00 => '6f%i', extended => '7f%w' },

	suba => { immediate => '80%b', direct => '90%b', indexed00 => 'a0%i', extended => 'b0%w' },
	cmpa => { immediate => '81%b', direct => '91%b', indexed00 => 'a1%i', extended => 'b1%w' },
	sbca => { immediate => '82%b', direct => '92%b', indexed00 => 'a2%i', extended => 'b2%w' },
	anda => { immediate => '84%b', direct => '94%b', indexed00 => 'a4%i', extended => 'b4%w' },
	bita => { immediate => '85%b', direct => '95%b', indexed00 => 'a5%i', extended => 'b5%w' },
	ldaa => { immediate => '86%b', direct => '96%b', indexed00 => 'a6%i', extended => 'b6%w' },
	staa => { direct => '97%b', indexed00 => 'a7%i', extended => 'b7%w' },
	eora => { immediate => '88%b', direct => '98%b', indexed00 => 'a8%i', extended => 'b8%w' },
	adca => { immediate => '89%b', direct => '99%b', indexed00 => 'a9%i', extended => 'b9%w' },
	oraa => { immediate => '8a%b', direct => '9a%b', indexed00 => 'aa%i', extended => 'ba%w' },
	adda => { immediate => '8b%b', direct => '9b%b', indexed00 => 'ab%i', extended => 'bb%w' },
	cpx => { immediate => '8c%w', direct => '9c%b', indexed00 => 'ac%i', extended => 'bc%w' },
	bsr => { relative => '8d%b' },
	jsr => { indexed00 => 'ad%i', extended => 'bd%w' },
	lds => { immediate => '8e%w', direct => '9e%b', indexed00 => 'ae%i', extended => 'be%w' },
	sts => { direct => '9f%b', indexed00 => 'af%i', extended => 'bf%w' },

	subb => { immediate => 'c0%b', direct => 'd0%b', indexed00 => 'e0%i', extended => 'f0%w' },
	cmpb => { immediate => 'c1%b', direct => 'd1%b', indexed00 => 'e1%i', extended => 'f1%w' },
	sbcb => { immediate => 'c2%b', direct => 'd2%b', indexed00 => 'e2%i', extended => 'f2%w' },
	andb => { immediate => 'c4%b', direct => 'd4%b', indexed00 => 'e4%i', extended => 'f4%w' },
	bitb => { immediate => 'c5%b', direct => 'd5%b', indexed00 => 'e5%i', extended => 'f5%w' },
	ldab => { immediate => 'c6%b', direct => 'd6%b', indexed00 => 'e6%i', extended => 'f6%w' },
	stab => { direct => 'd7%b', indexed00 => 'e7%i', extended => 'f7%w' },
	eorb => { immediate => 'c8%b', direct => 'd8%b', indexed00 => 'e8%i', extended => 'f8%w' },
	adcb => { immediate => 'c9%b', direct => 'd9%b', indexed00 => 'e9%i', extended => 'f9%w' },
	orab => { immediate => 'ca%b', direct => 'da%b', indexed00 => 'ea%i', extended => 'fa%w' },
	addb => { immediate => 'cb%b', direct => 'db%b', indexed00 => 'eb%i', extended => 'fb%w' },
	ldx => { immediate => 'ce%w', direct => 'de%b', indexed00 => 'ee%i', extended => 'fe%w' },
	stx => { direct => 'df%b', indexed00 => 'ef%i', extended => 'ff%w' },

	sub => { acc_op => 1 },
	cmp => { acc_op => 1 },
	sbc => { acc_op => 1 },
	and => { acc_op => 1 },
	bit => { acc_op => 1 },
	lda => { acc_op => 1 },
	sta => { acc_op => 1 },
	eor => { acc_op => 1 },
	adc => { acc_op => 1 },
	ora => { acc_op => 1 },
	add => { acc_op => 1 },

	psh => { acc_op => 1 },
	pul => { acc_op => 1 },

);

# Additions to the 6800 ISA
my @opcodes_6801 = (

	lsrd => { inherent => '04' },
	asld => { inherent => '05' },
	lsld => { inherent => '05' },

	brn => { relative => '21%b' },

	pulx => { inherent => '38' },
	abx => { inherent => '3a' },
	pshx => { inherent => '3c' },
	mul => { inherent => '3d' },

	subd => { immediate => '83%w', direct => '93%b', indexed00 => 'a3%i', extended => 'b3%w' },

	jsr => { direct => '9d%b', indexed00 => 'ad%i', extended => 'bd%w' },

	addd => { immediate => 'c3%w', direct => 'd3%b', indexed00 => 'e3%i', extended => 'f3%w' },
	ldd => { immediate => 'cc%w', direct => 'dc%b', indexed00 => 'ec%i', extended => 'fc%w' },
	std => { direct => 'dd%b', indexed00 => 'ed%i', extended => 'fd%w' },

	psh => { acc_op => 1 },
	pul => { acc_op => 1 },

);

my @opcodes_6809 = (

	neg => { direct => '00%b', indexed => '60%i', extended => '70%w' },
	com => { direct => '03%b', indexed => '63%i', extended => '73%w' },
	lsr => { direct => '04%b', indexed => '64%i', extended => '74%w' },
	ror => { direct => '06%b', indexed => '66%i', extended => '76%w' },
	asr => { direct => '07%b', indexed => '67%i', extended => '77%w' },
	asl => { direct => '08%b', indexed => '68%i', extended => '78%w' },
	lsl => { direct => '08%b', indexed => '68%i', extended => '78%w' },
	rol => { direct => '09%b', indexed => '69%i', extended => '79%w' },
	dec => { direct => '0a%b', indexed => '6a%i', extended => '7a%w' },
	inc => { direct => '0c%b', indexed => '6c%i', extended => '7c%w' },
	tst => { direct => '0d%b', indexed => '6d%i', extended => '7d%w' },
	jmp => { direct => '0e%b', indexed => '6e%i', extended => '7e%w' },
	clr => { direct => '0f%b', indexed => '6f%i', extended => '7f%w' },

	nop => { inherent => '12' },
	sync => { inherent => '13' },
	lbra => { longrelative => '16%w' },
	lbsr => { longrelative => '17%w' },
	daa => { inherent => '19' },
	orcc => { immediate => '1a%b' },
	andcc => { immediate => '1c%b' },
	sex => { inherent => '1d' },
	exg => { pair => '1e%b' },
	tfr => { pair => '1f%b' },

	bra => { relative => '20%b' },
	brn => { relative => '21%b' },
	bhi => { relative => '22%b' },
	bls => { relative => '23%b' },
	bcc => { relative => '24%b' },
	bhs => { relative => '24%b' },
	bcs => { relative => '25%b' },
	blo => { relative => '25%b' },
	bne => { relative => '26%b' },
	beq => { relative => '27%b' },
	bvc => { relative => '28%b' },
	bvs => { relative => '29%b' },
	bpl => { relative => '2a%b' },
	bmi => { relative => '2b%b' },
	bge => { relative => '2c%b' },
	blt => { relative => '2d%b' },
	bgt => { relative => '2e%b' },
	ble => { relative => '2f%b' },

	leax => { indexed => '30%i' },
	leay => { indexed => '31%i' },
	leas => { indexed => '32%i' },
	leau => { indexed => '33%i' },

	pshs => { stack => '34%s' },
	puls => { stack => '35%s' },
	pshu => { stack => '36%u' },
	pulu => { stack => '37%u' },
	rts => { inherent => '39' },
	abx => { inherent => '3a' },
	rti => { inherent => '3b' },
	cwai => { immediate => '3c%b' },
	mul => { inherent => '3d' },
	swi => { inherent => '3f' },

	nega => { inherent => '40' },
	coma => { inherent => '43' },
	lsra => { inherent => '44' },
	rora => { inherent => '46' },
	asra => { inherent => '47' },
	lsla => { inherent => '48' },
	asla => { inherent => '48' },
	rola => { inherent => '49' },
	deca => { inherent => '4a' },
	inca => { inherent => '4c' },
	tsta => { inherent => '4d' },
	clra => { inherent => '4f' },

	negb => { inherent => '50' },
	comb => { inherent => '53' },
	lsrb => { inherent => '54' },
	rorb => { inherent => '56' },
	asrb => { inherent => '57' },
	lslb => { inherent => '58' },
	aslb => { inherent => '58' },
	rolb => { inherent => '59' },
	decb => { inherent => '5a' },
	incb => { inherent => '5c' },
	tstb => { inherent => '5d' },
	clrb => { inherent => '5f' },

	suba => { immediate => '80%b', direct => '90%b', indexed => 'a0%i', extended => 'b0%w' },
	cmpa => { immediate => '81%b', direct => '91%b', indexed => 'a1%i', extended => 'b1%w' },
	sbca => { immediate => '82%b', direct => '92%b', indexed => 'a2%i', extended => 'b2%w' },
	subd => { immediate => '83%w', direct => '93%b', indexed => 'a3%i', extended => 'b3%w' },
	anda => { immediate => '84%b', direct => '94%b', indexed => 'a4%i', extended => 'b4%w' },
	bita => { immediate => '85%b', direct => '95%b', indexed => 'a5%i', extended => 'b5%w' },
	lda => { immediate => '86%b', direct => '96%b', indexed => 'a6%i', extended => 'b6%w' },
	sta => { direct => '97%b', indexed => 'a7%i', extended => 'b7%w' },
	eora => { immediate => '88%b', direct => '98%b', indexed => 'a8%i', extended => 'b8%w' },
	adca => { immediate => '89%b', direct => '99%b', indexed => 'a9%i', extended => 'b9%w' },
	ora => { immediate => '8a%b', direct => '9a%b', indexed => 'aa%i', extended => 'ba%w' },
	adda => { immediate => '8b%b', direct => '9b%b', indexed => 'ab%i', extended => 'bb%w' },
	cmpx => { immediate => '8c%w', direct => '9c%b', indexed => 'ac%i', extended => 'bc%w' },
	bsr => { relative => '8d%b' },
	jsr => { direct => '9d%b', indexed => 'ad%i', extended => 'bd%w' },
	ldx => { immediate => '8e%w', direct => '9e%b', indexed => 'ae%i', extended => 'be%w' },
	stx => { direct => '9f%b', indexed => 'af%i', extended => 'bf%w' },

	subb => { immediate => 'c0%b', direct => 'd0%b', indexed => 'e0%i', extended => 'f0%w' },
	cmpb => { immediate => 'c1%b', direct => 'd1%b', indexed => 'e1%i', extended => 'f1%w' },
	sbcb => { immediate => 'c2%b', direct => 'd2%b', indexed => 'e2%i', extended => 'f2%w' },
	addd => { immediate => 'c3%w', direct => 'd3%b', indexed => 'e3%i', extended => 'f3%w' },
	andb => { immediate => 'c4%b', direct => 'd4%b', indexed => 'e4%i', extended => 'f4%w' },
	bitb => { immediate => 'c5%b', direct => 'd5%b', indexed => 'e5%i', extended => 'f5%w' },
	ldb => { immediate => 'c6%b', direct => 'd6%b', indexed => 'e6%i', extended => 'f6%w' },
	stb => { direct => 'd7%b', indexed => 'e7%i', extended => 'f7%w' },
	eorb => { immediate => 'c8%b', direct => 'd8%b', indexed => 'e8%i', extended => 'f8%w' },
	adcb => { immediate => 'c9%b', direct => 'd9%b', indexed => 'e9%i', extended => 'f9%w' },
	orb => { immediate => 'ca%b', direct => 'da%b', indexed => 'ea%i', extended => 'fa%w' },
	addb => { immediate => 'cb%b', direct => 'db%b', indexed => 'eb%i', extended => 'fb%w' },
	ldd => { immediate => 'cc%w', direct => 'dc%b', indexed => 'ec%i', extended => 'fc%w' },
	std => { direct => 'dd%b', indexed => 'ed%i', extended => 'fd%w' },
	ldu => { immediate => 'ce%w', direct => 'de%b', indexed => 'ee%i', extended => 'fe%w' },
	stu => { direct => 'df%b', indexed => 'ef%i', extended => 'ff%w' },

	lbrn => { longrelative => '1021%w' },
	lbhi => { longrelative => '1022%w' },
	lbls => { longrelative => '1023%w' },
	lbcc => { longrelative => '1024%w' },
	lbhs => { longrelative => '1024%w' },
	lbcs => { longrelative => '1025%w' },
	lblo => { longrelative => '1025%w' },
	lbne => { longrelative => '1026%w' },
	lbeq => { longrelative => '1027%w' },
	lbvc => { longrelative => '1028%w' },
	lbvs => { longrelative => '1029%w' },
	lbpl => { longrelative => '102a%w' },
	lbmi => { longrelative => '102b%w' },
	lbge => { longrelative => '102c%w' },
	lblt => { longrelative => '102d%w' },
	lbgt => { longrelative => '102e%w' },
	lble => { longrelative => '102f%w' },

	swi2 => { inherent => '103f' },

	cmpd => { immediate => '1083%w', direct => '1093%b', indexed => '10a3%i', extended => '10b3%w' },
	cmpy => { immediate => '108c%w', direct => '109c%b', indexed => '10ac%i', extended => '10bc%w' },
	ldy => { immediate => '108e%w', direct => '109e%b', indexed => '10ae%i', extended => '10be%w' },
	sty => { direct => '109f%b', indexed => '10af%i', extended => '10bf%w' },

	lds => { immediate => '10ce%w', direct => '10de%b', indexed => '10ee%i', extended => '10fe%w' },
	sts => { direct => '10df%b', indexed => '10ef%i', extended => '10ff%w' },

	swi3 => { inherent => '113f' },

	cmpu => { immediate => '1183%w', direct => '1193%b', indexed => '11a3%i', extended => '11b3%w' },
	cmps => { immediate => '118c%w', direct => '119c%b', indexed => '11ac%i', extended => '11bc%w' },

);

my @opcodes_6309 = (

	oim => { imm_mem => '%b', direct => '01%t%b', indexed => '61%t%i', extended => '71%t%w' },
	aim => { imm_mem => '%b', direct => '02%t%b', indexed => '62%t%i', extended => '72%t%w' },
	eim => { imm_mem => '%b', direct => '05%t%b', indexed => '65%t%i', extended => '75%t%w' },
	tim => { imm_mem => '%b', direct => '0b%t%b', indexed => '6b%t%i', extended => '7b%t%w' },

	sexw => { inherent => '14' },

	ldq => { immediate => 'cd%q', direct => '10dc%b', indexed => '10ec%i', extended => '10fc%w' },

	addr => { pair => '1030%b' },
	adcr => { pair => '1031%b' },
	subr => { pair => '1032%b' },
	sbcr => { pair => '1033%b' },
	andr => { pair => '1034%b' },
	orr => { pair => '1035%b' },
	eorr => { pair => '1036%b' },
	cmpr => { pair => '1037%b' },
	pshsw => { inherent => '1038' },
	pulsw => { inherent => '1039' },
	pshuw => { inherent => '103a' },
	puluw => { inherent => '103b' },

	negd => { inherent => '1040' },
	comd => { inherent => '1043' },
	lsrd => { inherent => '1044' },
	rord => { inherent => '1046' },
	asrd => { inherent => '1047' },
	lsld => { inherent => '1048' },
	asld => { inherent => '1048' },
	rold => { inherent => '1049' },
	decd => { inherent => '104a' },
	incd => { inherent => '104c' },
	tstd => { inherent => '104d' },
	clrd => { inherent => '104f' },

	comw => { inherent => '1053' },
	lsrw => { inherent => '1054' },
	rorw => { inherent => '1056' },
	rolw => { inherent => '1059' },
	decw => { inherent => '105a' },
	incw => { inherent => '105c' },
	tstw => { inherent => '105d' },
	clrw => { inherent => '105f' },

	subw => { immediate => '1080%w', direct => '1090%b', indexed => '10a0%i', extended => '10b0%w' },
	cmpw => { immediate => '1081%w', direct => '1091%b', indexed => '10a1%i', extended => '10b1%w' },
	sbcd => { immediate => '1082%w', direct => '1092%b', indexed => '10a2%i', extended => '10b2%w' },
	andd => { immediate => '1084%w', direct => '1094%b', indexed => '10a4%i', extended => '10b4%w' },
	bitd => { immediate => '1085%w', direct => '1095%b', indexed => '10a5%i', extended => '10b5%w' },
	ldw => { immediate => '1086%w', direct => '1096%b', indexed => '10a6%i', extended => '10b6%w' },
	stw => { direct => '1097%b', indexed => '10a7%i', extended => '10b7%w' },
	eord => { immediate => '1088%w', direct => '1098%b', indexed => '10a8%i', extended => '10b8%w' },
	adcd => { immediate => '1089%w', direct => '1099%b', indexed => '10a9%i', extended => '10b9%w' },
	ord => { immediate => '108a%w', direct => '109a%b', indexed => '10aa%i', extended => '10ba%w' },
	addw => { immediate => '108b%w', direct => '109b%b', indexed => '10ab%i', extended => '10bb%w' },

	stq => { direct => '10dd%b', indexed => '10ed%i', extended => '10fd%w' },

	band => { reg_mem => '1130%p%b' },
	biand => { reg_mem => '1131%p%b' },
	bor => { reg_mem => '1132%p%b' },
	bior => { reg_mem => '1133%p%b' },
	beor => { reg_mem => '1134%p%b' },
	bieor => { reg_mem => '1135%p%b' },
	ldbt => { reg_mem => '1136%p%b' },
	stbt => { reg_mem => '1137%p%b' },
	tfm => { tfm => '11%p%b' },
	bitmd => { immediate => '113c%b' },
	ldmd => { immediate => '113d%b' },

	come => { inherent => '1143' },
	dece => { inherent => '114a' },
	ince => { inherent => '114c' },
	tste => { inherent => '114d' },
	clre => { inherent => '114f' },

	comf => { inherent => '1153' },
	decf => { inherent => '115a' },
	incf => { inherent => '115c' },
	tstf => { inherent => '115d' },
	clrf => { inherent => '115f' },

	sube => { immediate => '1180%b', direct => '1190%b', indexed => '11a0%i', extended => '11b0%w' },
	cmpe => { immediate => '1181%b', direct => '1191%b', indexed => '11a1%i', extended => '11b1%w' },
	lde => { immediate => '1186%b', direct => '1196%b', indexed => '11a6%i', extended => '11b6%w' },
	ste => { direct => '1197%b', indexed => '11a7%i', extended => '11b7%w' },
	adde => { immediate => '118b%b', direct => '119b%b', indexed => '11ab%i', extended => '11bb%w' },
	divd => { immediate => '118d%b', direct => '119d%b', indexed => '11ad%i', extended => '11bd%w' },
	divq => { immediate => '118e%w', direct => '119e%b', indexed => '11ae%i', extended => '11be%w' },
	muld => { immediate => '118f%w', direct => '119f%b', indexed => '11af%i', extended => '11bf%w' },

	subf => { immediate => '11c0%b', direct => '11d0%b', indexed => '11e0%i', extended => '11f0%w' },
	cmpf => { immediate => '11c1%b', direct => '11d1%b', indexed => '11e1%i', extended => '11f1%w' },
	ldf => { immediate => '11c6%b', direct => '11d6%b', indexed => '11e6%i', extended => '11f6%w' },
	stf => { direct => '11d7%b', indexed => '11e7%i', extended => '11f7%w' },
	addf => { immediate => '11cb%b', direct => '11db%b', indexed => '11eb%i', extended => '11fb%w' },

);

my @opcodes_extended = (

	fa => { direct => '%b', indexed => '%i', extended => '%w' },
	fr => { pair => '%b' },
	frbm => { reg_mem => '%p%b' },

);

my %opcodes = ();

# Generate opcode hash from ISA flags
add_opcodes(\@opcodes_6800, \%opcodes) if ($isa_6800);
add_opcodes(\@opcodes_6801, \%opcodes) if ($isa_6801);
add_opcodes(\@opcodes_6809, \%opcodes) if ($isa_6809);
add_opcodes(\@opcodes_6309, \%opcodes) if ($isa_6309);
add_opcodes(\@opcodes_extended, \%opcodes) if ($syntax_extended);

if ($isa_6800) {
	delete $modes{'setdp'};
}

my %arg_parse = (
	macro => \&parse_macro,
	export => \&parse_export,
	equ => \&parse_equ,
	setdp => \&parse_setdp,
	rmb => \&parse_rmb,
	rzb => \&parse_rzb,
	fill => \&parse_fill,
	fcb => \&parse_fcb,
	fdb => \&parse_fdb,
	fcc => \&parse_fcc,
	stack => \&parse_stack,
	pair => \&parse_pair,
	tfm => \&parse_tfm,
	address => \&parse_address,
	immediate => \&parse_immediate,
	imm_mem => \&parse_imm_mem,
	reg_mem => \&parse_reg_mem,
	direct => \&parse_direct,
	indexed => \&parse_indexed,
	indexed00 => \&parse_indexed_6800,
	extended => \&parse_extended,
	inherent => \&parse_inherent,
	relative => \&parse_relative,
	longrelative => \&parse_longrelative,
	acc_op => \&parse_acc_op,
);

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

### Pass 1
# First pass is purely reading in files, building macros

my %macros = ();
my $defining_macro = undef;
my $file_ctx = { };

my @syntax_errors = ();  # syntax errors fatal after first pass
my @errors = ();  # other errors and warnings go in here
my %label_errors = ();  # only report missing labels once

my $input = [];
for (@files) {
	read_file($_, $input);
}
die_if_syntax_error();

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

### Pass 2
# Second pass splits input into sections

my @section_list;
my %sections;

{

	my $section_name = "";
	@section_list = ( $section_name );
	%sections = ( $section_name => [] );
	my $section = $sections{$section_name};

	$file_ctx = { filename => "", lno => 0 };

	for my $cmd (@$input) {
		if (exists $$cmd{pragma}) {
			if ($$cmd{pragma} eq 'line') {
				$file_ctx = { %{$$cmd{file_ctx}} };
				push @$section, { pragma => 'line', file_ctx => { %{$file_ctx} } };
			} else {
				syntax_error("internal error: bad pragma");
			}
			next;
		}
		if (exists $$cmd{opcode} && $$cmd{opcode} eq 'section') {
			# Actually changing section?
			if ($section_name ne $$cmd{arg}) {
				$section_name = $$cmd{arg};  # XXX validate
				# New section?
				if (!exists $sections{$section_name}) {
					$sections{$section_name} = [];
					push @section_list, $section_name;
				}
				$section = $sections{$section_name};
				push @$section, { pragma => 'line', file_ctx => { %{$file_ctx} } };
			}
			$$file_ctx{lno}++;
			delete $$cmd{opcode};
			push @$section, $cmd;
			next;
		}
		$$file_ctx{lno}++;
		push @$section, $cmd;
	}
	undef $input;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

### Pass 3+
# Assemble sections until stable

my $pass = 2;

my $unresolved = 1;
my @listing;
my $pc = 0;
my $put = 0;
my $dp = undef;
my $exec_addr = undef;
my %equs = ();
my %export_labels = ();
my $asection;  # array ref of section currently being assembled
my $as_index;  # track where in the section array we are

if ($isa_6800) {
	$dp = 0;
}

while ($unresolved && $pass < 10) {
	$pass++;
	print STDERR "=== Pass $pass\n" if ($verbose);

	$unresolved = 0;
	@listing = ();
	@errors = ();
	%label_errors = ();
	$pc = 0;
	$put = 0;

	$file_ctx = { filename => "", lno => 0 };

	for my $sname (@section_list) {
		print STDERR "==> SECTION $sname\n" if ($verbose && $sname);
		$asection = $sections{$sname};
		$as_index = -1;
		for my $cmd (@$asection) {
			$as_index++;
			if (exists $$cmd{pragma}) {
				if ($$cmd{pragma} eq 'line') {
					$file_ctx = { %{$$cmd{file_ctx}} };
					push @listing, $cmd;
				} else {
					syntax_error("internal error: bad pragma");
				}
				next;
			}
			$$file_ctx{lno}++;

			process_cmd($cmd);

		}
	}

	if (defined $exec_label) {
		$exec_addr = eval_expr($exec_label);
		print STDERR "*** exec_addr undefined\n" if ($verbose && !defined $exec_addr);
		$unresolved = 1 if (!defined $exec_addr);
	}

	die_if_syntax_error();

}

print STDERR "$_\n" for (@errors);

if ($unresolved) {
	print STDERR "error: unresolved after $pass passes\n";
	exit 1;
}

undef %sections;
undef @section_list;

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

my %region_start = ();
my %region_end = ();

$file_ctx = { filename => "", lno => 0 };

my $listing_file = undef;
if (defined $listing_filename) {
	open($listing_file, ">", $listing_filename);
}

#
# Place instruction text into regions.
# Generate listing file if required.
#

for my $cmd (@listing) {
	my ($start,$end) = (undef,undef);
	my $addr = "";
	my $text = $$cmd{text} || "";
	my $line = expand($$cmd{line} || "");
	my $label = $$cmd{label} || "";
	my $opcode = $$cmd{opcode} || "";
	if ($label && $$cmd{label} !~ /^\d+$/) {
		$start = $$cmd{put};
		$addr = sprintf("\%04X", $equs{$$cmd{label}} & 0xffff);
	} elsif ($text || $label || $opcode eq 'org' || $opcode eq 'put') {
		$start = $$cmd{put};
		$addr = sprintf("\%04X", $$cmd{addr} || 0);
	}
	if (defined $listing_file) {
		printf $listing_file "\%-6s\%-14s  \%s\n", $addr, uc $text, $line;
	}
	if ($text) {
		my $end = $start + $$cmd{size};
		if (exists $region_end{$start}) {
			my $region = $region_end{$start};
			$$region{text} .= $text;
			$$region{end} = $end;
			delete $region_end{$start};
			$region_end{$end} = $region;
		} elsif (exists $region_start{$end}) {
			my $region = $region_start{$end};
			$$region{text} = $text . $$region{text};
			$$region{start} = $start;
			delete $region_start{$end};
			$region_start{$start} = $region;
		} else {
			my $region = {
				text => $text,
				start => $start,
				end => $end,
			};
			$region_start{$start} = $region;
			$region_end{$end} = $region;
		}
	}
}

undef @listing;

if (defined $listing_file) {
	close $listing_file;
}

#
# Generate symbols file, if required.
#

if (defined $symbols_filename) {
	if (open(my $symbols_file, ">", $symbols_filename)) {
		for my $label (keys %export_labels) {
			if (exists $macros{$label}) {
				print $symbols_file "$label\tmacro\n";
				for (@{$macros{$label}}) {
					print $symbols_file "$_->{line}\n";
				}
				print $symbols_file "\tendm\n";
			} elsif (exists $equs{$label}) {
				print $symbols_file "$label\tequ\t$equs{$label}\n";
			}
		}
		close $symbols_file;
	} else {
		die "Couldn't open $symbols_filename for writing: $!\n";
	}
}
undef %export_labels;
undef %macros;

exit 0 if (!defined $output_filename);

#
# Generate output file.
#

my $output_file = undef;
unless (open($output_file, ">", $output_filename)) {
	die "Couldn't open $output_filename for writing: $!\n";
}
binmode $output_file;

my @regions = sort { $a <=> $b } keys %region_start;

if ($output_format eq 'dragondos') {
	my $start = $regions[0];
	my $region0 = $region_start{$start};
	my $regionl = $region_start{$regions[$#regions]};
	my $length = ($regions[$#regions] + (length($$regionl{text}) / 2)) - $start;
	my $exec = (defined $exec_addr) ? $exec_addr : $start;
	print $output_file pack("CCnnnC", 0x55, 0x02, $start, $length, $exec, 0xaa);
}

my $last_region_end = undef;
for my $r (sort { $a <=> $b } keys %region_start) {
	my $region = $region_start{$r};
	my $addr = $r;
	if ($output_format eq 'binary' || $output_format eq 'dragondos') {
		if (defined $last_region_end) {
			my $skip = $addr - $last_region_end;
			print $output_file "\0" x $skip;
		}
		print $output_file pack("H*", $$region{text});
	} elsif ($output_format eq 'hex') {
		my $size = length($$region{text}) / 2;
		my $offset = 0;
		while ($size > 0) {
			my $bytes = ($size > 32) ? 32 : $size;
			printf $output_file ":\%02X\%04X00\%s00\n", $bytes, $addr, uc substr($$region{text}, $offset, $bytes * 2);
			$offset += $bytes * 2;
			$addr += $bytes;
			$size -= $bytes;
		}
	} elsif ($output_format eq 'coco') {
		print $output_file pack("xnnH*", length($$region{text}) / 2, $addr, $$region{text});
	}
	$last_region_end = $$region{end};
}

if ($output_format eq 'hex') {
	print $output_file ":00000001FF\n";
} elsif ($output_format eq 'coco' && defined $exec_addr) {
	print $output_file pack("Cxxn", 255, $exec_addr);
}
close $output_file;

exit 0;

############################################################################

# Used while generating the list of allowed opcodes.  Adds opcodes
# from a (ref to) list of pairs into the destination opcode hash.

sub add_opcodes {
	my $opcode_list = shift;
	my $dest_hash = shift;
	while (my $k = shift @{$opcode_list}) {
		my $v = shift @{$opcode_list};
		$dest_hash->{$k} = $v;
	}
}

############################################################################

# Read in a file and scan lines into an array.
# Globals:
#    $file_ctx - current file context (filename,lno)

sub read_file {
	my ($filename, $input) = @_;
	my $fd;
	OPENFILE: {
		for (@include_path) {
			last OPENFILE if open($fd, "<", "$_/$filename");
		}
		die "Couldn't open $filename: $!\n";
	}
	$input ||= [];
	print STDERR "=== Reading file '$filename'\n" if ($verbose);
	$file_ctx = { filename => $filename, lno => 0 };
	push @$input, { pragma => 'line', file_ctx => { %{$file_ctx} } };
	while (my $line = <$fd>) {
		chomp $line;
		$$file_ctx{lno}++;

		# Blank or pure comment lines
		if ($line =~ /^\s*[;*]/) {
			push @$input, { line => $line };
			next;
		}

		my $cmd = scan_line($line, $defining_macro);
		my $opcode = $$cmd{opcode} || "";

		# Include file
		if ($opcode eq 'include') {
			# Stop defining any macro
			undef $defining_macro;
			my $include_filename = $$cmd{arg};
			# Keep label
			delete $$cmd{opcode};
			delete $$cmd{arg};
			push @$input, $cmd;
			if ($include_filename =~ /^([\/\"\'])?(.*)\1\s*$/) {
				$include_filename = $2;
			}
			my $old_file_ctx = { %{$file_ctx} };
			read_file($include_filename, $input);
			$file_ctx = $old_file_ctx;
			push @$input, { pragma => 'line', file_ctx => { %{$file_ctx} } };
			next;
		}

		# Include binary file
		if ($opcode eq 'includebin') {
			my $include_filename = $$cmd{arg};
			# Keep label
			#delete $$cmd{opcode};
			delete $$cmd{arg};
			push @$input, $cmd;
			if ($include_filename =~ /^([\/\"\'])?(.*)\1\s*$/) {
				$include_filename = $2;
			}
			my $fd;
			my $size = -s $include_filename;
			unless ($size && open($fd, "<", $include_filename)) {
				die "Couldn't open $include_filename: $!\n";
			}
			my $bin;
			read $fd, $bin, $size;
			$$cmd{size} = $size;
			$$cmd{text} = unpack("H*", $bin);
			close $fd;
			next;
		}

		# Start defining a macro
		if ($opcode eq 'macro') {
			my $new_macro = $$cmd{label};
			if (!defined $new_macro || $new_macro !~ /^\w+/) {
				syntax_error("bad macro name");
				next;
			}
			push @$input, { line => $$cmd{line} };
			$defining_macro = $new_macro;
			next;
		}

		# Finish defining a macro
		if ($opcode eq 'endm') {
			if (!defined $defining_macro) {
				syntax_error("endm with no macro");
				next;
			}
			# A label on the endm should be included in the macro
			if (exists $$cmd{label}) {
				push @{$macros{$defining_macro}}, { label => $$cmd{label} };
			}
			push @$input, { line => $$cmd{line} };
			undef $defining_macro;
			next;
		}

		# Add line as appropriate
		if (defined $defining_macro) {
			push @$input, { line => $$cmd{line} };
			push @{$macros{$defining_macro}}, $cmd;
		} else {
			push @$input, $cmd;
		}

	}

	# Stop defining any macro
	undef $defining_macro;

	close $fd;
	return $input;
}

# Break a line into (label,opcode,arg) and ensure label & opcode don't have
# any dodgy characters in them.  Allows \&\d+ when $defining_macro is set.
# Returns a hash of the parts.

sub scan_line {
	my ($line, $defining_macro) = @_;

	my $cmd = { line => $line };
	my ($label, $opcode, $arg) = split(/\s+/, $line, 3);
	$label = "" unless (defined $label);
	$opcode = "" unless (defined $opcode);
	$opcode = "" if ($opcode =~ /^;/);
	$arg = "" unless (defined $arg);

	if (!defined $defining_macro) {
		if ($label) {
			if ($label =~ /^([\w\@]+)$/) {
				$label = $1;  # de-taint label
				$$cmd{label} = $label;
			} else {
				syntax_error("bad label");
				return;
			}
		}
		if ($opcode) {
			if ($opcode =~ /^(\w+)$/) {
				$opcode = lc $1;  # de-taint opcode
				$$cmd{opcode} = $opcode;
			} else {
				syntax_error("bad opcode");
				return;
			}
		}
	} else {
		if ($label) {
			if ($label =~ /^(((\&\d+)|[\w\@])+)$/) {
				$label = $1;  # de-taint label
				$$cmd{label} = $label;
			} else {
				syntax_error("bad label in macro");
				return;
			}
		}
		if ($opcode) {
			if ($opcode =~ /^(((\&\d+)|\w)+)$/) {
				$opcode = lc $1;  # de-taint opcode
				$$cmd{opcode} = $opcode;
			} else {
				syntax_error("bad opcode in macro");
				return;
			}
		}
	}

	if (defined $arg) {
		# FCC is a special case.  Comments can safely be stripped from
		# arguments to all other opcodes.
		if ($opcode ne 'fcc') {
			$arg =~ s/\s+;.*//;
		}

		# Leave $$cmd{arg} tainted, nothing should use it unparsed
		if ($arg !~ /^;/) {
			$$cmd{arg} = $arg;
		}
	}

	return $cmd;
}

############################################################################

# Determine the mode of an instruction (not pseudo-op or macro)
sub instr_mode {
	my ($opcode,$arg) = @_;
	return undef if (!$opcode);
	$opcode = lc $opcode;
	return undef if (!exists $opcodes{$opcode});
	my $mode = "";
	if (exists $opcodes{$opcode}->{stack}) {
		$mode = 'stack';
	} elsif ($arg && !exists $opcodes{$opcode}->{inherent}) {
		# If an arg is specified, determine mode from it:
		if (exists $opcodes{$opcode}->{pair}) {
			$mode = 'pair';
		} elsif (exists $opcodes{$opcode}->{tfm}) {
			$mode = 'tfm';
		} elsif (exists $opcodes{$opcode}->{stack}) {
			$mode = 'stack';
		} elsif (exists $opcodes{$opcode}->{reg_mem}) {
			$mode = 'reg_mem';
		} elsif (exists $opcodes{$opcode}->{relative}) {
			$mode = 'relative';
		} elsif (exists $opcodes{$opcode}->{longrelative}) {
			$mode = 'longrelative';
		} elsif ($isa_6800 && exists $opcodes{$opcode}->{acc_op} && $arg =~ /^[ab](\s.*)?$/i) {
			$mode = 'acc_op';
		} elsif ($isa_6801 && exists $opcodes{$opcode}->{acc_op} && $arg =~ /^x(\s.*)?$/i) {
			$mode = 'acc_op';
		} elsif (exists $opcodes{$opcode}->{imm_mem} && $arg =~ /^#/) {
			$mode = 'imm_mem';
		} elsif ($arg =~ /^#/) {
			if (exists $opcodes{$opcode}->{immediate}) {
				$mode = 'immediate';
			} else {
				syntax_error("immediate addressing not available for '$opcode'");
			}
		} elsif ($arg =~ /^\[.*\]$/ || $arg =~ /,/) {
			if ($isa_6800 && exists $opcodes{$opcode}->{indexed00}) {
				$mode = 'indexed00';
			} elsif (exists $opcodes{$opcode}->{indexed}) {
				$mode = 'indexed';
			} else {
				syntax_error("indexed addressing not available for '$opcode'");
			}
		} elsif ($isa_6800 && lc($arg) eq 'x') {
			if (exists $opcodes{$opcode}->{indexed00}) {
				$mode = 'indexed00';
			} else {
				syntax_error("indexed addressing not available for '$opcode'");
			}
		} elsif ($arg =~ /^</) {
			if (exists $opcodes{$opcode}->{direct}) {
				$mode = 'direct';
			} else {
				syntax_error("direct addressing not available for '$opcode'");
			}
		} elsif ($arg =~ /^>/) {
			if (exists $opcodes{$opcode}->{extended}) {
				$mode = 'extended';
			} else {
				syntax_error("extended addressing not available for '$opcode'");
			}
		} else {
			# The special mode 'address' will have
			# arg checked by parse_address()
			$mode = 'address';
		}
	} elsif (exists $opcodes{$opcode}->{inherent}) {
		$mode = 'inherent';
	} else {
		syntax_error("cannot determine addressing mode for '$opcode'");
	}
	return $mode;
}

# Assemble one line.
sub process_cmd {
	my ($cmd) = @_;

	push @listing, $cmd;

	my $label = $$cmd{label} || "";
	my $opcode = $$cmd{opcode} || "";
	return if (!$label && !$opcode);

	# Determine the mode of an opcode.  If an arg is specified, check it's
	# valid for the opcode.  No arg implies inherent, also checked.
	my $mode = "";
	my $arg = $$cmd{arg} || "";
	if ($opcode) {
		# Mostly simple precendence rules:
		if (exists $modes{lc $opcode}) {
			$opcode = lc $opcode;
			$mode = $modes{lc $opcode};
		} elsif (exists $opcodes{lc $opcode}) {
			$opcode = lc $opcode;
			$mode = instr_mode($opcode, $arg);
		} elsif (exists $macros{$opcode}) {
			$mode = "macro";
		} else {
			syntax_error("unknown opcode '$opcode'");
		}
	}

	# Copy appropriate template into the hash for parsing.
	if ($mode && $mode ne 'macro') {
		$$cmd{mode} = $mode;
		if (exists $opcodes{$opcode}->{$mode}) {
			$$cmd{tmpl} = $opcodes{$opcode}->{$mode};
		}
	}

	# Verify address/label: EQU is a special case.
	verify_address($cmd, $pc, $put) if ($mode ne 'equ');

	# Call appropriate parse routine, fills in text & size.
	if (exists $arg_parse{$mode}) {
		$arg_parse{$mode}($cmd);
	}

	# Address of next instruction.
	$pc += $$cmd{size} if (exists $$cmd{size});
	$put += $$cmd{size} if (exists $$cmd{size});
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Check instruction address against supplied PC
sub verify_address {
	my ($cmd, $pc, $put) = @_;

	# If the address of this instruction has changed since last
	# time, mark unresolved.
	if (exists $$cmd{addr} && $$cmd{addr} != $pc) {
		printf STDERR "*** line %d: \$%04x != \$%04x\n", $$file_ctx{lno}, $$cmd{addr}, $pc if ($verbose);
		$unresolved = 1;
	}
	$$cmd{put} = $put;
	$$cmd{addr} = $pc;

	# For non-local labels, if the address of a label has changed
	# since last time, mark unresolved.
	my $label = $$cmd{label} || "";
	if ($label && $label !~ /^\d+$/) {
		if (exists $equs{$label} && $equs{$label} != $pc) {
			printf STDERR "*** $label: \$%04x != \$%04x\n", $equs{$label}, $pc if ($verbose);
			$unresolved = 1;
		}
		$equs{$label} = $pc;
	}
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Expand a macro performing substitution, calling process_cmd for each line.
sub parse_macro {
	my ($cmd) = @_;
	my $macro = $macros{$$cmd{opcode}};
	my $arg = $$cmd{arg};

	# Intelligently split comma-separated list of args
	my @args = ();
	if (defined $arg) {
		$arg =~ s/^\s+//;
		while ($arg ne "") {
			last if ($arg =~ /^;/);  # skip comments
			if ($arg =~ /^,/) {
				# empty expression not allowed
				syntax_error("bad expression in macro");
				return;
			} elsif ($arg =~ /^([\/\"!])(.*?)(\1)\s*(.*)?$/) {
				# string
				$arg = $4;
				push @args, $2;
			} elsif ($arg =~ /^([^,;]*)(.*)$/) {
				# expression
				$arg = $2;
				push @args, $1;
			}
			$arg =~ s/^,\s*//;
		}
	}

	for my $cmd (@$macro) {
		# Copy macro cmd and perform substitutions:
		my $new_cmd = { %{$cmd} };
		$$new_cmd{label} =~ s/\&(\d+)/$args[$1-1]/g if (exists $$new_cmd{label});
		$$new_cmd{opcode} =~ s/\&(\d+)/$args[$1-1]/g if (exists $$new_cmd{opcode});
		$$new_cmd{arg} =~ s/\&(\d+)/$args[$1-1]/g if (exists $$new_cmd{arg});
		$$new_cmd{line} =~ s/\&(\d+)/$args[$1-1]/g if (exists $$new_cmd{line});
		process_cmd($new_cmd);
	}
}

sub parse_export {
	my ($cmd) = @_;
	if (exists $$cmd{arg}) {
		my $arg = $$cmd{arg};
		$export_labels{$arg} = 1;
	} else {
		syntax_error("bad label in export");
	}
}

sub parse_equ {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	my $val = eval_expr($arg);
	return undef if (!defined $val);
	if (exists $$instr{addr} && $$instr{addr} != $val) {
		$unresolved = 1;
	}
	$$instr{addr} = $val;
	if ($$instr{opcode} eq 'org') {
		$pc = $val;
		$put = $val;
	} elsif ($$instr{opcode} eq 'put') {
		$put = $val;
	}
	if (exists $$instr{label} && $$instr{label} !~ /^\d+$/) {
		$equs{$$instr{label}} = $val;
	}
}

sub parse_setdp {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	my $val = eval_expr($arg);
	return undef if (!defined $val);
	$dp = $val & 0xff;
}

sub parse_rmb {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	$arg =~ s/\s+//g;
	my $num = eval_expr($arg);
	return undef if (!defined $num);
	$$instr{size} = $num;
}

sub parse_rzb {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	$arg =~ s/\s+//g;
	my $num = eval_expr($arg);
	return undef if (!defined $num);
	$$instr{size} = $num;
	$$instr{text} = "00" x $num;
}

sub parse_fill {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	my ($arg1,$arg2) = split(/,/, $arg, 2);
	my $size = eval_expr($arg1);
	return undef if (!defined $size);
	my $value = eval_expr($arg2);
	return undef if (!defined $value);
	$$instr{size} = $size;
	$$instr{text} = sprintf("\%02x", $value & 0xff) x $size;
}

sub parse_fcb {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	my $text = "";
	for my $i (split(/,/, $arg)) {
		my $num = eval_expr($i);
		if (defined $num) {
			$text .= sprintf("%02x", $num & 0xff);
		} else {
			$unresolved = 1;
		}
	}
	$$instr{text} = $text;
	$$instr{size} = length($text) / 2;
}

sub parse_fdb {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	my $text = "";
	for my $i (split(/,/, $arg)) {
		my $num = eval_expr($i);
		if (defined $num) {
			$text .= sprintf("%04x", $num & 0xffff);
		} else {
			$unresolved = 1;
		}
	}
	$$instr{text} = $text;
	$$instr{size} = length($text) / 2;
}

sub parse_fcc {
	my ($instr) = @_;
	my $arg = $$instr{arg};
	my $text = "";
	my $c;
	my $tmp = "";
	my $valid = 1;
	$arg =~ s/^\s+//;
	while (defined $arg && $arg ne "") {
		last if ($arg =~ /^;/);  # skip comments
		if ($arg =~ /^,/) {
			# empty expression not allowed
			syntax_error("bad expression");
			return;
		} elsif ($arg =~ /^([\/\"!])(.*?)(\1)\s*(.*)?$/) {
			# string
			$arg = $4;
			my $string = $2;
			$string =~ s/(.)/sprintf("%02x", ord($1))/ge;
			$text .= $string;
		} elsif ($arg =~ /^([^,;]*)(.*)$/) {
			# expression
			$arg = $2;
			my $val = eval_expr($1);
			if (defined $val) {
				$text .= sprintf("%02x", $val & 0xff);
			} else {
				$text .= "xx";
				$valid = 0;
			}
		}
		$arg =~ s/^,\s*//;
	}
	$$instr{size} = length($text) / 2;
	return undef unless $valid;
	$$instr{text} = $text;
}

sub parse_stack {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	my $sstack = 0;
	my $ustack = 0;
	my %regs = (
		cc => 0x01, a => 0x02, b => 0x04, d => 0x06, dp => 0x08,
		x => 0x10, y => 0x20, pc => 0x80,
	);
	$arg =~ s/\s+//g;
	for my $reg (split(/,/, $arg)) {
		if ($reg =~ /s/i) {
			$ustack |= 0x40;
		} elsif ($reg =~ /u/i) {
			$sstack |= 0x40;
		} elsif ($reg =~ /^(cc|a|b|d|dp|x|y|pc)$/i) {
			# Perl 5.14 weirdly taints if I just use $regs{$reg}...
			$ustack |= $regs{lc $1};
			$sstack |= $regs{lc $1};
		} else {
			syntax_error("bad register in stack operation");
		}
	}
	$sstack = sprintf("%02x", $sstack);
	$ustack = sprintf("%02x", $ustack);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%s/$sstack/g;
	$$instr{text} =~ s/\%u/$ustack/g;
	$$instr{size} = length($$instr{text}) / 2;
}

sub parse_pair {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	my %regs;
	if (!$isa_6309) {
		%regs = (
			d => 0, x => 1,  y => 2,   u => 3, s => 4, pc => 5,
			a => 8, b => 9, cc => 10, dp => 11,
		);
	} else {
		%regs = (
			d => 0, x => 1,  y => 2,   u => 3, s => 4, pc => 5, w => 6, v => 7,
			a => 8, b => 9, cc => 10, dp => 11, e => 14, f => 15,
		);
	}
	$arg =~ s/\s+//g;
	my $warn_numerical = 0;
	my ($src,$dest) = split(/,/, lc $arg);
	if ($src =~ /^\d+$/) {
		if ($isa_6309 && $src == 0) {
			$src = 12;
		} else {
			$warn_numerical = 1;
		}
	} elsif (exists $regs{$src}) {
		$src = $regs{$src};
	} else {
		syntax_error("bad source register");
		$src = 0;
	}
	if ($dest =~ /^\d+$/) {
		if ($isa_6309 && $dest == 0) {
			$dest = 12;
		} else {
			$warn_numerical = 1;
		}
	} elsif (exists $regs{$dest}) {
		$dest = $regs{$dest};
	} else {
		syntax_error("bad destination register");
		$dest = 0;
	}
	warning("numerical values used in inter-register op") if ($warn_numerical && !$quiet);
	# going to assume the 6309 mismatched size behaviour is "defined"
	if (!$isa_6309 && ($src & 8) != ($dest & 8)) {
		warning("register sizes don't match in inter-register op") if (!$quiet);
	}
	my $pair = sprintf("%01x%01x", $src & 15, $dest & 15);
	$$instr{size} = length($tmpl) / 2;
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%b/$pair/g;
}

sub parse_address {
	my ($instr) = @_;
	my $opcode = $$instr{opcode};
	my $arg = $$instr{arg};
	my $addr = eval_expr($arg);
	if (!defined $addr) {
		$unresolved = 1;
		if (exists $opcodes{$opcode}->{extended}) {
			$$instr{size} = length($opcodes{$opcode}->{extended}) / 2;
		} elsif (exists $opcodes{$opcode}->{direct}) {
			$$instr{size} = (length($opcodes{$opcode}->{direct}) / 2) + 1;
		} elsif (exists $opcodes{$opcode}->{indexed}) {
			$$instr{size} = (length($opcodes{$opcode}->{indexed}) / 2) + 2;
		} else {
			syntax_error("cannot determine addressing mode for '$opcode'");
		}
		return undef;
	}
	if (defined $dp
		&& $dp == (($addr >> 8) & 0xff)
		&& exists $opcodes{$opcode}->{direct}) {
		$$instr{tmpl} = $opcodes{$opcode}->{direct};
		if (exists $$instr{itext}) {
			$$instr{tmpl} =~ s/\%t/$$instr{itext}/;
		}
		return parse_direct($instr);
	} elsif (exists $opcodes{$opcode}->{extended}) {
		$$instr{tmpl} = $opcodes{$opcode}->{extended};
		if (exists $$instr{itext}) {
			$$instr{tmpl} =~ s/\%t/$$instr{itext}/;
		}
		return parse_extended($instr);
	} elsif ($opcodes{$opcode}->{indexed}) {
		$$instr{tmpl} = $opcodes{$opcode}->{indexed};
		if (exists $$instr{itext}) {
			$$instr{tmpl} =~ s/\%t/$$instr{itext}/;
		}
		return parse_indexed($instr);
	}
	syntax_error("cannot determine addressing mode for '$opcode'");
}

sub parse_immediate {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	$arg =~ s/\s+//g;
	$arg =~ s/^#//;
	my $size = length($tmpl) / 2;
	$size++ if ($tmpl =~ /\%w/);
	$size += 3 if ($tmpl =~ /\%q/);
	$$instr{size} = $size;
	my $val = eval_expr($arg);
	return undef if (!defined $val);
	my $as_byte = sprintf("%02x", $val & 0xff);
	my $as_word = sprintf("%04x", $val & 0xffff);
	my $as_quad = sprintf("%08x", $val & 0xffffffff);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%b/$as_byte/g;
	$$instr{text} =~ s/\%w/$as_word/g;
	$$instr{text} =~ s/\%q/$as_quad/g;
}

sub parse_direct {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	$arg =~ s/^<//;
	my $size = length($tmpl) / 2;
	$$instr{size} = $size;
	my $addr = eval_expr($arg);
	return undef if (!defined $addr);
	my $as_byte = sprintf("%02x", $addr & 0xff);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%b/$as_byte/g;
}

# Long and complex because 6809 indexed addressing is complex.

sub parse_indexed {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	my %aregs = ( a => 0x06, b => 0x05, d => 0x0b, e => 0x07, f => 0x0a, w => 0x0e );
	my %regs = ( x => 0x00, y => 0x20, u => 0x40, s => 0x60 );
	$arg =~ s/\s+//g;
	my $indirect = 0;
	my $want_bits = 0;
	my $text = "";
	if ($arg =~ /^\[(.*)\]$/) {
		$arg = $1;
		$indirect = 0x10;
	}
	# Allow bracketing a second time to reverse the meaning
	if ($arg =~ /^\[(.*)\]$/) {
		$arg = $1;
		$indirect = 0;
	}
	if ($arg =~ /^>>(.*)$/) {
		$want_bits = 16;
		$arg = $1;
	} elsif ($arg =~ /^>(.*)$/) {
		$want_bits = 8;
		$arg = $1;
	} elsif ($arg =~ /^<<(.*)$/) {
		$want_bits = 0;
		$arg = $1;
	} elsif ($arg =~ /^<(.*)$/) {
		$want_bits = 5;
		$arg = $1;
	}
	my $base_size = length($tmpl) / 2;  # includes postbyte
	$$instr{size} = $base_size + 2;  # maximum
	my ($offset,$reg) = split(/,/, $arg);
	if ($arg !~ /,/) {
		if (!$indirect) {
			warning("invalid extended non-indirect address") if (!$quiet);
		}
		my $addr = eval_expr($arg);
		return undef if (!defined $addr);
		$text = sprintf("\%02x\%04x", 0x8f | $indirect, $addr & 0xffff);
	} elsif ($reg eq 'pcr') {
		my $addr = eval_expr($offset);
		return undef if (!defined $addr);
		if ($want_bits < 16) {
			my $next_pc = $pc + $base_size + 1;
			my $offset = $addr - $next_pc;
			if (defined $addr && $offset >= -128 && $offset <= 127) {
				$text = sprintf("\%02x\%02x", 0x8c | $indirect, $offset & 0xff);
			} else {
				$want_bits = 16;
			}
		}
		if ($want_bits == 16) {
			my $next_pc = $pc + $base_size + 2;
			my $offset = $addr - $next_pc;
			$text = sprintf("\%02x\%04x", 0x8d | $indirect, $offset & 0xffff);
		}
	} elsif ($offset eq "") {
		$$instr{size} -= 2;
		if ($isa_6309 && $reg =~ /w\+\+/) {
			$text = sprintf("\%02x", 0xcf + ($indirect ? 1 : 0));
		} elsif ($isa_6309 && $reg =~ /--w/) {
			$text = sprintf("\%02x", 0xef + ($indirect ? 1 : 0));
		} elsif ($isa_6309 && $reg =~ /w/) {
			$text = sprintf("\%02x", 0x8f + ($indirect ? 1 : 0));
		} elsif ($reg =~ /([xyus])\+\+/i) {
			$text = sprintf("\%02x", 0x81 | $regs{lc $1} | $indirect);
		} elsif ($reg =~ /--([xyus])/i) {
			$text = sprintf("\%02x", 0x83 | $regs{lc $1} | $indirect);
		} elsif ($reg =~ /([xyus])\+/i) {
			if ($indirect && $isa_6309) {
				syntax_error("invalid indirect post-increment");
			} elsif ($indirect) {
				warning("invalid indirect post-increment") if (!$quiet);
			}
			$text = sprintf("\%02x", 0x80 | $regs{lc $1} | $indirect);
		} elsif ($reg =~ /-([xyus])/i) {
			if ($indirect && $isa_6309) {
				syntax_error("invalid indirect pre-decrement");
			} elsif ($indirect) {
				warning("invalid indirect pre-decrement") if (!$quiet);
			}
			$text = sprintf("\%02x", 0x82 | $regs{lc $1} | $indirect);
		} elsif ($reg =~ /([xyus])/i) {
			$text = sprintf("\%02x", 0x84 | $regs{lc $1} | $indirect);
		} else {
			syntax_error("unknown index register or operation");
			return undef;
		}
	} elsif ($offset =~ /^([abd])$/i || ($isa_6309 && $offset =~ /^([efw])$/i)) {
		my $areg = lc $1;
		$$instr{size} -= 2;
		if ($reg =~ /^([xyus])$/i) {
			$reg = lc $1;
		} else {
			syntax_error("unknown index register or operation");
			return undef;
		}
		$text = sprintf("\%02x", 0x80 | $regs{$reg} | $aregs{$areg} | $indirect);
	} else {
		if ($reg =~ /^([xyus])$/i) {
			$reg = lc $1;
		} elsif  ($isa_6309 && lc($reg) eq 'w') {
			$reg = 'w';
		} else {
			syntax_error("unknown index register or operation");
			return undef;
		}
		my $val = eval_expr($offset);
		return undef if (!defined $val);
		$want_bits = 16 if ($reg eq 'w');
		$want_bits = 8 if ($want_bits < 8 && $indirect);
		if ($want_bits < 8) {
			if (defined $val && $val >= -16 && $val <= 15) {
				if ($val == 0 && $want_bits == 0) {
					$text = sprintf("\%02x", 0x84 | $regs{$reg} | $indirect);
				} else {
					$val &= 0x1f;
					$text = sprintf("\%02x", $regs{$reg} | $val);
				}
			} else {
				$want_bits = 8;
			}
		}
		if ($want_bits == 8 || $want_bits == 16) {
			if (defined $val && $val >= -128 && $val <= 127) {
				$val &= 0xff;
				$text = sprintf("\%02x\%02x", 0x88 | $regs{$reg} | $indirect, $val);
			} else {
				$want_bits = 16;
			}
		}
		if ($want_bits == 16) {
			$val &= 0xffff;
			if ($reg eq 'w') {
				$text = sprintf("\%02x\%04x", 0xaf + ($indirect ? 1 : 0), $val);
			} else {
				$text = sprintf("\%02x\%04x", 0x89 | $regs{$reg} | $indirect, $val);
			}
		}
	}
	return undef if (!$text);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%i/$text/g;
	$$instr{size} = length($$instr{text}) / 2;
}

sub parse_indexed_6800 {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	$arg =~ s/\s+//g;
	my $text = "";
	$$instr{size} = length($tmpl) / 2;  # includes postbyte
	my ($offset,$reg) = split(/,/, $arg);
	my $val = 0;
	if ($offset ne '' && lc($offset) ne 'x') {
		$val = eval_expr($offset);
	}
	return undef if (!defined $val);
	$text = sprintf("\%02x", $val);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%i/$text/g;
	$$instr{size} = length($$instr{text}) / 2;
}

sub parse_extended {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	$arg =~ s/\s+//g;
	$arg =~ s/^>//;
	my $size = (length($tmpl) / 2) + 1;
	my $addr = eval_expr($arg);
	$$instr{size} = $size;
	return undef if (!defined $addr);
	my $as_word = sprintf("%04x", $addr & 0xffff);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%w/$as_word/g;
}

sub parse_inherent {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	$$instr{size} = length($tmpl) / 2;
	$$instr{text} = $tmpl;
}

sub parse_relative {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $size = length($tmpl) / 2;
	$$instr{size} = $size;
	my $arg = $$instr{arg};
	my $addr = eval_expr($arg);
	return undef if (!defined $addr);
	my $next_pc = $pc + $size;
	my $offset = $addr - $next_pc;
	if ($offset < -128 || $offset > 127) {
		error("branch destination out of range");
	}
	my $off_text = sprintf("%02x", $offset & 0xff);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%b/$off_text/g;
}

sub parse_longrelative {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $size = (length($tmpl) / 2) + 1;
	$$instr{size} = $size;
	my $arg = $$instr{arg};
	my $addr = eval_expr($arg);
	return undef if (!defined $addr);
	my $next_pc = $pc + $size;
	my $offset = $addr - $next_pc;
	if ($offset >= -128 && $offset <= 127) {
		warning("long branch could be optimised") if (!$quiet);
	}
	my $off_text = sprintf("%04x", $offset & 0xffff);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%w/$off_text/g;
}

# This does some complex manipulation of the instruction to parse the immediate
# part then combine it with the result of parsing the address part.

sub parse_imm_mem {
	my ($instr) = @_;
	my $opcode = $$instr{opcode};
	my $old_arg = $$instr{arg};
	if ($old_arg !~ /^([^,]*),(.*)$/) {
		syntax_error("cannot determine immediate part for '$opcode'");
		return undef;
	}
	my ($imm_arg,$arg) = ($1,$2);
	$$instr{arg} = $imm_arg;
	$$instr{tmpl} = $opcodes{$opcode}->{imm_mem};
	parse_immediate($instr);
	$$instr{itext} = $$instr{text};
	my $mode = instr_mode($opcode, $arg);
	# Copy appropriate template into the hash for parsing.
	if (exists $opcodes{$opcode}->{$mode}) {
		$$instr{tmpl} = $opcodes{$opcode}->{$mode};
		$$instr{tmpl} =~ s/\%t/$$instr{itext}/;
	}
	# Call appropriate parse routine, fills in text & size.
	if (exists $arg_parse{$mode}) {
		$$instr{arg} = $arg;
		$arg_parse{$mode}($instr);
	}
	delete $$instr{itext};
	$$instr{arg} = $old_arg;
}

sub parse_reg_mem {
	my ($instr) = @_;
	my $opcode = $$instr{opcode};
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	if ($arg !~ /^(.*),(.*),(.*),(.*)$/) {
		syntax_error("cannot parse arguments for '$opcode'");
		return undef;
	}
	my ($reg,$sbit,$dbit,$addr) = ($1,$2,$3,$4);
	$addr =~ s/^<//;
	my $size = length($tmpl) / 2;
	$$instr{size} = $size;
	my $postbyte = 0;
	if ((lc $reg) eq 'cc') {
		$postbyte |= 0;
	} elsif ((lc $reg) eq 'a') {
		$postbyte |= 0x40;
	} elsif ((lc $reg) eq 'b') {
		$postbyte |= 0x80;
	} else {
		syntax_error("invalid register in bit operation");
		return undef;
	}
	$sbit = eval_expr($sbit);
	return undef if (!defined $sbit);
	$dbit = eval_expr($dbit);
	return undef if (!defined $dbit);
	$addr = eval_expr($addr);
	return undef if (!defined $addr);
	$postbyte |= (($sbit & 7) << 3);
	$postbyte |= ($dbit & 7);
	my $postbyte_text = sprintf("%02x", $postbyte & 0xff);
	my $addr_text = sprintf("%02x", $addr & 0xff);
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%p/$postbyte_text/g;
	$$instr{text} =~ s/\%b/$addr_text/g;
}

sub parse_tfm {
	my ($instr) = @_;
	my $tmpl = $$instr{tmpl};
	my $arg = $$instr{arg};
	my %regs = (
		d => 0, x => 1, y => 2, u => 3, s => 4,
	);
	my %incs = (
		'++' => 0, '--' => 1, '+0' => 2, '0+' => 3
	);
	$arg =~ s/\s+//g;
	my $inc = "";
	my ($src,$dest) = split(/,/, $arg);
	if ($src =~ /(.*)([\+\-])/) {
		$src = $1;
		$inc = $2;
	} else {
		$inc = "0";
	}
	if ($dest =~ /(.*)([\+\-])/) {
		$dest = $1;
		$inc .= $2;
	} else {
		$inc .= "0";
	}
	if (!exists $incs{$inc}) {
		syntax_error("invalid post-inc/dec combination in tfm");
		return undef;
	}
	my $postbyte = 0x38 + $incs{$inc};
	if (exists $regs{$src}) {
		$src = $regs{$src};
	} else {
		syntax_error("bad source register");
		$src = 0;
	}
	if (exists $regs{$dest}) {
		$dest = $regs{$dest};
	} else {
		syntax_error("bad destination register");
		$dest = 0;
	}
	my $postbyte_text = sprintf("%02x", $postbyte & 0xff);
	my $pair = sprintf("%01x%01x", $src & 15, $dest & 15);
	$$instr{size} = length($tmpl) / 2;
	$$instr{text} = $tmpl;
	$$instr{text} =~ s/\%p/$postbyte_text/g;
	$$instr{text} =~ s/\%b/$pair/g;
}

# Old 6800 assembly files don't just have "LDAA" etc., they actually appear to
# use "LDA A <the rest>".  Weird.  This copes with that syntax:

sub parse_acc_op {
	my ($instr) = @_;
	my $old_opcode = $$instr{opcode};
	my $old_arg = $$instr{arg};
	if ($old_arg !~ /^(\S+)(\s+(.*))?$/) {
		syntax_error("cannot determine register part for '$old_opcode'");
		return undef;
	}
	my ($reg,$arg) = ($1,$3);
	my $opcode = $old_opcode . lc($reg);
	if (!exists $opcodes{$opcode}) {
		syntax_error("invalid register for '$old_opcode'");
		return undef;
	}
	$$instr{opcode} = $opcode;
	$$instr{arg} = $arg;
	my $mode = instr_mode($opcode, $arg);
	# Copy appropriate template into the hash for parsing.
	if ($mode) {
		$$instr{mode} = $mode;
		if (exists $opcodes{$opcode}->{$mode}) {
			$$instr{tmpl} = $opcodes{$opcode}->{$mode};
		}
		# Call appropriate parse routine, fills in text & size.
		if (exists $arg_parse{$mode}) {
			$arg_parse{$mode}($instr);
		}
	}
	$$instr{opcode} = $old_opcode;
	$$instr{arg} = $old_arg;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Tries to convert an expression into one eval-able by Perl.  Any undefined
# label references cause $unresolved to be set and undef returned.
sub eval_expr {
	my ($expr) = @_;
	my $evalstr = "";
	my $invalid = 0;
	$expr =~ s/^\s+//;
	my $nest = 0;
	my $expect_value = 1;

	PART: while ($expr ne "") {
		if ($expect_value) {
			if ($expr =~ /^(\(+)\s*(.*)$/) {
				$evalstr .= $1;
				$nest += length($1);
				$expr = $2;
			} elsif ($expr =~ /^([~\-])\s*(.*)$/) {
				$evalstr .= $1;
				$expr = $2;
			} elsif ($expr =~ /^(\*)\s*(.*)$/) {
				$evalstr .= $pc;
				$expr = $2;
				$expect_value = 0;
			} elsif ($expr =~ /^\$([\da-fA-F]+)\s*(.*)$/) {
				$evalstr .= hex($1);
				$expr = $2;
				$expect_value = 0;
			} elsif ($expr =~ /^\%([01]+)\s*(.*)$/) {
				$evalstr .= oct("0b$1");
				$expr = $2;
				$expect_value = 0;
			} elsif ($expr =~ /^\@([0-7]+)\s*(.*)$/) {
				$evalstr .= oct("0$1");
				$expr = $2;
				$expect_value = 0;
			} elsif ($expr =~ /^'(.)\s*(.*)$/) {
				$evalstr .= ord($1);
				$expr = $2;
				$expect_value = 0;
			} elsif ($expr =~ /^(\d+)([fb])\s*(.*)$/i) {
				my $num .= $1;
				my $dir = uc $2;
				$expr = $3;
				my $instr = undef;
				# Search backwards or forwards for local label
				if ($dir eq 'B') {
					for (my $i = $as_index; $i >= 0; $i--) {
						if  (exists $asection->[$i]->{label} && $asection->[$i]->{label} eq $num) {
							$instr = $asection->[$i];
							last;
						}
					}
				} else {
					for (my $i = $as_index + 1; $i < $#$asection; $i++) {
						if  (exists $asection->[$i]->{label} && $asection->[$i]->{label} eq $num) {
							$instr = $asection->[$i];
							last;
						}
					}
				}
				if (!defined $instr) {
					error("unknown local label '$num$dir'");
					$invalid = 1;
				} elsif (!exists $$instr{addr}) {
					$unresolved = 1;
					$evalstr .= "0";
				} else {
					$evalstr .= (0+($$instr{addr}));
				}
				$expect_value = 0;
			} elsif ($expr =~ /^(\d+(\.\d+)?)\s*(.*)$/) {
				$evalstr .= (0+$1);
				$expr = $3;
				$expect_value = 0;
			} elsif ($expr =~ /^(\w+)\s*(.*)$/) {
				$expr = $2;
				if (exists $equs{$1}) {
					$evalstr .= "(".(0+$equs{$1}).")";
				} else {
					$evalstr .= (0);
					if (!exists $label_errors{$1}) {
						error("unknown label '$1'");
						$label_errors{$1} = 1;
					}
					$invalid = 1;
				}
				$expect_value = 0;
			} else {
				syntax_error("bad expression");
				return undef;
			}
		} else {
			if ($expr =~ /^(\)+)\s*(.*)$/) {
				$evalstr .= $1;
				$nest -= length($1);
				$expr = $2;
			} elsif ($expr =~ /^([\+\-\*\/\&\|\^]|<<|>>)\s*(.*)$/) {
				$evalstr .= $1;
				$expr = $2;
				$expect_value = 1;
			} else {
				if ($nest == 0) {
					last PART;
				}
				syntax_error("bad expression");
				return undef;
			}
		}
	}
	if ($nest != 0) {
		syntax_error("bad expression");
		return undef;
	}

	return undef if ($invalid);
	my $ret = undef;
	eval "\$ret = ($evalstr);";
	return $ret;
}

############################################################################

sub syntax_error {
	my ($msg) = @_;
	push @syntax_errors, "error: $$file_ctx{filename}:$$file_ctx{lno}: $msg";
}

sub die_if_syntax_error {
	if (@syntax_errors) {
		print STDERR "$_\n" for (@syntax_errors);
		exit 1;
	}
}

sub error {
	my ($msg) = @_;
	push @errors, "error: $$file_ctx{filename}:$$file_ctx{lno}: $msg";
	$unresolved = 1;
}

sub warning {
	my ($msg) = @_;
	push @errors, "warning: $$file_ctx{filename}:$$file_ctx{lno}: $msg";
}
