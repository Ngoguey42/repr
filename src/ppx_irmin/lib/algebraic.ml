(*
 * Copyright (c) 2019-2020 Craig Ferguson <me@craigfe.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

include Algebraic_intf
open Typ
open Ppxlib

let ( >> ) f g x = g (f x)

module Located (A : Ast_builder.S) (M : Monad.S) : S with module M = M = struct
  module M = M
  open A

  let ( >|= ) x f = List.map f x

  let compose_all : type a. (a -> a) list -> a -> a =
   fun l x -> List.fold_left ( |> ) x (List.rev l)

  let generate_identifiers n =
    List.init n (fun i -> Printf.sprintf "x%d" (i + 1))

  (** [lambda \[ "x_1"; ...; "x_n" \] e] is [fun x1 ... xN -> e] *)
  let lambda params = params >|= (pvar >> pexp_fun Nolabel None) |> compose_all

  (** {1 Helper functions for various subfragments} *)

  let construct ~polymorphic ?body name =
    if polymorphic then pexp_variant name body
    else pexp_construct (Located.lident name) body

  (** {[ |~ case0 "cons_name" (`)Cons_name ]} *)
  let variant_case0 ~polymorphic ~cons_name e =
    [%expr
      [%e e]
      |~ case0 [%e estring cons_name] [%e construct ~polymorphic cons_name]]

  (** {[
        |~ case1 "cons_name" component_type (fun (x1, ..., xN) -> (`)Cons_name (x1, ..., xN))
      ]} *)
  let variant_case1 ~polymorphic ~cons_name ~component_type ~idents e =
    let tuple_pat = idents >|= pvar |> ppat_tuple in
    let tuple_exp = idents >|= evar |> pexp_tuple in
    [%expr
      [%e e]
      |~ case1 [%e estring cons_name] [%e component_type] (fun [%p tuple_pat] ->
             [%e construct ~polymorphic ~body:tuple_exp cons_name])]

  (** Wrapper for {!variant_case0} and {!variant_case1} *)
  let variant_case ~polymorphic { case_name; case_cons } =
    match case_cons with
    | None -> variant_case0 ~polymorphic ~cons_name:case_name
    | Some (component_type, n) ->
        let idents = generate_identifiers n in
        variant_case1 ~polymorphic ~cons_name:case_name ~component_type ~idents

  (** [|+ field "field_name" (field_type) (fun t -> t.field_name)] *)
  let record_field { field_name; field_repr } e =
    [%expr
      [%e e]
      |+ field [%e estring field_name] [%e field_repr] (fun t ->
             [%e pexp_field (evar "t") (Located.lident field_name)])]

  (** Record composites are encoded as a constructor function

      {[ fun field1 field2 ... fieldN -> { field1; field2; ...; fieldN }) ]} *)
  let record_composite fields =
    let fields = fields >|= fun l -> l.pld_name.txt in
    let record =
      let rfields = fields >|= fun s -> (Located.lident s, evar s) in
      pexp_record rfields None
    in
    lambda fields record

  (** {[ | Cons_name (x1, x2, x3) -> cons_name x1 x2 x3 ] ]} *)
  let variant_pattern cons_name pattern n =
    let fparam_of_name name = String.lowercase_ascii name in
    match n with
    | 0 ->
        let lhs = pattern None in
        let rhs = evar (fparam_of_name cons_name) in
        case ~lhs ~guard:None ~rhs
    | n ->
        let idents = generate_identifiers n in
        let lhs = idents >|= pvar |> ppat_tuple |> fun x -> pattern (Some x) in
        let rhs =
          idents >|= evar |> pexp_tuple |> fun x ->
          [%expr [%e evar (fparam_of_name cons_name)] [%e x]]
        in
        case ~lhs ~guard:None ~rhs

  (** Variant composites are encoded as a destructor function:

      {[
        fun case1 case2 ... caseN -> function
           | Case1 x -> case1 c
           | Case2 (x1, x2) -> case2 x1 x2
            ...
           | CaseN -> casen
      ]} *)
  let variant_composite cs =
    let fparam_of_cdecl c = c.pcd_name.txt |> String.lowercase_ascii in
    let pattern_of_cdecl c =
      let pattern = ppat_construct (Located.map_lident c.pcd_name) in
      let n =
        match c.pcd_args with
        | Pcstr_tuple args -> List.length args
        | Pcstr_record _ -> invalid_arg "Inline record types unsupported"
      in
      variant_pattern c.pcd_name.txt pattern n
    in
    cs >|= pattern_of_cdecl |> pexp_function |> lambda (cs >|= fparam_of_cdecl)

  (** Analogous to {!variant_composite} but using AST fragments for polymorphic
      variants. *)
  let polyvariant_composite fs =
    let fparam_of_rowfield f =
      match f.prf_desc with
      | Rtag (label, _, _) -> String.lowercase_ascii label.txt
      | Rinherit _ -> assert false
    in
    let pattern_case_of_rowfield f =
      match f.prf_desc with
      | Rtag ({ txt; _ }, _, typs) ->
          let pattern = ppat_variant txt in
          let n = List.length typs in
          variant_pattern txt pattern n
      | Rinherit _ -> assert false
    in
    fs
    >|= pattern_case_of_rowfield
    |> pexp_function
    |> lambda (fs >|= fparam_of_rowfield)

  (** {1 Functional encodings of composite types}

      The functional encodings have a standard form:

      {[
        <combinator> <type_name> <composite>
        |> <augment> <subcomponent_1>
        |> <augment> <subcomponent_2>
        |> <augment> <subcomponent_3>
        |> <sealer>
      ]}

      That is, they initially construct an 'open' representation of the
      composite, then add each of the subcomponents to the open representation
      using an 'augmenter', and finally 'seal' the representation.

      The following functions provide each part of the encoding for each
      composite type. *)

  let augment_of_typ : type a b. (a, b) Typ.t -> b -> expression -> expression =
    function
    | Record -> record_field
    | Variant -> variant_case ~polymorphic:false
    | Polyvariant -> variant_case ~polymorphic:true

  let composite_of_typ : type a b. (a, b) Typ.t -> a list -> expression =
    function
    | Record -> record_composite
    | Variant -> variant_composite
    | Polyvariant -> polyvariant_composite

  let combinator_of_typ : type a b. (a, b) Typ.t -> string = function
    | Record -> "record"
    | Variant -> "variant"
    | Polyvariant -> "variant"

  let sealer_of_typ : type a b. (a, b) Typ.t -> expression -> expression =
    let seal name e = [%expr [%e e] |> [%e evar name]] in
    function
    | Record -> seal "sealr"
    | Variant -> seal "sealv"
    | Polyvariant -> seal "sealv"

  let encode :
      type a b.
      (a, b) Typ.t ->
      subderive:(a -> b M.t) ->
      type_name:string ->
      a list ->
      expression M.t =
   fun typ ~subderive ~type_name ts ->
    let open M.Syntax in
    let composite = composite_of_typ typ ts in
    let+ apply_augments =
      ts
      >|= (subderive >> M.map (augment_of_typ typ))
      |> M.sequence
      |> M.map (List.rev >> compose_all)
    in
    [%expr
      [%e evar (combinator_of_typ typ)] [%e estring type_name] [%e composite]]
    |> apply_augments
    |> sealer_of_typ typ
end
