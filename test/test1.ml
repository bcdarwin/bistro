open Core
open Bistro
open Lwt.Infix

let add x y = Workflow.cached_value (fun%workflow () ->
    [%eval x] + [%eval y]
  )

let%workflow mul x y : int workflow =
  [%eval x] * [%eval y]

let pipeline = add (Workflow.int 1) (Workflow.int 41)

let _ =
  Bistro_engine.Scheduler.eval pipeline >|= Printf.printf "%d\n"
  |> Lwt_main.run