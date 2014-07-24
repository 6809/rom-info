#!/usr/bin/perl

# 6809/6309 disassembler
# by Ciaran Anscomb, 2014

# Disclaimer:
# Possibly not fit for any purpose.  You're free to use, copy, modify and
# redistribute so long as I don't get the blame for anything.

my %need_labels = ();
my %labels = ();
my %def_labels = ();
my %forceorg = ();
my %comments = ();
my %comment_bytes = ();

my $isa_6309 = 0;

my $origin = 0xc000;
my $code_end;
my @sections = ();
while (scalar(@ARGV) > 0) {
	my $arg = $ARGV[0];
	if ($arg eq '--6309' || $arg eq '-3') {
		$isa_6309 = 1;
	} elsif ($arg =~ /^org=(\d+|0x[\da-f]+)$/i) {
		eval "\$origin = $1;";
	} elsif ($arg =~ /^end=(\d+|0x[\da-f]+)$/i) {
		eval "\$code_end = $1;";
	} elsif ($arg =~ /^forceorg=(\d+|0x[\da-f]+)$/i) {
		my $addr;
		eval "\$addr = $1;";
		$forceorg{$addr} = 1;
	} elsif ($arg =~ /^comment=(\d+|0x[\da-f]+),(.*)$/i) {
		my $addr;
		eval "\$addr = $1;";
		$comments{$addr} = $2;
	} elsif ($arg =~ /^commentbyte=(\d+|0x[\da-f]+)$/i) {
		my $addr;
		eval "\$addr = $1;";
		$comment_bytes{$addr} = 1;
	} elsif ($arg =~ /^label=(\d+|0x[\da-f]+),(\w+)$/i) {
		my ($label, $addr);
		eval "\$label = $2; \$addr = $1;";
		$labels{$addr} = $label;
		$def_labels{$addr} = $label;
		$need_labels{$addr} = 1;
	} elsif ($arg =~ /^fdb=(\d+|0x[\da-f]+),(\d+|0x[\da-f]+)$/i) {
		my ($start, $end);
		eval "\$start = $1; \$end = $2;";
		push @sections, [ $start, $end, 'FDB' ];
	} elsif ($arg =~ /^fcb=(\d+|0x[\da-f]+),(\d+|0x[\da-f]+)$/i) {
		my ($start, $end);
		eval "\$start = $1; \$end = $2;";
		push @sections, [ $start, $end, 'FCB' ];
	} elsif ($arg =~ /^fcc=(\d+|0x[\da-f]+),(\d+|0x[\da-f]+)$/i) {
		my ($start, $end);
		eval "\$start = $1; \$end = $2;";
		push @sections, [ $start, $end, 'FCC' ];
	} else {
		last;
	}
	shift @ARGV;
}

die unless (scalar(@ARGV) > 0);
my $file;
open($file, "<", $ARGV[0]) or die "$ARGV[0]: $!\n";

@sections = sort { $$a[0] <=> $$b[0] } @sections;
my $section_num = 0;
my $section = $sections[$section_num];  # undef is fine here

