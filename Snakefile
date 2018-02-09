# usage example: snakemake -d data/ngs15 -j 4
import re
import json
from collections import Counter

from snakemake.utils import min_version, listfiles
import pandas as pd
import matplotlib
matplotlib.rcParams['backend'] = 'agg'  # make pypy work without Qt
import seaborn as sns
from tqdm import tqdm

from bartseq.io import write_bc_table, transparent_open


min_version('4.5.1')


with open('in/amplicons.fa') as a_f:
	amplicons = [line.lstrip('>').rstrip('\n') for line in a_f.readlines() if line.startswith('>')]
	amplicons += ['unmapped', 'one-mapped']

dir_qc = 'out/qc'
amplicon_index_stem = 'process/1-index/amplicons'
amplicon_index_files = expand('{stem}.{n}.ht2', stem=[amplicon_index_stem], n=range(1, 9))
all_reads_in = [(w.readname, w.read) for _, w in listfiles('in/reads/{readname}_R{read,[12]}_001.fastq.gz')]
lib_names = [readname for readname, read in all_reads_in if read == '1']
all_counts_out = expand('out/counts/{amplicon}/{amplicon}{which}{ext}', amplicon=amplicons, which=['', '-all'], ext=['.tsv', '-log.svg'])

def get_read_path(prefix, name, read, suffix='.fastq.gz'):
	return '{prefix}/{name}_R{read}_001{suffix}'.format_map(locals())

def get_read_paths(prefix, *suffixes):
	if len(suffixes) == 0:
		suffixes = ['.fastq.gz']
	return [
		get_read_path(prefix, n, r, suffix)
		for n, r in all_reads_in
		for suffix in suffixes
	]

reads_raw = get_read_paths('rawdata')


rule all:
	input:
		get_read_paths('out/qc', '_fastqc.html', '_fastqc.zip'),
		all_counts_out,
		'out/barcodes.htm',

rule get_qc:
	input:
		'in/reads/{name_full}.fastq.gz'
	output:
		expand('{dir_qc}/{{name_full}}_fastqc{suffix}', dir_qc=[dir_qc], suffix=['.html', '.zip'])
	shell:
		'fastqc {input:q} -o {dir_qc:q}'

rule get_read_count:
	input:
		'in/reads/{name}_R1_001.fastq.gz'
	output:
		'process/1-index/{name}_001.count.txt'
	shell:
		'''
		lines=$(zcat {input:q} | wc -l)
		echo "$lines / 4" | bc > {output:q}
		'''

rule trim_quality:
	input:
		expand('in/reads/{{name}}_R{read}_001.fastq.gz', read=[1,2]),
	output:
		expand('process/2-trimmed/{{name}}_R{read}_001.fastq.gz', read=[1,2]),
		single='process/2-trimmed/{name}_single_001.fastq.gz',
	shell:
		'''
		sickle pe --gzip-output --qual-type=sanger \
			--pe-file1={input[0]:q} --output-pe1={output[0]:q} \
			--pe-file2={input[1]:q} --output-pe2={output[1]:q} \
			--output-single={output.single:q}
		'''

rule bc_table:
	input:
		'in/barcodes.fa'
	output:
		'out/barcodes.htm'
	run:
		write_bc_table(input[0], output[0])

rule tag_reads:
	input:
		expand('process/2-trimmed/{{name}}_R{read}_001.fastq.gz', read=[1,2]),
		count_file='process/1-index/{name}_001.count.txt',
		bc_file='in/barcodes.fa',
	output:
		expand('process/3-tagged/{{name}}_R{read}_001.fastq.gz', read=[1,2]),
		stats_file='process/3-tagged/{name}_stats.json',
	run:
		from bartseq.main import run
		with open(input.count_file) as c_f:
			total = int(c_f.read())
		run(
			in_1=input[0], out_1=output[0],
			in_2=input[1], out_2=output[1],
			bc_file=input.bc_file,
			stats_file=output.stats_file,
			total=total,
		)

rule tag_stats:
	input:
		expand('process/3-tagged/{name}_stats.json', name=lib_names)
	run:
		for path in input:
			with open(path) as f:
				stats = json.load(f)
				for read in ['read1', 'read2']:
					print(path, read, sep='\t')
					for stat, count in stats[read].items():
						print('', stat, '{:.1%}'.format(count / stats['n_reads']), sep='\t')

