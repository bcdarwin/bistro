open Types

val package : package workflow

val sort :
  ?on:[`name | `position] ->
  bam workflow -> bam workflow
val indexed_bam_of_sam : sam workflow -> [ `indexed_bam ] directory workflow
val indexed_bam_of_bam : bam workflow -> [ `indexed_bam ] directory workflow
val bam_of_indexed_bam : [ `indexed_bam ] directory workflow -> bam workflow
(* val bam_of_sam : sam workflow -> bam workflow *)
val sam_of_bam : bam workflow -> sam workflow

(* val rmdup : ?single_end_mode:bool -> bam workflow -> bam workflow *)