my %instructions_6309 = (
	0 => {

		0x01 => { text => 'OIM',     type => 'IMM_DIRECT' },
		0x02 => { text => 'AIM',     type => 'IMM_DIRECT' },
		0x05 => { text => 'EIM',     type => 'IMM_DIRECT' },
		0x0b => { text => 'TIM',     type => 'IMM_DIRECT' },

		0x14 => { text => 'SEXW',    type => 'INHERENT' },

		0x61 => { text => 'OIM',     type => 'IMM_INDEXED' },
		0x62 => { text => 'AIM',     type => 'IMM_INDEXED' },
		0x65 => { text => 'EIM',     type => 'IMM_INDEXED' },
		0x6b => { text => 'TIM',     type => 'IMM_INDEXED' },

		0x71 => { text => 'OIM',     type => 'IMM_EXTENDED' },
		0x72 => { text => 'AIM',     type => 'IMM_EXTENDED' },
		0x75 => { text => 'EIM',     type => 'IMM_EXTENDED' },
		0x7b => { text => 'TIM',     type => 'IMM_EXTENDED' },

		0xcd => { text => 'LDQ',     type => 'IMMEDIATE32' },

	},
	2 => {

		0x30 => { text => 'ADDR',    type => 'REGISTER' },
		0x31 => { text => 'ADCR',    type => 'REGISTER' },
		0x32 => { text => 'SUBR',    type => 'REGISTER' },
		0x33 => { text => 'SBCR',    type => 'REGISTER' },
		0x34 => { text => 'ANDR',    type => 'REGISTER' },
		0x35 => { text => 'ORR',     type => 'REGISTER' },
		0x36 => { text => 'EORR',    type => 'REGISTER' },
		0x37 => { text => 'CMPR',    type => 'REGISTER' },

		0x40 => { text => 'NEGD',    type => 'INHERENT' },
		0x43 => { text => 'COMD',    type => 'INHERENT' },
		0x44 => { text => 'LSRD',    type => 'INHERENT' },
		0x46 => { text => 'RORD',    type => 'INHERENT' },
		0x47 => { text => 'ASRD',    type => 'INHERENT' },
		0x48 => { text => 'LSLD',    type => 'INHERENT' },
		0x49 => { text => 'ROLD',    type => 'INHERENT' },
		0x4a => { text => 'DECD',    type => 'INHERENT' },
		0x4c => { text => 'INCD',    type => 'INHERENT' },
		0x4d => { text => 'TSTD',    type => 'INHERENT' },
		0x4f => { text => 'CLRD',    type => 'INHERENT' },

		0x80 => { text => 'SUBW',    type => 'IMMEDIATE16' },
		0x81 => { text => 'CMPW',    type => 'IMMEDIATE16' },
		0x82 => { text => 'SBCD',    type => 'IMMEDIATE16' },
		0x84 => { text => 'ANDD',    type => 'IMMEDIATE16' },
		0x85 => { text => 'BITD',    type => 'IMMEDIATE16' },
		0x86 => { text => 'LDW',     type => 'IMMEDIATE16' },
		0x88 => { text => 'EORD',    type => 'IMMEDIATE16' },
		0x89 => { text => 'ADCD',    type => 'IMMEDIATE16' },
		0x8a => { text => 'ORD',     type => 'IMMEDIATE16' },
		0x8b => { text => 'ADDW',    type => 'IMMEDIATE16' },

		0x90 => { text => 'SUBW',    type => 'DIRECT' },
		0x91 => { text => 'CMPW',    type => 'DIRECT' },
		0x92 => { text => 'SBCD',    type => 'DIRECT' },
		0x94 => { text => 'ANDD',    type => 'DIRECT' },
		0x95 => { text => 'BITD',    type => 'DIRECT' },
		0x96 => { text => 'LDW',     type => 'DIRECT' },
		0x98 => { text => 'EORD',    type => 'DIRECT' },
		0x99 => { text => 'ADCD',    type => 'DIRECT' },
		0x9a => { text => 'ORD',     type => 'DIRECT' },
		0x9b => { text => 'ADDW',    type => 'DIRECT' },

		0xa0 => { text => 'SUBW',    type => 'INDEXED' },
		0xa1 => { text => 'CMPW',    type => 'INDEXED' },
		0xa2 => { text => 'SBCD',    type => 'INDEXED' },
		0xa4 => { text => 'ANDD',    type => 'INDEXED' },
		0xa5 => { text => 'BITD',    type => 'INDEXED' },
		0xa6 => { text => 'LDW',     type => 'INDEXED' },
		0xa8 => { text => 'EORD',    type => 'INDEXED' },
		0xa9 => { text => 'ADCD',    type => 'INDEXED' },
		0xaa => { text => 'ORD',     type => 'INDEXED' },
		0xab => { text => 'ADDW',    type => 'INDEXED' },

		0xb0 => { text => 'SUBW',    type => 'EXTENDED' },
		0xb1 => { text => 'CMPW',    type => 'EXTENDED' },
		0xb2 => { text => 'SBCD',    type => 'EXTENDED' },
		0xb4 => { text => 'ANDD',    type => 'EXTENDED' },
		0xb5 => { text => 'BITD',    type => 'EXTENDED' },
		0xb6 => { text => 'LDW',     type => 'EXTENDED' },
		0xb8 => { text => 'EORD',    type => 'EXTENDED' },
		0xb9 => { text => 'ADCD',    type => 'EXTENDED' },
		0xba => { text => 'ORD',     type => 'EXTENDED' },
		0xbb => { text => 'ADDW',    type => 'EXTENDED' },

		0xdc => { text => 'LDQ',     type => 'DIRECT' },
		0xdd => { text => 'STQ',     type => 'DIRECT' },

		0xec => { text => 'LDQ',     type => 'INDEXED' },
		0xed => { text => 'STQ',     type => 'INDEXED' },

		0xfc => { text => 'LDQ',     type => 'EXTENDED' },
		0xfd => { text => 'STQ',     type => 'EXTENDED' },

	},
	3 => {

		0x30 => { text => 'BAND',    type => 'BIT_DIRECT' },
		0x31 => { text => 'BIAND',   type => 'BIT_DIRECT' },
		0x32 => { text => 'BOR',     type => 'BIT_DIRECT' },
		0x33 => { text => 'BIOR',    type => 'BIT_DIRECT' },
		0x34 => { text => 'BEOR',    type => 'BIT_DIRECT' },
		0x35 => { text => 'BIEOR',   type => 'BIT_DIRECT' },
		0x36 => { text => 'LDBT',    type => 'BIT_DIRECT' },
		0x37 => { text => 'STBT',    type => 'BIT_DIRECT' },
		0x38 => { text => 'TFM',     type => 'TFM' },
		0x39 => { text => 'TFM',     type => 'TFM' },
		0x3a => { text => 'TFM',     type => 'TFM' },
		0x3b => { text => 'TFM',     type => 'TFM' },
		0x3c => { text => 'BITMD',   type => 'IMMEDIATE' },
		0x3d => { text => 'LDMD',    type => 'IMMEDIATE' },

		0x43 => { text => 'COME',    type => 'INHERENT' },
		0x4a => { text => 'DECE',    type => 'INHERENT' },
		0x4c => { text => 'INCE',    type => 'INHERENT' },
		0x4d => { text => 'TSTE',    type => 'INHERENT' },
		0x4f => { text => 'CLRE',    type => 'INHERENT' },

		0x53 => { text => 'COMF',    type => 'INHERENT' },
		0x5a => { text => 'DECF',    type => 'INHERENT' },
		0x5c => { text => 'INCF',    type => 'INHERENT' },
		0x5d => { text => 'TSTF',    type => 'INHERENT' },
		0x5f => { text => 'CLRF',    type => 'INHERENT' },

		0x80 => { text => 'SUBE',    type => 'IMMEDIATE' },
		0x81 => { text => 'CMPE',    type => 'IMMEDIATE' },
		0x86 => { text => 'LDE',     type => 'IMMEDIATE' },
		0x8b => { text => 'ADDE',    type => 'IMMEDIATE' },
		0x8d => { text => 'DIVD',    type => 'IMMEDIATE' },
		0x8e => { text => 'DIVQ',    type => 'IMMEDIATE16' },
		0x8f => { text => 'MULD',    type => 'IMMEDIATE16' },

		0x90 => { text => 'SUBE',    type => 'DIRECT' },
		0x91 => { text => 'CMPE',    type => 'DIRECT' },
		0x96 => { text => 'LDE',     type => 'DIRECT' },
		0x97 => { text => 'STE',     type => 'DIRECT' },
		0x9b => { text => 'ADDE',    type => 'DIRECT' },
		0x9d => { text => 'DIVD',    type => 'DIRECT' },
		0x9e => { text => 'DIVQ',    type => 'DIRECT' },
		0x9f => { text => 'MULD',    type => 'DIRECT' },

		0xa0 => { text => 'SUBE',    type => 'INDEXED' },
		0xa1 => { text => 'CMPE',    type => 'INDEXED' },
		0xa6 => { text => 'LDE',     type => 'INDEXED' },
		0xa7 => { text => 'STE',     type => 'INDEXED' },
		0xab => { text => 'ADDE',    type => 'INDEXED' },
		0xad => { text => 'DIVD',    type => 'INDEXED' },
		0xae => { text => 'DIVQ',    type => 'INDEXED' },
		0xaf => { text => 'MULD',    type => 'INDEXED' },

		0xb0 => { text => 'SUBE',    type => 'EXTENDED' },
		0xb1 => { text => 'CMPE',    type => 'EXTENDED' },
		0xb6 => { text => 'LDE',     type => 'EXTENDED' },
		0xb7 => { text => 'STE',     type => 'EXTENDED' },
		0xbb => { text => 'ADDE',    type => 'EXTENDED' },
		0xbd => { text => 'DIVD',    type => 'EXTENDED' },
		0xbe => { text => 'DIVQ',    type => 'EXTENDED' },
		0xbf => { text => 'MULD',    type => 'EXTENDED' },

		0xc0 => { text => 'SUBF',    type => 'IMMEDIATE' },
		0xc1 => { text => 'CMPF',    type => 'IMMEDIATE' },
		0xc6 => { text => 'LDF',     type => 'IMMEDIATE' },
		0xcb => { text => 'ADDF',    type => 'IMMEDIATE' },

		0xd0 => { text => 'SUBF',    type => 'DIRECT' },
		0xd1 => { text => 'CMPF',    type => 'DIRECT' },
		0xd6 => { text => 'LDF',     type => 'DIRECT' },
		0xd7 => { text => 'STF',     type => 'DIRECT' },
		0xdb => { text => 'ADDF',    type => 'DIRECT' },

		0xe0 => { text => 'SUBF',    type => 'INDEXED' },
		0xe1 => { text => 'CMPF',    type => 'INDEXED' },
		0xe6 => { text => 'LDF',     type => 'INDEXED' },
		0xe7 => { text => 'STF',     type => 'INDEXED' },
		0xeb => { text => 'ADDF',    type => 'INDEXED' },

		0xf0 => { text => 'SUBF',    type => 'EXTENDED' },
		0xf1 => { text => 'CMPF',    type => 'EXTENDED' },
		0xf6 => { text => 'LDF',     type => 'EXTENDED' },
		0xf7 => { text => 'STF',     type => 'EXTENDED' },
		0xfb => { text => 'ADDF',    type => 'EXTENDED' },

	},
);

