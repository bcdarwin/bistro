(** {:{http://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE29506}GEO Series GSE29506} *)

open Core
open Bistro
open Bistro_bioinfo

let common_spec f =
  let open Command.Let_syntax in
  [%map_open
    let outdir =
      flag "--outdir" (required string) ~doc:"DIR Directory where to link exported targets"
    and np =
      flag "--np" (optional_with_default 4 int) ~doc:"INT Number of processors"
    and mem =
      flag "--mem" (optional_with_default 4 int) ~doc:"INT Available memory (in GB)"
    and verbose =
      flag "--verbose" no_arg ~doc:" Logs build events on the console"
    and html_report =
      flag "--html-report" (optional string) ~doc:"PATH Logs build events in an HTML report"
    in
    f ~outdir ~np ~mem ~verbose ~html_report
  ]

let loggers verbose html_report = [
    (if verbose then console_logger () else null_logger ()) ;
    (match html_report with
     | Some path -> Bistro_utils.Html_logger.create path
     | None -> null_logger ())
  ]


let main repo ~outdir ~np ~mem ~verbose ~html_report () =
  let open Repo in
  build
    ~keep_all:false
    ~np ~mem:(`GB mem)
    ~loggers:(loggers verbose html_report)
    ~outdir repo

module ChIP_seq = struct
  let chIP_pho4_noPi = List.map ~f:Sra.fetch_srr [ "SRR217304" ; "SRR217305" ]

  let genome = Ucsc_gb.genome_sequence `sacCer2

  (* SAMPLES AS FASTQ *)
  let chIP_pho4_noPi_fq = List.map chIP_pho4_noPi ~f:Sra_toolkit.fastq_dump

  (* MAPPING *)
  let bowtie_index = Bowtie.bowtie_build genome
  let chIP_pho4_noPi_sam = Bowtie.bowtie ~v:2 bowtie_index (`single_end chIP_pho4_noPi_fq)
  let chIP_pho4_noPi_bam = Samtools.(indexed_bam_of_sam chIP_pho4_noPi_sam |> indexed_bam_to_bam)

  let chIP_pho4_noPi_macs2 = Macs2.callpeak ~mfold:(1,100) Macs2.bam [ chIP_pho4_noPi_bam ]

  let repo = Repo.[
    [ "chIP_pho4_noPi_macs2.peaks" ] %> chIP_pho4_noPi_macs2
  ]

  let command =
    let open Command.Let_syntax in
    Command.basic
      ~summary:"Analysis of a ChIP-seq dataset"
      (common_spec (main repo))
end

module RNA_seq = struct
  (* http://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE61661 *)

  let samples = [
    (`WT, `High_Pi) ;
    (`WT, `No_Pi 360) ;
  ]

  let sra_id = function
    | `WT, `High_Pi  -> "SRR1583715"
    | `WT, `No_Pi 360 -> "SRR1583740"
    | `WT, `No_Pi _ -> assert false

  let sra x = Sra.fetch_srr (sra_id x)

  let fastq x = Sra_toolkit.fastq_dump (sra x)

  let genome = Ucsc_gb.genome_sequence `sacCer2

  (* MAPPING *)
  let bowtie_index = Bowtie.bowtie_build genome

  let bam x =
    Tophat.(
      tophat1
        bowtie_index
        (`single_end [ fastq x ])
      |> accepted_hits
    )

  (* oddly the gff from sgd has a fasta file at the end, which htseq-count
     doesn't like. This is a step to remove it. *)
  let remove_fasta_from_gff gff =
    shell ~descr:"remove_fasta_from_gff" Shell_dsl.[
      cmd "sed" ~stdout:dest [
        string "'/###/q'" ;
        dep gff ;
      ]
    ]

  let gene_annotation : gff workflow =
    Bistro_unix.wget
      "http://downloads.yeastgenome.org/curation/chromosomal_feature/saccharomyces_cerevisiae.gff"
    |> remove_fasta_from_gff

  let counts x =
    Htseq.count
      ~stranded:`no ~feature_type:"gene" ~idattribute:"Name"
      (`bam (bam x)) gene_annotation

  let deseq2 =
    DESeq2.main_effects
      ["time"]
      [ [   "0" ], counts (`WT, `High_Pi) ;
        [ "360" ], counts (`WT, `No_Pi 360) ; ]

  let repo = Repo.[
    [ "deseq2" ; "0_vs_360" ] %> deseq2#effect_table ;
  ]

  let command =
    Command.basic
      ~summary:"Analysis of a RNA-seq dataset"
      (common_spec (main repo))
end

let command =
  Command.group
    ~summary:"Demo pipelines for bistro"
    [
      "chipseq", ChIP_seq.command ;
      "rnaseq",  RNA_seq.command ;
    ]

let () = Command.run ~version:"0.1" command
