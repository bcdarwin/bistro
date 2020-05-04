open Base
module L = Location
open Ppxlib

let digest x =
  Caml.Digest.to_hex (Caml.Digest.string (Caml.Marshal.to_string x []))

let string_of_expression e =
  let buf = Buffer.create 251 in
  Pprintast.expression (Caml.Format.formatter_of_buffer buf) e ;
  Buffer.contents buf

let new_id =
  let c = ref 0 in
  fun () -> Caml.incr c ; Printf.sprintf "__v%d__" !c

module B = struct
  include Ast_builder.Make(struct let loc = Location.none end)
  let elident v = pexp_ident (Located.lident v)
  let econstr s args =
    let args = match args with
      | [] -> None
      | [x] -> Some x
      | l -> Some (pexp_tuple l)
    in
    pexp_construct (Located.lident s) args
  let enil () = econstr "[]" []
  let econs hd tl = econstr "::" [hd; tl]
  let enone () = econstr "None" []
  let esome x = econstr "Some" [ x ]
  let eopt x = match x with
    | None -> enone ()
    | Some x -> esome x
  let elist l = List.fold_right ~f:econs l ~init:(enil ())
  let pvar v = ppat_var (Located.mk v)
end

type insert_type =
  | Value
  | Path
  | Param

let insert_type_of_ext = function
  | "eval"  -> Value
  | "path"  -> Path
  | "param" -> Param
  | ext -> failwith ("Unknown insert " ^ ext)