my %instructions_illegal = (
	0 => {
		0x01 => { text => 'NEG',     type => 'DIRECT' },
		0x02 => { text => 'NEGCOM',  type => 'DIRECT' },
		0x05 => { text => 'LSR',     type => 'DIRECT' },
		0x0b => { text => 'DEC',     type => 'DIRECT' },
		0x14 => { text => 'HCF',     type => 'INHERENT' },
		0x15 => { text => 'HCF',     type => 'INHERENT' },
		0x18 => { text => 'LSLCC',   type => 'INHERENT' },
		0x1b => { text => 'NOP',     type => 'INHERENT' },
		0x38 => { text => 'ANDCC',   type => 'IMMEDIATE' },
		0x3e => { text => 'RESET',   type => 'INHERENT' },
		0x41 => { text => 'NEGA',    type => 'INHERENT' },
		0x42 => { text => 'NEGCOMA', type => 'INHERENT' },
		0x45 => { text => 'LSRA',    type => 'INHERENT' },
		0x4b => { text => 'DECA',    type => 'INHERENT' },
		0x51 => { text => 'NEGB',    type => 'INHERENT' },
		0x52 => { text => 'NEGCOMB', type => 'INHERENT' },
		0x55 => { text => 'LSRB',    type => 'INHERENT' },
		0x5b => { text => 'DECB',    type => 'INHERENT' },
		0x61 => { text => 'NEG',     type => 'INDEXED' },
		0x62 => { text => 'NEGCOM',  type => 'INDEXED' },
		0x65 => { text => 'LSR',     type => 'INDEXED' },
		0x6b => { text => 'DEC',     type => 'INDEXED' },
		0x71 => { text => 'NEG',     type => 'EXTENDED' },
		0x72 => { text => 'NEGCOM',  type => 'EXTENDED' },
		0x75 => { text => 'LSR',     type => 'EXTENDED' },
		0x7b => { text => 'DEC',     type => 'EXTENDED' },
		0x87 => { text => 'DISCARDA', type => 'IMMEDIATE' },
		0x8f => { text => 'STXI',    type => 'IMMEDIATE16' },
		0xc7 => { text => 'DISCARDB', type => 'IMMEDIATE' },
		0xcd => { text => 'HCF',     type => 'INHERENT' },
		0xcf => { text => 'STUI',    type => 'IMMEDIATE16' },
	},
	2 => {
		0x20 => { text => 'LBRA',    type => 'RELATIVE16' },
	},
);

