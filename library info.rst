
Test data
---------
#. Old good quality data (purified)
#. MiSeq (better quality) & NextSeq (maybe unpurified but both protocols)
#. Only NextSeq (important goal)

Everything up until NGS15 purified.

Good test data: NGS12 MiSeq, NGS15 NextSeq, NGS17 MiSeq!

NGS15 and NGS17
~~~~~~~~~~~~~~~

NGS15 NextSeq libraries:

- Library1: Single Cell Replicate 1 (NGS15_SC_Rep1)

- Library2: Single Cell Replicate 2 (NGS15_SC_Rep2)

  Biological replicate of Library 1 i.e. another library, so for MiSeq-NextSeq comparison we can ignore this, because we didn't analyze it on a MiSeq device

- Library3: Bulk RNA Titration Replicate 1 (NGS15_Bulk_Rep1)

- Library4: Bulk RNA Titration Replicate 2 (NGS15_Bulk_Rep2)

  These were the dilution series where we had 4-fold dilutions of bulk RNA samples

- Library5: Spike-in Titration Replicate 1 (NGS15_Titration_Rep1)

- Library6: Spike-in Titration Replicate 2 (NGS15_Titration_Rep2)

  These were the dilution series where we had 10-fold dilutions of RNAspike-ins

Lib 1 re-analyzed in MiSeq. Corresponding files:

NGS15 (NextSeq)

- NGS15_SC_Rep1_S1_R1_001.fastq.gz
- NGS15_SC_Rep1_S1_R2_001.fastq.gz

NGS17 (MiSeq)

- SC-Lib1_S1_L001_R1_001.fastq.gz
- SC-Lib1_S1_L001_R2_001.fastq.gz

Info in “NGS-15 Analysis Required Information.xlsx”. Overview:

- Cell Plates
- Bulk & Titration Plates


NGS experiments that are used for the manuscript
------------------------------------------------

Genotyping:

- NGS4 - Lib3
- NGS7 - Lib2
- NGS8 - Lib1

Transcriptomics:

- NGS15 - Lib1 & Lib2
- NGS16 - Lib1, Lib2, & Lib3
- NGS25 - Lib1 & Lib2