# Helper rule for Lukas’ pipeline file
rule amplicon_fa:
	input:
		'in/amplicons.txt'
	output:
		'in/amplicons.fa'
	shell:
		r"cat {input:q} | tail -n +2 | cut -f 1,4 | sed 's/^ */>/;s/\t/\n/' > {output:q}"

rule build_index:
	input:
		'in/amplicons.fa'
	output:
		idx = amplicon_index_files,
	threads: 4
	shell:
		'hisat2-build -p {threads} {input:q} {amplicon_index_stem:q}'

rule map_reads:
	input:
		amplicons = amplicon_index_files,
		read = 'process/3-tagged/{name_full}.fastq.gz',
	output:
		map = 'process/4-mapped/{name_full}.txt',
		summary = 'process/4-mapped/{name_full}_summary.txt'
	threads: 4
	shell:
		'''
		hisat2 \
			--threads {threads} \
			--reorder \
			-k 1 \
			-x {amplicon_index_stem:q} \
			--new-summary --summary-file {output.summary:q} \
			-q -U {input.read:q} | \
			grep -v "^@" - | \
			cut -f3 > {output.map:q}
		'''

rule count:
	input:
		reads = expand('process/3-tagged/{{name}}_R{read}_001.fastq.gz', read=[1,2]),
		mappings = expand('process/4-mapped/{{name}}_R{read}_001.txt', read=[1,2]),
		stats_file='process/3-tagged/{name}_stats.json'
	output:
		'process/5-counts/{name}_001.tsv'
	run:
		bc_re = re.compile(r'barcode=(\w+)')
		with open(input.stats_file) as s_f:
			total = json.load(s_f)['n_both_regular']
		def get_barcodes(fastq_file):
			for header in fastq_file:
				next(fastq_file)
				next(fastq_file)
				next(fastq_file)
				yield bc_re.search(header).group(1)
		counts = Counter()
		with \
			transparent_open(input.reads[0]) as r1, open(input.mappings[0]) as a1, \
			transparent_open(input.reads[1]) as r2, open(input.mappings[1]) as a2:
			
			bcs1 = get_barcodes(r1)
			bcs2 = get_barcodes(r2)
			amps1 = (a.rstrip('\n') for a in a1)
			amps2 = (a.rstrip('\n') for a in a2)
			for bc1, bc2, amp1, amp2 in tqdm(zip(bcs1, bcs2, amps1, amps2), total=total):
				bc1, bc2 = sorted([bc1, bc2])
				if amp1 == amp2:
					counts[bc1, bc2, 'unmapped' if amp1 == '*' else amp1] += 1
				else:
					counts[bc1, bc2, 'one-mapped'] += 1
			
			with open(output[0], 'w') as of:
				print('bc_l', 'bc_r', 'amp', 'count', sep='\t', file=of)
				for fields, c in counts.items():
					print(*fields, c, sep='\t', file=of)

rule combine_counts:
	input:
		expand('process/5-counts/{name}_001.tsv', name=lib_names)
	output:
		all_counts_out
	run:
		entries = pd.concat([pd.read_csv(f, '\t') for f in input])
		entries['useful'] = entries.bc_l.str.match('L.*') & entries.bc_r.str.match('R.*')
		for amplicon in amplicons:
			entries_amplicon = entries[entries.amp == amplicon]
			del entries_amplicon['amp']
			
			table_amplicon = entries_amplicon.pivot('bc_l', 'bc_r', 'count')
			table_useful = entries_amplicon[entries_amplicon.useful].pivot('bc_l', 'bc_r', 'count')
			for o in [o for o in output if amplicon in o]:
				table = table_amplicon if '-all' in o else table_useful
				if o.endswith('.svg'):
					plot = sns.heatmap(table.transform(pd.np.log1p))
					plot.set(xlabel='', ylabel='')
					fig = plot.get_figure()
					fig.savefig(
						fname=o,
						bbox_inches='tight',
						transparent=True,
						pad_inches=0,
					)
					fig.clf()
				else:
					table.to_csv(o, '\t')


#Needs https://bitbucket.org/snakemake/snakemake/pull-requests/264
rule dag:
	shell:
		'snakemake -s {__file__} --dag | dot -Tsvg | gwenview /dev/stdin'