my %instructions = (
	0 => {
		0x00 => { text => 'NEG',     type => 'DIRECT' },
		0x03 => { text => 'COM',     type => 'DIRECT' },
		0x04 => { text => 'LSR',     type => 'DIRECT' },
		0x06 => { text => 'ROR',     type => 'DIRECT' },
		0x07 => { text => 'ASR',     type => 'DIRECT' },
		0x08 => { text => 'LSL',     type => 'DIRECT' },
		0x09 => { text => 'ROL',     type => 'DIRECT' },
		0x0a => { text => 'DEC',     type => 'DIRECT' },
		0x0c => { text => 'INC',     type => 'DIRECT' },
		0x0d => { text => 'TST',     type => 'DIRECT' },
		0x0e => { text => 'JMP',     type => 'DIRECT' },
		0x0f => { text => 'CLR',     type => 'DIRECT' },
		0x10 => { page => 2 },
		0x11 => { page => 3 },
		0x12 => { text => 'NOP',     type => 'INHERENT' },
		0x13 => { text => 'SYNC',    type => 'INHERENT' },
		0x16 => { text => 'LBRA',    type => 'RELATIVE16' },
		0x17 => { text => 'LBSR',    type => 'RELATIVE16' },
		0x19 => { text => 'DAA',     type => 'INHERENT' },
		0x1a => { text => 'ORCC',    type => 'IMMEDIATE' },
		0x1c => { text => 'ANDCC',   type => 'IMMEDIATE' },
		0x1d => { text => 'SEX',     type => 'INHERENT' },
		0x1e => { text => 'EXG',     type => 'REGISTER' },
		0x1f => { text => 'TFR',     type => 'REGISTER' },
		0x20 => { text => 'BRA',     type => 'RELATIVE' },
		0x21 => { text => 'BRN',     type => 'RELATIVE' },
		0x22 => { text => 'BHI',     type => 'RELATIVE' },
		0x23 => { text => 'BLS',     type => 'RELATIVE' },
		0x24 => { text => 'BCC',     type => 'RELATIVE' },
		0x25 => { text => 'BCS',     type => 'RELATIVE' },
		0x26 => { text => 'BNE',     type => 'RELATIVE' },
		0x27 => { text => 'BEQ',     type => 'RELATIVE' },
		0x28 => { text => 'BVC',     type => 'RELATIVE' },
		0x29 => { text => 'BVS',     type => 'RELATIVE' },
		0x2a => { text => 'BPL',     type => 'RELATIVE' },
		0x2b => { text => 'BMI',     type => 'RELATIVE' },
		0x2c => { text => 'BGE',     type => 'RELATIVE' },
		0x2d => { text => 'BLT',     type => 'RELATIVE' },
		0x2e => { text => 'BGT',     type => 'RELATIVE' },
		0x2f => { text => 'BLE',     type => 'RELATIVE' },
		0x30 => { text => 'LEAX',    type => 'INDEXED' },
		0x31 => { text => 'LEAY',    type => 'INDEXED' },
		0x32 => { text => 'LEAS',    type => 'INDEXED' },
		0x33 => { text => 'LEAU',    type => 'INDEXED' },
		0x34 => { text => 'PSHS',    type => 'STACK', bit6 => 'u' },
		0x35 => { text => 'PULS',    type => 'STACK', bit6 => 'u' },
		0x36 => { text => 'PSHU',    type => 'STACK', bit6 => 's' },
		0x37 => { text => 'PULU',    type => 'STACK', bit6 => 's' },
		0x39 => { text => 'RTS',     type => 'INHERENT' },
		0x3a => { text => 'ABX',     type => 'INHERENT' },
		0x3b => { text => 'RTI',     type => 'INHERENT' },
		0x3c => { text => 'CWAI',    type => 'IMMEDIATE' },
		0x3d => { text => 'MUL',     type => 'INHERENT' },
		0x3f => { text => 'SWI',     type => 'INHERENT' },
		0x40 => { text => 'NEGA',    type => 'INHERENT' },
		0x43 => { text => 'COMA',    type => 'INHERENT' },
		0x44 => { text => 'LSRA',    type => 'INHERENT' },
		0x46 => { text => 'RORA',    type => 'INHERENT' },
		0x47 => { text => 'ASRA',    type => 'INHERENT' },
		0x48 => { text => 'LSLA',    type => 'INHERENT' },
		0x49 => { text => 'ROLA',    type => 'INHERENT' },
		0x4a => { text => 'DECA',    type => 'INHERENT' },
		0x4c => { text => 'INCA',    type => 'INHERENT' },
		0x4d => { text => 'TSTA',    type => 'INHERENT' },
		0x4f => { text => 'CLRA',    type => 'INHERENT' },
		0x50 => { text => 'NEGB',    type => 'INHERENT' },
		0x53 => { text => 'COMB',    type => 'INHERENT' },
		0x54 => { text => 'LSRB',    type => 'INHERENT' },
		0x56 => { text => 'RORB',    type => 'INHERENT' },
		0x57 => { text => 'ASRB',    type => 'INHERENT' },
		0x58 => { text => 'LSLB',    type => 'INHERENT' },
		0x59 => { text => 'ROLB',    type => 'INHERENT' },
		0x5a => { text => 'DECB',    type => 'INHERENT' },
		0x5c => { text => 'INCB',    type => 'INHERENT' },
		0x5d => { text => 'TSTB',    type => 'INHERENT' },
		0x5f => { text => 'CLRB',    type => 'INHERENT' },
		0x60 => { text => 'NEG',     type => 'INDEXED' },
		0x63 => { text => 'COM',     type => 'INDEXED' },
		0x64 => { text => 'LSR',     type => 'INDEXED' },
		0x66 => { text => 'ROR',     type => 'INDEXED' },
		0x67 => { text => 'ASR',     type => 'INDEXED' },
		0x68 => { text => 'LSL',     type => 'INDEXED' },
		0x69 => { text => 'ROL',     type => 'INDEXED' },
		0x6a => { text => 'DEC',     type => 'INDEXED' },
		0x6c => { text => 'INC',     type => 'INDEXED' },
		0x6d => { text => 'TST',     type => 'INDEXED' },
		0x6e => { text => 'JMP',     type => 'INDEXED' },
		0x6f => { text => 'CLR',     type => 'INDEXED' },
		0x70 => { text => 'NEG',     type => 'EXTENDED' },
		0x73 => { text => 'COM',     type => 'EXTENDED' },
		0x74 => { text => 'LSR',     type => 'EXTENDED' },
		0x76 => { text => 'ROR',     type => 'EXTENDED' },
		0x77 => { text => 'ASR',     type => 'EXTENDED' },
		0x78 => { text => 'LSL',     type => 'EXTENDED' },
		0x79 => { text => 'ROL',     type => 'EXTENDED' },
		0x7a => { text => 'DEC',     type => 'EXTENDED' },
		0x7c => { text => 'INC',     type => 'EXTENDED' },
		0x7d => { text => 'TST',     type => 'EXTENDED' },
		0x7e => { text => 'JMP',     type => 'EXTENDED' },
		0x7f => { text => 'CLR',     type => 'EXTENDED' },
		0x80 => { text => 'SUBA',    type => 'IMMEDIATE' },
		0x81 => { text => 'CMPA',    type => 'IMMEDIATE' },
		0x82 => { text => 'SBCA',    type => 'IMMEDIATE' },
		0x83 => { text => 'SUBD',    type => 'IMMEDIATE16' },
		0x84 => { text => 'ANDA',    type => 'IMMEDIATE' },
		0x85 => { text => 'BITA',    type => 'IMMEDIATE' },
		0x86 => { text => 'LDA',     type => 'IMMEDIATE' },
		0x88 => { text => 'EORA',    type => 'IMMEDIATE' },
		0x89 => { text => 'ADCA',    type => 'IMMEDIATE' },
		0x8a => { text => 'ORA',     type => 'IMMEDIATE' },
		0x8b => { text => 'ADDA',    type => 'IMMEDIATE' },
		0x8c => { text => 'CMPX',    type => 'IMMEDIATE16' },
		0x8d => { text => 'BSR',     type => 'RELATIVE' },
		0x8e => { text => 'LDX',     type => 'IMMEDIATE16' },
		0x90 => { text => 'SUBA',    type => 'DIRECT' },
		0x91 => { text => 'CMPA',    type => 'DIRECT' },
		0x92 => { text => 'SBCA',    type => 'DIRECT' },
		0x93 => { text => 'SUBD',    type => 'DIRECT' },
		0x94 => { text => 'ANDA',    type => 'DIRECT' },
		0x95 => { text => 'BITA',    type => 'DIRECT' },
		0x96 => { text => 'LDA',     type => 'DIRECT' },
		0x97 => { text => 'STA',     type => 'DIRECT' },
		0x98 => { text => 'EORA',    type => 'DIRECT' },
		0x99 => { text => 'ADCA',    type => 'DIRECT' },
		0x9a => { text => 'ORA',     type => 'DIRECT' },
		0x9b => { text => 'ADDA',    type => 'DIRECT' },
		0x9c => { text => 'CMPX',    type => 'DIRECT' },
		0x9d => { text => 'JSR',     type => 'DIRECT' },
		0x9e => { text => 'LDX',     type => 'DIRECT' },
		0x9f => { text => 'STX',     type => 'DIRECT' },
		0xa0 => { text => 'SUBA',    type => 'INDEXED' },
		0xa1 => { text => 'CMPA',    type => 'INDEXED' },
		0xa2 => { text => 'SBCA',    type => 'INDEXED' },
		0xa3 => { text => 'SUBD',    type => 'INDEXED' },
		0xa4 => { text => 'ANDA',    type => 'INDEXED' },
		0xa5 => { text => 'BITA',    type => 'INDEXED' },
		0xa6 => { text => 'LDA',     type => 'INDEXED' },
		0xa7 => { text => 'STA',     type => 'INDEXED' },
		0xa8 => { text => 'EORA',    type => 'INDEXED' },
		0xa9 => { text => 'ADCA',    type => 'INDEXED' },
		0xaa => { text => 'ORA',     type => 'INDEXED' },
		0xab => { text => 'ADDA',    type => 'INDEXED' },
		0xac => { text => 'CMPX',    type => 'INDEXED' },
		0xad => { text => 'JSR',     type => 'INDEXED' },
		0xae => { text => 'LDX',     type => 'INDEXED' },
		0xaf => { text => 'STX',     type => 'INDEXED' },
		0xb0 => { text => 'SUBA',    type => 'EXTENDED' },
		0xb1 => { text => 'CMPA',    type => 'EXTENDED' },
		0xb2 => { text => 'SBCA',    type => 'EXTENDED' },
		0xb3 => { text => 'SUBD',    type => 'EXTENDED' },
		0xb4 => { text => 'ANDA',    type => 'EXTENDED' },
		0xb5 => { text => 'BITA',    type => 'EXTENDED' },
		0xb6 => { text => 'LDA',     type => 'EXTENDED' },
		0xb7 => { text => 'STA',     type => 'EXTENDED' },
		0xb8 => { text => 'EORA',    type => 'EXTENDED' },
		0xb9 => { text => 'ADCA',    type => 'EXTENDED' },
		0xba => { text => 'ORA',     type => 'EXTENDED' },
		0xbb => { text => 'ADDA',    type => 'EXTENDED' },
		0xbc => { text => 'CMPX',    type => 'EXTENDED' },
		0xbd => { text => 'JSR',     type => 'EXTENDED' },
		0xbe => { text => 'LDX',     type => 'EXTENDED' },
		0xbf => { text => 'STX',     type => 'EXTENDED' },
		0xc0 => { text => 'SUBB',    type => 'IMMEDIATE' },
		0xc1 => { text => 'CMPB',    type => 'IMMEDIATE' },
		0xc2 => { text => 'SBCB',    type => 'IMMEDIATE' },
		0xc3 => { text => 'ADDD',    type => 'IMMEDIATE16' },
		0xc4 => { text => 'ANDB',    type => 'IMMEDIATE' },
		0xc5 => { text => 'BITB',    type => 'IMMEDIATE' },
		0xc6 => { text => 'LDB',     type => 'IMMEDIATE' },
		0xc8 => { text => 'EORB',    type => 'IMMEDIATE' },
		0xc9 => { text => 'ADCB',    type => 'IMMEDIATE' },
		0xca => { text => 'ORB',     type => 'IMMEDIATE' },
		0xcb => { text => 'ADDB',    type => 'IMMEDIATE' },
		0xcc => { text => 'LDD',     type => 'IMMEDIATE16' },
		0xce => { text => 'LDU',     type => 'IMMEDIATE16' },
		0xd0 => { text => 'SUBB',    type => 'DIRECT' },
		0xd1 => { text => 'CMPB',    type => 'DIRECT' },
		0xd2 => { text => 'SBCB',    type => 'DIRECT' },
		0xd3 => { text => 'ADDD',    type => 'DIRECT' },
		0xd4 => { text => 'ANDB',    type => 'DIRECT' },
		0xd5 => { text => 'BITB',    type => 'DIRECT' },
		0xd6 => { text => 'LDB',     type => 'DIRECT' },
		0xd7 => { text => 'STB',     type => 'DIRECT' },
		0xd8 => { text => 'EORB',    type => 'DIRECT' },
		0xd9 => { text => 'ADCB',    type => 'DIRECT' },
		0xda => { text => 'ORB',     type => 'DIRECT' },
		0xdb => { text => 'ADDB',    type => 'DIRECT' },
		0xdc => { text => 'LDD',     type => 'DIRECT' },
		0xdd => { text => 'STD',     type => 'DIRECT' },
		0xde => { text => 'LDU',     type => 'DIRECT' },
		0xdf => { text => 'STU',     type => 'DIRECT' },
		0xe0 => { text => 'SUBB',    type => 'INDEXED' },
		0xe1 => { text => 'CMPB',    type => 'INDEXED' },
		0xe2 => { text => 'SBCB',    type => 'INDEXED' },
		0xe3 => { text => 'ADDD',    type => 'INDEXED' },
		0xe4 => { text => 'ANDB',    type => 'INDEXED' },
		0xe5 => { text => 'BITB',    type => 'INDEXED' },
		0xe6 => { text => 'LDB',     type => 'INDEXED' },
		0xe7 => { text => 'STB',     type => 'INDEXED' },
		0xe8 => { text => 'EORB',    type => 'INDEXED' },
		0xe9 => { text => 'ADCB',    type => 'INDEXED' },
		0xea => { text => 'ORB',     type => 'INDEXED' },
		0xeb => { text => 'ADDB',    type => 'INDEXED' },
		0xec => { text => 'LDD',     type => 'INDEXED' },
		0xed => { text => 'STD',     type => 'INDEXED' },
		0xee => { text => 'LDU',     type => 'INDEXED' },
		0xef => { text => 'STU',     type => 'INDEXED' },
		0xf0 => { text => 'SUBB',    type => 'EXTENDED' },
		0xf1 => { text => 'CMPB',    type => 'EXTENDED' },
		0xf2 => { text => 'SBCB',    type => 'EXTENDED' },
		0xf3 => { text => 'ADDD',    type => 'EXTENDED' },
		0xf4 => { text => 'ANDB',    type => 'EXTENDED' },
		0xf5 => { text => 'BITB',    type => 'EXTENDED' },
		0xf6 => { text => 'LDB',     type => 'EXTENDED' },
		0xf7 => { text => 'STB',     type => 'EXTENDED' },
		0xf8 => { text => 'EORB',    type => 'EXTENDED' },
		0xf9 => { text => 'ADCB',    type => 'EXTENDED' },
		0xfa => { text => 'ORB',     type => 'EXTENDED' },
		0xfb => { text => 'ADDB',    type => 'EXTENDED' },
		0xfc => { text => 'LDD',     type => 'EXTENDED' },
		0xfd => { text => 'STD',     type => 'EXTENDED' },
		0xfe => { text => 'LDU',     type => 'EXTENDED' },
		0xff => { text => 'STU',     type => 'EXTENDED' },
	},
	2 => {
		0x21 => { text => 'LBRN',    type => 'RELATIVE16' },
		0x22 => { text => 'LBHI',    type => 'RELATIVE16' },
		0x23 => { text => 'LBLS',    type => 'RELATIVE16' },
		0x24 => { text => 'LBCC',    type => 'RELATIVE16' },
		0x25 => { text => 'LBCS',    type => 'RELATIVE16' },
		0x26 => { text => 'LBNE',    type => 'RELATIVE16' },
		0x27 => { text => 'LBEQ',    type => 'RELATIVE16' },
		0x28 => { text => 'LBVC',    type => 'RELATIVE16' },
		0x29 => { text => 'LBVS',    type => 'RELATIVE16' },
		0x2a => { text => 'LBPL',    type => 'RELATIVE16' },
		0x2b => { text => 'LBMI',    type => 'RELATIVE16' },
		0x2c => { text => 'LBGE',    type => 'RELATIVE16' },
		0x2d => { text => 'LBLT',    type => 'RELATIVE16' },
		0x2e => { text => 'LBGT',    type => 'RELATIVE16' },
		0x2f => { text => 'LBLE',    type => 'RELATIVE16' },
		0x3f => { text => 'SWI2',    type => 'INHERENT' },
		0x83 => { text => 'CMPD',    type => 'IMMEDIATE16' },
		0x8c => { text => 'CMPY',    type => 'IMMEDIATE16' },
		0x8e => { text => 'LDY',     type => 'IMMEDIATE16' },
		0x93 => { text => 'CMPD',    type => 'DIRECT' },
		0x9c => { text => 'CMPY',    type => 'DIRECT' },
		0x9e => { text => 'LDY',     type => 'DIRECT' },
		0x9f => { text => 'STY',     type => 'DIRECT' },
		0xa3 => { text => 'CMPD',    type => 'INDEXED' },
		0xac => { text => 'CMPY',    type => 'INDEXED' },
		0xae => { text => 'LDY',     type => 'INDEXED' },
		0xaf => { text => 'STY',     type => 'INDEXED' },
		0xb3 => { text => 'CMPD',    type => 'EXTENDED' },
		0xbc => { text => 'CMPY',    type => 'EXTENDED' },
		0xbe => { text => 'LDY',     type => 'EXTENDED' },
		0xbf => { text => 'STY',     type => 'EXTENDED' },
		0xce => { text => 'LDS',     type => 'IMMEDIATE16' },
		0xde => { text => 'LDS',     type => 'DIRECT' },
		0xdf => { text => 'STS',     type => 'DIRECT' },
		0xee => { text => 'LDS',     type => 'INDEXED' },
		0xef => { text => 'STS',     type => 'INDEXED' },
		0xfe => { text => 'LDS',     type => 'EXTENDED' },
		0xff => { text => 'STS',     type => 'EXTENDED' },
	},
	3 => {
		0x3f => { text => 'SWI3',    type => 'INHERENT' },
		0x83 => { text => 'CMPU',    type => 'IMMEDIATE16' },
		0x8c => { text => 'CMPS',    type => 'IMMEDIATE16' },
		0x93 => { text => 'CMPU',    type => 'DIRECT' },
		0x9c => { text => 'CMPS',    type => 'DIRECT' },
		0xa3 => { text => 'CMPU',    type => 'INDEXED' },
		0xac => { text => 'CMPS',    type => 'INDEXED' },
		0xb3 => { text => 'CMPU',    type => 'EXTENDED' },
		0xbc => { text => 'CMPS',    type => 'EXTENDED' },
	},
);

