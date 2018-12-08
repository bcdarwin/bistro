open Core
open Bistro_internals
open Bistro_engine

(* module T = struct
 *   include Task
 *   let sexp_of_t _ = assert false
 *   let t_of_sexp _ = assert false
 *   let hash t = String.hash (Task.id t)
 * end *)

module W = Workflow

module V = struct
  include W.Any
  let sexp_of_t _ = assert false
  let t_of_sexp _ = assert false
end

module E = struct
  type t = Dependency | GC_link
  let default = Dependency
  let compare = compare
end

module S = Set.Make(V)

module G = struct
  open E
  include Graph.Persistent.Digraph.ConcreteLabeled(V)(E)
  (* let successors   g u = fold_succ (fun h t -> h :: t) g u [] *)

  let rec of_workflow_aux seen acc u =
    if S.mem seen u then (seen, acc)
    else (
      let deps = W.Any.deps u in
      let seen, acc =
        List.fold deps
          ~init:(seen, acc)
          ~f:(fun (seen, acc) v -> of_workflow_aux seen acc v)
      in
      let acc = List.fold deps ~init:acc ~f:(fun acc v -> add_edge acc u v) in
      let seen = S.add seen u in
      seen, acc
    )

  let of_workflow u =
    of_workflow_aux S.empty empty (W.Any u)
    |> snd

  let of_gc_state gc_state =
    List.fold gc_state.Scheduler.Gc.deps ~init:empty ~f:(fun acc (u, v) ->
        let e = E.create u GC_link v in
        add_edge_e acc e
      )

end


let light_gray = 0xC0C0C0
let black = 0

let shape = function
  | _ -> `Box

let dot_output ?db oc g ~needed =
  let already_done = match db with
    | None -> Fn.const false
    | Some db -> Db.is_in_cache db
  in
  let step_attributes ~descr u =
    let already_done = already_done u in
    let color = black in
    let shape = `Shape (shape u) in
    let id = W.Any.id u in
    [ `Label (sprintf "%s.%s" descr (String.prefix id 6)) ;
      shape ;
      `Peripheries (if already_done then 2 else 1) ;
      `Color color ;
      `Fontcolor color ;
    ]
  in
  let vertex_attributes u =
    let needed = S.mem needed u in
    let color = if needed then black else light_gray in
    let shape = `Shape (shape u) in
    let W.Any w = u in
    match w with
    | W.Input i ->
      let label = i.path in
      [ `Label label ; `Color color ; `Fontcolor color ; shape ]
    | Select s ->
      let label = Path.to_string s.sel in
      [ `Label label ; `Fontcolor color ; `Color color ; shape ]
    | Shell { descr ; _ } -> step_attributes ~descr u
    | Value { descr ; _ } -> step_attributes ~descr u
    | Path { descr ; _ } -> step_attributes ~descr u
    | Pure _ -> [ `Label "pure" ; `Shape `Plaintext ]
    | App _ -> [ `Label "app" ; `Shape `Plaintext ]
    | Spawn _ -> [ `Label "spawn" ; `Shape `Ellipse ]
    | Both _ -> [ `Label "both" ; `Shape `Plaintext ]
    | List _ -> [ `Label "list" ; `Shape `Plaintext ]
    | Eval_path _ -> [ `Label "path" ; `Shape `Plaintext ]
  in
  let edge_attributes e =
    let u = G.E.src e and v = G.E.dst e in
    let style = match u, v, G.E.label e with
      | _, _, GC_link -> [ `Style `Dotted ]
      | W.Any W.Select _, _, Dependency -> [ `Style `Dashed ]
      | _ -> []
    in
    let color =
      if S.mem needed u
      && not (already_done u)
      then black else light_gray in
    style @ [ `Color color ]
  in
  let module G = struct
    include G
    let graph_attributes _ = []
    let default_vertex_attributes _ = []
    let vertex_name t = sprintf "\"%s\"" (W.Any.id t)
    let vertex_attributes = vertex_attributes
    let edge_attributes = edge_attributes
    let get_subgraph _ = None
    let default_edge_attributes _ = []
  end in
  let module Dot = Graph.Graphviz.Dot(G) in
  Dot.output_graph oc g

(* class logger path : Scheduler.logger =
 *   object
 *     method event config _ = function
 *       | Scheduler.Init { dag ; needed ; already_done } ->
 *         let needed = S.of_list needed in
 *         let already_done = S.of_list already_done in
 *         dot_output dag ~needed ~already_done path ~precious:config.Task.precious
 *       | _ -> ()
 *
 *     method stop = ()
 *
 *     method wait4shutdown = Lwt.return ()
 *   end
 *
 * let create path = new logger path *)

let workflow_to_channel ?db oc w =
  let dep_graph = G.of_workflow (Bistro.Private.reveal w) in
  dot_output ~needed:S.empty ?db oc dep_graph

let workflow_to_file ?db fn w =
  Out_channel.with_file fn ~f:(fun oc -> workflow_to_channel ?db oc w)

let gc_state_to_channel ?db oc gcs =
  let dep_graph = G.of_gc_state gcs in
  dot_output ~needed:S.empty ?db oc dep_graph

let gc_state_to_file ?db fn w =
  Out_channel.with_file fn ~f:(fun oc -> gc_state_to_channel ?db oc w)
