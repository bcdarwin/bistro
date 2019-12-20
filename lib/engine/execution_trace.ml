open Core_kernel

type time = float

type t =
  | Run of { ready : time ;
             start : time ;
             _end_ : time ;
             outcome : Task_result.t }

  | Done_already of { id : string }
  | Canceled of {
      id : string ;
      missing_deps : t list ;
    }
  | Allocation_error of {
      id : string ;
      msg : string ;
    }

module S = struct
  module Elt = struct type nonrec t = t let compare = Poly.compare end
  include Caml.Set.Make(Elt)
end

let is_errored = function
  | Run { outcome ; _ } -> not (Task_result.succeeded outcome)
  | Allocation_error _
  | Canceled _ -> true
  | Done_already _ -> false

let gather_failures traces =
  List.fold traces ~init:S.empty ~f:(fun acc t ->
      match t with
      | Done_already _ -> acc
      | Run { outcome ; _ } ->
        if Task_result.succeeded outcome then
          acc
        else
          S.add t acc
      | Canceled { missing_deps ; _ } ->
        List.fold ~f:(Fn.flip S.add) ~init:acc missing_deps
      | Allocation_error _ -> S.add t acc
    )
  |> S.elements

let error_title buf title short_desc =
  bprintf buf "################################################################################\n" ;
  bprintf buf "#                                                                              #\n" ;
  bprintf buf "#  %s\n" title ;
  bprintf buf "#                                                                               \n" ;
  bprintf buf "#------------------------------------------------------------------------------#\n" ;
  bprintf buf "#                                                                               \n" ;
  bprintf buf "# %s\n" short_desc ;
  bprintf buf "#                                                                              #\n" ;
  bprintf buf "################################################################################\n" ;
  bprintf buf "###\n" ;
  bprintf buf "##\n" ;
  bprintf buf "#\n"

let error_report trace db buf =
  match trace with
  | Run { outcome ; _ } ->
    if not (Task_result.succeeded outcome) then
      let title = sprintf "Task %s failed\n" (Task_result.name outcome) in
      let short_descr = Task_result.error_short_descr outcome in
      error_title buf title short_descr ;
      Task_result.error_long_descr outcome db buf (Task_result.id outcome)
  | Allocation_error { id ; msg } ->
    let title = sprintf "Task %s failed\n" id in
    let short_descr = sprintf "Allocation error: %s\n" msg in
    error_title buf title short_descr
  | (Done_already _ | Canceled _) -> ()

let all_ok xs = not (List.exists ~f:is_errored xs)

module Set = S