# Further populate either from the list of 6809 illegal instructions or the
# list of 6309 instructions.
{
	my $extra;
	if ($isa_6309) {
		$extra = \%instructions_6309;
	} else {
		$extra = \%instructions_illegal;
	}
	for my $p (keys %{$extra}) {
		my $page = $extra->{$p};
		for my $i (keys %{$page}) {
			$instructions{$p}{$i} = $page->{$i};
			if (!$isa_6309) {
				$instructions{$p}{$i}->{'illegal'} = 1;
			}
		}
	}
}

my %tfr_regs = (
	0x0 => "d",
	0x1 => "x",
	0x2 => "y",
	0x3 => "u",
	0x4 => "s",
	0x5 => "pc",
	0x8 => "a",
	0x9 => "b",
	0xa => "cc",
	0xb => "dp",
);

if ($isa_6309) {
	$tfr_regs{0x6} = 'w';
	$tfr_regs{0x7} = 'v';
	$tfr_regs{0xc} = '0';
	$tfr_regs{0xd} = '0';
	$tfr_regs{0xe} = 'e';
	$tfr_regs{0xf} = 'f';
}

my %bit_regs = (
	0x0 => 'cc',
	0x1 => 'a',
	0x2 => 'b',
	0x3 => '*',
);

my %index_regs = (
	0 => "x",
	1 => "y",
	2 => "u",
	3 => "s",
);

