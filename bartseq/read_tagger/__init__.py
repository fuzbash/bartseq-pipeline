from collections import OrderedDict
from typing import NamedTuple, Iterable, FrozenSet, Tuple, Optional, Generator, Iterator, Dict, Set

from ahocorasick import Automaton
from warnings import warn

import pandas as pd

from . import defaults


BASES = set('ATGC')

HTML_INTRO = f'''\
<!doctype html>
<meta charset="utf-8">
<style>
body  {{ font-size: 12px }}
table {{ border-collapse: collapse }}
th:empty,
table {{ border: none }}
th, td {{ border: 1px solid rgba(0,0,0,.2); padding: 5px }}
thead, tbody th {{ position: sticky }}

thead th,
.a    {{ color: #FF6AD5 }}
tbody th,
.b    {{ color: #AD8CFF }}
td    {{ color: #94D0FF }}
.both {{ color: red }}
</style>
'''


class TaggedRead(NamedTuple):
	header: str
	qual: str  # Whole qual sequence
	len_primer: int
	junk: Optional[str]
	barcode: Optional[str]
	linker: Optional[str]
	amplicon: str
	other_barcodes: FrozenSet[str]
	barcode_mismatch: bool
	
	@property
	def has_multiple_barcodes(self):
		return len(self.other_barcodes) > 0
	
	@property
	def is_just_primer(self):
		return self.barcode is not None and len(self.amplicon) <= self.len_primer
	
	@property
	def is_regular(self):
		return self.barcode and not self.is_just_primer
	
	def cut_seq(self, seq):
		ljb = len(self.junk or []) + len(self.barcode or [])
		ljba = ljb + len(self.amplicon or [])
		return seq[ljb:ljba]
	
	def __str__(self):
		return f'''\
{self.header}\
 barcode={self.barcode}\
 linker={self.linker}\
 multi-bc={self.has_multiple_barcodes}\
 just-primer={self.is_just_primer}\
 other-bcs={",".join(self.other_barcodes) or None}\
 barcode-mismatch={self.barcode_mismatch}\
 junk={self.junk}
{self.amplicon}
+
{self.cut_seq(self.qual)}
'''


PREDS = dict(
	n_only_primer=lambda read: read.is_just_primer,
	n_multiple_bcs=lambda read: read.has_multiple_barcodes,
	n_no_barcode=lambda read: not read.barcode,
	n_barcode_mismatch=lambda read: read.barcode_mismatch,
	n_junk=lambda read: read.junk,
	n_regular=lambda read: read.is_regular,
)


def get_mismatches(barcode: str, *, max_mm: int = 1) -> Generator[str, None, None]:
	yield barcode
	if max_mm != 1:
		raise NotImplemented
	if max_mm == 1:
		for i in range(len(barcode)):
			for mismatch in BASES - {barcode[i]}:
				yield f'{barcode[:i]}{mismatch}{barcode[i+1:]}'


def get_all_barcodes(
	barcodes: Iterable[str],
	*,
	max_mm: int = 1
) -> Tuple[Dict[str, str], Dict[str, Set[Tuple[str, str]]]]:
	found = {}
	blacklist = {}
	
	for barcode in barcodes:
		for pattern in get_mismatches(barcode, max_mm=max_mm):
			previous_barcode = found.get(pattern)
			if previous_barcode:
				bl_item = blacklist.setdefault(pattern, set())
				bl_item.add((previous_barcode, barcode))
				bl_item.add((barcode, previous_barcode))
				warn(
					'Barcodes with one mismatch are ambiguous: '
					f'Modification {pattern} encountered in '
					f'barcode {previous_barcode} and {barcode}'
				)
			found[pattern] = barcode
	
	for pattern in blacklist:
		del found[pattern]
	
	return found, blacklist


class ReadTagger:
	def __init__(
		self,
		bc_to_id: Dict[str, str],
		len_linker: int,
		len_primer: int,
		*,
		max_mm: int = 1,
		use_stats: bool = True
	):
		self.bc_to_id = bc_to_id
		self.len_linker = len_linker
		self.len_primer = len_primer
		self.stats = None if not use_stats else dict(
			n_only_primer=0,
			n_multiple_bcs=0,
			n_no_barcode=0,
			n_regular=0,
			n_barcode_mismatch=0,
			n_junk=0,
		)
		
		self.automaton = Automaton()
		all_barcodes, self.blacklist = get_all_barcodes(bc_to_id.keys(), max_mm=max_mm)
		for pattern, barcode in all_barcodes.items():
			self.automaton.add_word(pattern, barcode)
		self.automaton.make_automaton()
	
	def search_barcode(self, read: str) -> Tuple[int, int, str]:
		for end, barcode in self.automaton.iter(read):
			start = end - len(barcode) + 1
			yield start, end + 1, barcode
	
	def tag_read(self, header: str, seq_read: str, seq_qual: str) -> TaggedRead:
		# as ordered set
		matches = OrderedDict((match, None) for match in self.search_barcode(seq_read))
		
		match_iter: Iterator[Tuple[int, int, str]] = iter(matches)
		bc_start, bc_end, barcode = next(match_iter, (None, None, None))
		
		bc_id = self.bc_to_id.get(barcode)
		other_barcodes = frozenset(set(self.bc_to_id[bc] for _, _, bc in match_iter) - {bc_id})
		
		if barcode is not None:
			linker_end = bc_end + self.len_linker if bc_end else None
			
			junk = seq_read[:bc_start] or None
			linker = seq_read[bc_end:linker_end]
			amplicon = seq_read[linker_end:]
			barcode_mismatch = seq_read[bc_start:bc_end] != barcode
		else:
			junk = None
			linker = None
			amplicon = seq_read
			barcode_mismatch = False
		
		read = TaggedRead(
			header, seq_qual, self.len_primer, junk, bc_id,
			linker, amplicon, other_barcodes, barcode_mismatch,
		)
		
		if self.stats is not None:
			for name, pred in PREDS.items():
				if pred(read):
					self.stats[name] += 1
		
		return read
	
	def get_barcode_table(self, plain=False):
		cell_templates = {
			(True, True): '{}',
			(True, False): '<span class="b">{}</span>',
			(False, True): '<span class="a">{}</span>',
			(False, False): '<span class="both">{}</span>',
		}
		
		patterns = sorted({bc for bc_pairs in self.blacklist.values() for pair in bc_pairs for bc in pair})
		sprs = pd.DataFrame(index=patterns, columns=patterns, dtype=str)
		for pattern, bc_pairs in self.blacklist.items():
			for bc1, bc2 in bc_pairs:
				sprs.loc[bc1, bc2] = ''.join(
					cell_templates[bc1[i] == base, bc2[i] == base].format(base)
					for i, base in enumerate(pattern)
				)
		
		with pd.option_context('display.max_colwidth', -1):
			html = sprs.to_html(escape=False, na_rep='')
		
		if plain:
			return html
		return HTML_INTRO + html


def get_tagger(
	id_to_bc: Iterable[Tuple[str, str]],
	len_linker: int = defaults.len_linker,
	len_primer: int = defaults.len_primer,
):
	bc_to_id = {bc: id_ for id_, bc in id_to_bc}
	return ReadTagger(bc_to_id, len_linker, len_primer)
