#!/usr/bin/env python

"""
    add comments to a disassemble listing
    =====================================

    usage e.g.:

    python add_comments.py d32.lis d32_comments.lis --meminfo="Dragon32.txt"

    :created: 2014 by Jens Diemer - www.jensdiemer.de
    :copyleft: 2014 by the 6809 team, see AUTHORS for more details.
    :license: GNU GPL v3 or above, see LICENSE for more details.
"""

import sys
import time
import argparse


class MemoryInfo2Comments(object):
    def __init__(self, rom_info_file):
        self.mem_info = self._get_rom_info(rom_info_file)

    def eval_addr(self, addr):
        addr = addr.strip("$")
        return int(addr, 16)

    def _get_rom_info(self, rom_info_file):
        sys.stderr.write(
            "Read ROM Info file: %r\n" % rom_info_file.name
        )
        rom_info = []
        next_update = time.time() + 0.5
        for line_no, line in enumerate(rom_info_file):
            if time.time() > next_update:
                sys.stderr.write(
                    "\rRead %i lines..." % line_no
                )
                sys.stderr.flush()
                next_update = time.time() + 0.5

            try:
                addr_raw, comment = line.split(";", 1)
            except ValueError:
                continue

            try:
                start_addr_raw, end_addr_raw = addr_raw.split("-")
            except ValueError:
                start_addr_raw = addr_raw
                end_addr_raw = None

            start_addr = self.eval_addr(start_addr_raw)
            if end_addr_raw:
                end_addr = self.eval_addr(end_addr_raw)
            else:
                end_addr = start_addr

            rom_info.append(
                (start_addr, end_addr, comment.strip())
            )
        sys.stderr.write(
            "ROM Info file: %r readed.\n" % rom_info_file.name
        )
        return rom_info

    def add_comments(self, infile, outfile):
        mem_dict = dict([
            (start_addr, comment)
            for start_addr, end_addr, comment in self.mem_info
        ])

        for line in infile:
            line = line.strip()
            addr = line[:4]
            try:
                addr = self.eval_addr(addr)
            except ValueError:
                outfile.write("%s\n" % line)
                continue

            comments = set()

            try:
                code, origin_comment = line.split(";", 1)
            except ValueError:
                code = line
            else:
                comments.add(origin_comment)

            try:
                mem_info = mem_dict[addr]
            except KeyError:
                pass
            else:
                comments.add(mem_info)
                
            comment = " / ".join(comments)

            if comment:
                line = "%-60s ; %s\n" % (code, comment)
            else:
                line = "%s\n" % code
            outfile.write(line)


def main(args):
    rom_info = MemoryInfo2Comments(args.meminfo)
    rom_info.add_comments(args.infile, args.outfile)
    sys.stderr.write("\n --- END --- \n")

def get_cli_args():
    parser = argparse.ArgumentParser(
        description="create comment statements from rom info for 6809dasm.pl"
    )
    parser.add_argument('infile', nargs='?',
        type=argparse.FileType('r'), default=sys.stdin,
        help="Dissassembly listing"
    )
    parser.add_argument('outfile', nargs='?',
        type=argparse.FileType('w'), default=sys.stdout,
        help="output file or stdout"
    )
    parser.add_argument('--meminfo',
        type=argparse.FileType('r'), default=sys.stdout,
        help="ROM Addresses info file or stdin"
    )
    args = parser.parse_args()
    return args


if __name__ == '__main__':
    sys.argv += ["d64_1.lis", "d64_1_comments.lis", "--meminfo=Dragon 64 in 32 mode.txt"]

    args = get_cli_args()
    main(args)