my %illegal_indexed = (
	0x07 => 1, 0x0a => 1, 0x0e => 1, 0x0f => 1,
	0x10 => 1, 0x12 => 1, 0x17 => 1, 0x1a => 1, 0x1e => 1,
);

if ($isa_6309) {
	%illegal_indexed = ( 0x12 => 1 );
}

my $offset = $origin;
my @bytes;

my %decoders = (
	'FCB' => \&decode_fcb,
	'FDB' => \&decode_fdb,
	'FCC' => \&decode_fcc,
	'IMMEDIATE' => \&decode_immediate,
	'IMMEDIATE16' => \&decode_immediate16,
	'IMMEDIATE32' => \&decode_immediate32,
	'STACK' => \&decode_stack,
	'REGISTER' => \&decode_register,
	'DIRECT' => \&decode_direct,
	'INDEXED' => \&decode_indexed,
	'EXTENDED' => \&decode_extended,
	'RELATIVE' => \&decode_relative,
	'RELATIVE16' => \&decode_relative16,
	'BIT_DIRECT' => \&decode_bit_direct,
	'IMM_DIRECT' => \&decode_imm_direct,
	'IMM_INDEXED' => \&decode_imm_indexed,
	'IMM_EXTENDED' => \&decode_imm_extended,
	'TFM' => \&decode_tfm,
);

my %lines = ();

my $page = 0;
my $pc = $offset;
my $file_rewind = undef;
my $cbyte;
my $skipped_comment = undef;
printf "\torg\t\$\%04x\n", $pc;
for (;;) {
	if ($page == 0) {
		@bytes = ();
		$pc = $offset;
	}
	my $area = 'CODE';
	while (defined $section && $pc > $$section[1]) {
		$section_num++;
		$section = $sections[$section_num];
	}
	if (defined $section && $pc >= $$section[0]) {
		$area = $$section[2];
	}

	my $comment;
	if (exists $comments{$pc}) {
		$comment = $comments{$pc};
	}

	my $c = getbyte();
	last if (!defined $c);

	my $ins;
	if ($area eq 'FCB') {
		$ins = { text => 'FCB', type => 'FCB' };
		my $i = 1;
		while ($i < 16 && $offset <= $$section[1]) {
			last if (exists $labels{$offset});
			last if (exists $comments{$offset});
			$c = getbyte();
			last if (!defined $c);
			$i++;
		}
	} elsif ($area eq 'FDB') {
		$ins = { text => 'FDB', type => 'FDB' };
		$c = getbyte();
		last if (!defined $c);
		my $i = 1;
		while ($i < 16 && $offset <= $$section[1]) {
			last if (exists $labels{$offset});
			last if (exists $comments{$offset});
			$c = getbyte();
			last if (!defined $c);
			$c = getbyte();
			last if (!defined $c);
			$i++;
		}
	} elsif ($area eq 'FCC') {
		$ins = { text => 'FCC', type => 'FCC' };
		my $i = 1;
		while ($i < 32 && $offset <= $$section[1]) {
			last if (exists $labels{$offset});
			last if (exists $comments{$offset});
			$c = getbyte();
			last if (!defined $c);
			last if ($c == 0 || $c == 0x0d);
			$i++;
		}
	} else {
		$ins = $instructions{$page}{$c} || { text => 'FCB', type => 'FCB' };
		$ins->{opcode} = $c;
	}

	if (exists $comment_bytes{$pc}) {
		$file_rewind = tell $file;
		$cbyte = $c;
	}

	if (exists $$ins{page}) {
		$page = $$ins{page};
		next;
	}
	my $text = lc $$ins{text};
	my $data = "";
	my $type = $$ins{type};
	my $illegal = $$ins{illegal};
	if (exists $decoders{$type}) {
		$data = $decoders{$type}($ins, \$illegal);
	}
	$illegal = 1 if (!defined $data);
	if ($illegal) {
		my $fcb = join(",", map { sprintf("\$\%02x", $_) } @bytes);
		$lines{$pc} = sprintf "fcb\t\%-16s; \%s \%s", $fcb, $text, $data;
	} else {
		$lines{$pc} = sprintf "\%s\t\%s", $text, $data;
	}

	if (defined $skipped_comment) {
		$lines{$pc} .= "\t; usually skipped by comment byte";
		undef $skipped_comment;
	}

	if (defined $file_rewind) {
		$lines{$pc} = sprintf("fcb\t\$\%02x\t; ", $cbyte).$lines{$pc}." - comment byte";
		seek $file, $file_rewind, 0;
		$offset = $pc + 1;
		undef $file_rewind;
		$skipped_comment = 1;
	}

	if (defined $comment) {
		$lines{$pc} .= "\t; $comment";
	}

	$page = 0;
}