class payload_env_rewriter = object
  inherit [(string * expression * insert_type) list] Ast_traverse.fold_map as super
  method! expression expr acc =
    match expr with
    | { pexp_desc = Pexp_extension ({txt = ("dest" | "np" | "mem" | "tmp" as ext) ; _ }, payload) ; pexp_loc = loc ; _ } -> (
        match payload with
        | PStr [] -> (
            let expr' = match ext with
              | "dest" -> [%expr __dest__]
              (* | "tmp" -> [%expr env#tmp] *)
              (* | "np" -> [%expr env#np] *)
              (* | "mem" -> [%expr env#mem] *)
              | _ -> assert false
            in
            expr', acc
          )
        | _ -> failwith "expected empty payload"

      )
    | _ -> super#expression expr acc
end

class payload_rewriter = object
  inherit payload_env_rewriter as super
  method! expression expr acc =
    match expr with
    | { pexp_desc = Pexp_extension ({txt = ("eval" | "path" | "param" as ext) ; loc ; _}, payload) ; _ } -> (
        match payload with
        | PStr [ { pstr_desc = Pstr_eval (e, _) ; _ } ] ->
          let id = new_id () in
          let acc' = (id, e, insert_type_of_ext ext) :: acc in
          let expr' = B.elident id in
          expr', acc'
        | _ -> failwith (Location.raise_errorf ~loc "expected an expression")
      )
    | _ -> super#expression expr acc

end

let add_renamings ~loc deps init =
  List.fold deps ~init ~f:(fun acc (tmpvar, expr, ext) ->
      let rhs = match ext with
        | Path  -> [%expr Bistro.Workflow.path [%e expr]]
        | Param -> [%expr Bistro.Workflow.data [%e expr]]
        | Value -> expr
      in
      [%expr let [%p B.pvar tmpvar] = [%e rhs] in [%e acc]]
    )

let build_applicative ~loc deps code =
  let id = digest (string_of_expression code) in
  match deps with
  | [] ->
    [%expr Bistro.Workflow.pure ~id:[%e B.estring id] [%e code]]
  | (h_tmpvar, _, _) :: t ->
    let tuple_expr =
      List.fold_right t ~init:(B.elident h_tmpvar) ~f:(fun (tmpvar,_,_) acc ->
          [%expr Bistro.Workflow.both [%e B.elident tmpvar] [%e acc]]
        )
    in
    let tuple_pat =
      List.fold_right t ~init:(B.pvar h_tmpvar) ~f:(fun (tmpvar,_,_) acc ->
          Ast_builder.Default.ppat_tuple ~loc [B.pvar tmpvar; acc]
        )
    in
    [%expr
      Bistro.Workflow.app
        (Bistro.Workflow.pure ~id:[%e B.estring id] (fun [%p tuple_pat] -> [%e code]))
        [%e tuple_expr]]
    |> add_renamings deps ~loc

let expression_rewriter ~loc ~path:_ expr =
  let code, deps = new payload_rewriter#expression expr [] in
  build_applicative ~loc deps code

let rec extract_body = function
  | { pexp_desc = Pexp_fun (_,_,_,body) ; _ } -> extract_body body
  | { pexp_desc = Pexp_constraint (expr, ty) ; _ } -> expr, Some ty
  | expr -> expr, None

let rec replace_body new_body = function
  | ({ pexp_desc = Pexp_fun (lab, e1, p, e2) ; _ } as expr) ->
    { expr with pexp_desc = Pexp_fun (lab, e1, p, replace_body new_body e2) }
  | _ -> new_body

let default_descr var =
  Printf.sprintf
    "%s.%s"
    Caml.Filename.(remove_extension (basename !L.input_name))
    var

let str_item_rewriter ~loc ~path:_ descr version mem np var expr =
  let descr = match descr with
    | Some d -> d
    | None -> B.estring (default_descr var)
  in
  let body, body_type = extract_body expr in
  let rewritten_body, deps = new payload_rewriter#expression body [] in
  let applicative_body = build_applicative ~loc deps [%expr fun () -> [%e rewritten_body]] in
  let workflow_body = [%expr
    Bistro.Workflow.plugin
      ~descr:[%e descr]
      ?version:[%e B.eopt version]
      ?np:[%e B.eopt np]
      ?mem:[%e B.eopt mem]
      [%e applicative_body]] in
  let workflow_body_with_type = match body_type with
    | None -> workflow_body
    | Some ty -> [%expr ([%e workflow_body] : [%t ty])]
  in
  [%stri let [%p B.pvar var] = [%e replace_body workflow_body_with_type expr]]

let gen_letin_rewriter ~loc ~env_rewrite (vbs : value_binding list) (body : expression) =
  let id = digest body in
  let rewritten_body, _ =
    if env_rewrite
    then new payload_env_rewriter#expression body []
    else body, []
  in
  let f = List.fold_right vbs ~init:rewritten_body ~f:(fun vb acc ->
      B.pexp_fun Nolabel None vb.pvb_pat acc
    )
  in
  List.fold vbs ~init:[%expr Bistro.Workflow.pure ~id:[%e B.estring id] [%e f]] ~f:(fun acc vb ->
      let module_expr = B.pmod_ident (B.Located.lident "Bistro.Workflow") in
      let oi = B.open_infos ~expr:module_expr ~override:Override in
      let e = B.pexp_open oi vb.pvb_expr in
      [%expr Bistro.Workflow.app [%e acc] [%e e]]
    )

let letin_rewriter ~loc ~path:_ vbs body = gen_letin_rewriter ~loc vbs ~env_rewrite:false [%expr fun () -> [%e body]]
let pletin_rewriter ~loc ~path:_ vbs body = gen_letin_rewriter ~loc ~env_rewrite:true vbs [%expr fun __dest__ -> [%e body]]

let pstr_item_rewriter ~loc ~path:_ descr version mem np var expr =
  let descr = match descr with
    | Some d -> d
    | None -> B.estring (default_descr var)
  in
  let body, body_type = extract_body expr in
  let rewritten_body, deps = new payload_rewriter#expression body [] in
  let applicative_body = build_applicative ~loc deps [%expr fun __dest__ -> [%e rewritten_body]] in
  let workflow_body = [%expr
    Bistro.Workflow.path_plugin
      ~descr:[%e descr]
      ?version:[%e B.eopt version]
      ?np:[%e B.eopt np]
      ?mem:[%e B.eopt mem]
      [%e applicative_body]] in
  let workflow_body_with_type = match body_type with
    | None -> workflow_body
    | Some ty -> [%expr ([%e workflow_body] : [%t ty])]
  in
  [%stri let [%p B.pvar var] = [%e replace_body workflow_body_with_type expr]]

let translate_position (p : Lexing.position) ~from:(q : Lexing.position) =
  {
    q with pos_lnum = p.pos_lnum + q.pos_lnum - 1 ;
           pos_bol = if p.pos_lnum = 1 then q.pos_bol else q.pos_cnum + p.pos_bol ;
           pos_cnum = p.pos_cnum + q.pos_cnum
  }

class ast_translation pos = object
  inherit Ast.map
  method bool x = x
  method char c = c
  method int x = x
  method list f x = List.map x ~f
  method option f x = Option.map x ~f
  method string x = x
  method! location loc =
    {
      loc with loc_start = translate_position loc.loc_start ~from:pos ;
               loc_end = translate_position loc.loc_end ~from:pos
    }
end

let script_rewriter ~loc:_ ~path:_ { txt = str ; loc } =
  match Script_parser.lexer str with
  | Error _ -> failwith "FIXME"
  | Ok fragments ->
    List.map fragments ~f:(function
        | `Text (i, j) ->
          let i = i.Script_parser.Position.cnum in
          let j = j.Script_parser.Position.cnum in
          let e = B.estring (String.sub str ~pos:i ~len:(j - i)) in
          [%expr Bistro.Shell_dsl.string [%e e]]
        | `Antiquotation (i, j) ->
          let cnum_i = i.Script_parser.Position.cnum in
          let cnum_j = j.Script_parser.Position.cnum in
          let txt = String.sub str ~pos:cnum_i ~len:(cnum_j - cnum_i) in
          let e = Parser.parse_expression Lexer.token (Lexing.from_string txt) in
          let i' = Script_parser.Position.translate_lexing_position ~by:i loc.loc_start in
          let j' = Script_parser.Position.translate_lexing_position ~by:j loc.loc_start in
          let loc' = Location.{ loc with loc_start = i' ; loc_end = j' } in
          (new ast_translation loc'.loc_start)#expression e
      )
    |> B.elist
    |> (fun e -> [%expr Bistro.Shell_dsl.seq ~sep:"" [%e e]])

let script_ext =
  let open Extension in
  declare "script" Context.expression Ast_pattern.(single_expr_payload (estring __')) script_rewriter

let expression_ext =
  let open Extension in
  declare "workflow" Context.expression Ast_pattern.(single_expr_payload __) expression_rewriter

let letin_ext =
  let open Extension in
  declare "deps" Context.expression Ast_pattern.(single_expr_payload (pexp_let nonrecursive __ __)) letin_rewriter

let pletin_ext =
  let open Extension in
  declare "pdeps" Context.expression Ast_pattern.(single_expr_payload (pexp_let nonrecursive __ __)) pletin_rewriter

let np_attr =
  Attribute.declare "bistro.np"
    Attribute.Context.value_binding
    Ast_pattern.(single_expr_payload (__))
    (fun x -> x)

let mem_attr =
  Attribute.declare "bistro.mem"
    Attribute.Context.value_binding
    Ast_pattern.(single_expr_payload (__))
    (fun x -> x)

let descr_attr =
  Attribute.declare "bistro.descr"
    Attribute.Context.value_binding
    Ast_pattern.(single_expr_payload (__))
    (fun x -> x)

let version_attr =
  Attribute.declare "bistro.version"
    Attribute.Context.value_binding
    Ast_pattern.(single_expr_payload (__))
    (fun x -> x)

let str_item_ext label rewriter =
  let open Extension in
  let pattern =
    let open Ast_pattern in
    let vb =
      value_binding ~expr:__ ~pat:(ppat_var __)
      |> Attribute.pattern np_attr
      |> Attribute.pattern mem_attr
      |> Attribute.pattern version_attr
      |> Attribute.pattern descr_attr
    in
    pstr ((pstr_value nonrecursive ((vb ^:: nil))) ^:: nil)
  in
    declare label Context.structure_item pattern rewriter

let () =
  Driver.register_transformation "bistro" ~extensions:[
    script_ext ;
    expression_ext ;
    letin_ext ;
    pletin_ext ;
    str_item_ext "workflow" str_item_rewriter ;
    str_item_ext "pworkflow" pstr_item_rewriter ;
  ]