for my $label (sort { $a <=> $b} keys %need_labels) {
	next if (exists $lines{$label});
	if ($label < $origin || $label >= $offset) {
		$lines{$label} = sprintf "equ\t\$\%04x", $label;
	} else {
		my $l;
		for ($l = $label - 1; $l >= $origin && !exists $lines{$l}; $l--) { };
		$lines{$label} = sprintf "equ\t%s + \%d", label_for($l), ($label - $l);
		$need_labels{$l} = 1;
	}
	$need_labels{$l} = 1;
}

for my $line (sort { $a <=> $b} keys %lines) {
	if (exists $forceorg{$line}) {
		printf "\torg\t\$\%04x\n", $line;
	}
	if (exists $need_labels{$line}) {
		print label_for($line);
	}
	printf "\t\%s\n", $lines{$line};
}

sub label_for {
	my ($addr) = @_;
	if (!exists $labels{$addr}) {
		$labels{$addr} = sprintf("L_\%04X", $addr);
	}
	return $labels{$addr};
}

sub rel_label_for {
	my ($addr) = @_;
	if (exists $labels{$addr}) {
		return $labels{$addr};
	}
	for my $i (1..2) {
		if (exists $def_labels{$addr-$i}) {
			return $def_labels{$addr-$i}." + $i";
		}
		if (exists $def_labels{$addr+$i}) {
			return $def_labels{$addr+$i}." - $i";
		}
	}
	return undef;
}

sub decode_fcb {
	my ($ins) = @_;
	return join(",", map { sprintf("\$\%02x", $_) } @bytes);
}

sub decode_fdb {
	my ($ins) = @_;
	my @words = ();
	while (@bytes) {
		push @words, ((shift @bytes) << 8) | shift @bytes;
	}
	return join(",", map { rel_label_for($_) || sprintf("\$\%04x", $_) } @words);
}

sub decode_fcc {
	my ($ins) = @_;
	my @strings = ();
	my $snum = 0;
	for my $byte (@bytes) {
		if ($byte >= 32 && $byte < 127 && $byte != 47) {
			$strings[$snum] = "/" if ($strings[$snum] eq "");
			$strings[$snum] .= sprintf("%c", $byte);
		} else {
			if ($strings[$snum] ne "") {
				$strings[$snum] .= "/" if ($strings[$snum] ne "");
				$snum++;
			}
			$strings[$snum] = sprintf("\$\%02x", $byte);
			$snum++;
		}
	}
	$strings[$snum] .= "/" if ($strings[$snum] =~ /^\//);
	return join(",", @strings);
}

sub decode_immediate {
	my ($ins) = @_;
	my $c = getbyte();
	return undef if (!defined $c);
	return sprintf("#\$\%02x", $c);
}

sub decode_immediate16 {
	my ($ins) = @_;
	my $w = getword();
	return undef if (!defined $w);
	my $alabel = rel_label_for($w);
	if ($alabel) {
		return "#$alabel";
	}
	return sprintf("#\$\%04x", $w);
}

sub decode_immediate32 {
	my ($ins) = @_;
	my $q = getquad();
	return undef if (!defined $q);
	return sprintf("#\$\%08x", $q);
}

sub decode_stack {
	my ($ins, $illegal) = @_;
	my $c = getbyte();
	return undef if (!defined $c);
	my @regs = ();
	if ($c & 0x01) { push @regs, "cc"; }
	if ($c & 0x02) { push @regs, "a"; }
	if ($c & 0x04) { push @regs, "b"; }
	if ($c & 0x08) { push @regs, "dp"; }
	if ($c & 0x10) { push @regs, "x"; }
	if ($c & 0x20) { push @regs, "y"; }
	if ($c & 0x40) { push @regs, $$ins{bit6}; }
	if ($c & 0x80) { push @regs, "pc"; }
	if ($c == 0) {
		$$illegal = 1;
	}
	return join(",", @regs);
}

sub decode_register {
	my ($ins, $illegal) = @_;
	my $post = getbyte();
	return undef if (!defined $post);
	my $r1 = ($post & 0xf0) >> 4;
	my $r2 = $post & 0x0f;
	if (!$isa_6309 && (($r1 ^ $r2) & 0x08)) {
		$$illegal = 1;
	}
	$r1 = $tfr_regs{$r1} || '*';
	$r2 = $tfr_regs{$r2} || '*';
	if ($r1 eq '*' || $r2 eq '*') {
		$$illegal = 1;
	}
	return sprintf("\%s,\%s", $r1, $r2);
}

sub decode_tfm {
	my ($ins, $illegal) = @_;
	my $post = getbyte();
	return undef if (!defined $post);
	if (($$ins{opcode} & 3) == 0) {
		($p1,$p2) = ("+", "+");
	} elsif (($$ins{opcode} & 3) == 1) {
		($p1,$p2) = ("-", "-");
	} elsif (($$ins{opcode} & 3) == 2) {
		($p1,$p2) = ("+", "");
	} else {
		($p1,$p2) = ("", "+");
	}
	my $r1 = ($post & 0xf0) >> 4;
	my $r2 = $post & 0x0f;
	if ($r1 > 4 || $r2 > 4) {
		$$illegal = 1;
	}
	$r1 = $tfr_regs{$r1} || '*';
	$r2 = $tfr_regs{$r2} || '*';
	if ($r1 eq '*' || $r2 eq '*') {
		$$illegal = 1;
	}
	return sprintf("\%s%s,\%s%s", $r1, $p1, $r2, $p2);
}

sub decode_direct {
	my ($ins) = @_;
	my $c = getbyte();
	return undef if (!defined $c);
	return sprintf("<\$\%02x", $c);
}

sub decode_indexed {
	my ($ins, $illegal) = @_;
	my $post = getbyte();
	return undef if (!defined $post);
	my $r = $index_regs{($post>>5)&3};
	if (($post & 0x80) == 0) {
		my $off = sex5($post&0x1f);
		if ($off == 0) {
			# Not really illegal, but a09 will assemble
			# "0,idx" into ",idx"
			$$illegal = 1;
		}
		return sprintf("\%d,\%s", $off, $r);
	}
	$$illegal = $illegal_indexed{$post & 0x1f};
	my $indirect = $post & 0x10;
	my $mode = $post & 0x0f;
	my $text = "";
	if ($isa_6309 && ($post == 0x8f || $post == 0x90)) {
		$text = ",w";
	} elsif ($isa_6309 && ($post == 0xaf || $post == 0xb0)) {
		my $v = getword();
		return undef if (!defined $v);
		$text = sprintf(">\$\%04x,w", $v);
	} elsif ($isa_6309 && ($post == 0xcf || $post == 0xd0)) {
		$text = ",w++";
	} elsif ($isa_6309 && ($post == 0xef || $post == 0xf0)) {
		$text = ",--w";
	} elsif ($mode == 0) {
		$text = sprintf(",\%s+", $r);
	} elsif ($mode == 1) {
		$text = sprintf(",\%s++", $r);
	} elsif ($mode == 2) {
		$text = sprintf(",-\%s", $r);
	} elsif ($mode == 3) {
		$text = sprintf(",--\%s", $r);
	} elsif ($mode == 4) {
		$text = sprintf(",\%s", $r);
	} elsif ($mode == 5) {
		$text = sprintf("b,\%s", $r);
	} elsif ($mode == 6) {
		$text = sprintf("a,\%s", $r);
	} elsif ($isa_6309 && $mode == 7) {
		$text = sprintf("e,\%s", $r);
	} elsif ($mode == 8) {
		my $v = getbyte();
		return undef if (!defined $v);
		$text = sprintf("<\$\%02x,\%s", $v, $r);
	} elsif ($mode == 9) {
		my $v = getword();
		return undef if (!defined $v);
		$text = sprintf(">\$\%04x,\%s", $v, $r);
	} elsif ($isa_6309 && $mode == 10) {
		$text = sprintf("f,\%s", $r);
	} elsif ($mode == 11) {
		$text = sprintf("d,\%s", $r);
	} elsif ($mode == 12) {
		my $o = getbyte();
		return undef if (!defined $o);
		if (($post & 0x60) != 0) {
			# Not illegal, but assemblers will set these bits to 0.
			$$illegal = 1;
		}
		$o = (sex8($o) + $offset) & 0xffff;
		my $absaddr = rel_label_for($o);
		if (defined $absaddr) {
			$text = "<$absaddr,pcr";
		} else {
			$text = sprintf("<\$\%04x,pcr", $o);
		}
	} elsif ($mode == 13) {
		my $o = getword();
		return undef if (!defined $o);
		if (($post & 0x60) != 0) {
			# Not illegal, but assemblers will set these bits to 0.
			$$illegal = 1;
		}
		$o = ($o + $offset) & 0xffff;
		$need_labels{$o} = 1;
		$text = sprintf(">%s,pcr", label_for($o));
		#$text = sprintf(">\$\%04x,pcr", $o);
	} elsif ($isa_6309 && $mode == 14) {
		$text = sprintf("w,\%s", $r);
	} elsif ($mode == 15) {
		my $a = getword();
		return undef if (!defined $a);
		$text = sprintf("\$\%04x", $a);
	}
	if ($indirect) {
		$text = "[$text]";
	}
	return $text;
}

sub decode_extended {
	my ($ins) = @_;
	my $w = getword();
	return undef if (!defined $w);
	if (!defined $code_end || $w < $origin || $w > $code_end) {
		return sprintf(">\$\%04x", $w);
	}
	my $label = $w & 0xffff;
	$need_labels{$label} = 1;
	return label_for($label);
}

sub decode_imm_direct {
	my ($ins) = @_;
	my $i = getbyte();
	return undef if (!defined $i);
	my $rest = decode_direct($ins);
	return undef if (!defined $rest);
	return sprintf("\#\$%02x,%s", $i, $rest);
}

sub decode_imm_indexed {
	my ($ins) = @_;
	my $i = getbyte();
	return undef if (!defined $i);
	my $rest = decode_indexed($ins);
	return undef if (!defined $rest);
	return sprintf("\#\$%02x,%s", $i, $rest);
}

sub decode_imm_extended {
	my ($ins) = @_;
	my $i = getbyte();
	return undef if (!defined $i);
	my $rest = decode_extended($ins);
	return undef if (!defined $rest);
	return sprintf("\#\$%02x,%s", $i, $rest);
}

sub decode_bit_direct {
	my ($ins) = @_;
	my $p = getbyte();
	return undef if (!defined $p);
	my $reg_idx = ($p >> 6) & 3;
	my $reg = $bit_regs{$reg_idx};
	my $sbit = ($p >> 3) & 7;
	my $dbit = $p & 7;
	my $rest = decode_direct($ins);
	return undef if (!defined $rest);
	return sprintf("%s,%d,%d,%s", $reg, $sbit, $dbit, $rest);
}

sub decode_relative {
	my ($ins) = @_;
	my $r = getbyte();
	return undef if (!defined $r);
	my $label = ($offset + sex8($r)) & 0xffff;
	$need_labels{$label} = 1;
	return label_for($label);
}

sub decode_relative16 {
	my ($ins) = @_;
	my $r = getword();
	return undef if (!defined $r);
	my $label = ($offset + $r) & 0xffff;
	$need_labels{$label} = 1;
	return label_for($label);
}

sub sex5 {
	my ($v) = @_;
	return int((($v) & 0x0f) - (($v) & 0x10));
}

sub sex8 {
	my ($v) = @_;
	return ($v & 0x80) ? ($v | 0xff00) : $v;
}

sub getbyte {
	my $c = getc($file);
	return undef if (!defined $c);
	$offset++;
	$c = unpack("C", $c);
	push @bytes, $c;
	return $c;
}

sub getword {
	my $h = getbyte();
	return undef if (!defined $h);
	my $l = getbyte();
	return undef if (!defined $l);
	return ($h << 8) | $l;
}

sub getquad {
	my $v = 0;
	for (my $i = 0; $i < 4; $i++) {
		my $b = getbyte();
		return undef if (!defined $b);
		$v = ($v << 8) | $b;
	}
	return $v;
}
