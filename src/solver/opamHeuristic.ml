(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012 OCamlPro                                          *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  OPAM is distributed in the hope that it will be useful,            *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

open OpamTypes

let log fmt = OpamGlobals.log "HEURISTIC" fmt

let rec minimize minimizable universe =
  log "minimize minimizable=%s" (OpamMisc.StringSet.to_string minimizable);
  if OpamMisc.StringSet.is_empty minimizable then
    universe
  else
    let is_removable universe name =
      let b, r = Cudf_checker.is_consistent (OpamCudf.uninstall name universe) in
      (match r with
      | None   -> log "%s is not necessary" name
      | Some r ->
        log "cannot remove %s: %s" name
          (Cudf_checker.explain_reason (r:>Cudf_checker.bad_solution_reason)));
      b in
    let to_remove = OpamMisc.StringSet.filter (is_removable universe) minimizable in
    let minimizable = OpamMisc.StringSet.diff minimizable to_remove in
    if OpamMisc.StringSet.is_empty to_remove then
      universe
    else
      let universe = OpamMisc.StringSet.fold OpamCudf.uninstall to_remove universe in
      minimize minimizable universe

(* Given a list of bounds, create the least tuple such that the sum of
   components is equal to n.  For instance: init [1;2;1] 3 is
   [0;2;1] *)
let init ~bounds n =
  let rec zero n =
    if n > 0 then
      0 :: zero (n-1)
    else
      [] in
  let rec aux = function
    | 0, []   -> Some []
    | 0, l    -> Some (zero (List.length l))
    | n, []   -> None
    | n, b::t ->
      if n <= b then
        Some (n :: zero (List.length t))
      else match aux (n-b, t) with
      | None   -> None
      | Some l -> Some (b::l) in
  match aux (n, List.rev bounds) with
  | None   -> None
  | Some l -> Some (List.rev l)

  (* Given a list of bounds and a tuple, return the next tuple while
     keeping the sum of components of the tuple constant *)
let rec cst_succ ~bounds l =
  let k = List.fold_left (+) 0 l in
  match l, bounds with
  | [] , []  -> None
  | [n], [b] ->
    if n+1 = k && n < b then
      Some [k]
    else
      None
  | n::nt, b::bt ->
    if n >= k then
      None
    else (
      match cst_succ ~bounds:bt nt with
      | Some s -> Some (n::s)
      | None   ->
        if n < b then
          match init ~bounds:bt (k-n-1) with
          | None   -> None
          | Some l -> Some (n+1 :: l)
        else
          None)
  | _ ->
    failwith "Bounds and tuples do not have the same size"

(* Given a list of bounds and a tuple, return the next tuple *)
let succ ~bounds l =
  match cst_succ ~bounds l with
  | Some t -> Some t
  | None   ->
    let k = List.fold_left (+) 0 l in
    init ~bounds (k+1)

(* explore the state-space given by an upgrade table.

   - [upgrade_tbl] associate pkg name to pacake constraints, for a
   collection of possible versions.

   - [f] is applied on each possible state of the system, where a
   state is where each pacakge has a fix version. We ensure that we
   apply [f] in increasing order regarding the difference between
   the maximum version and the current version for each
   package. That is, we apply [f] first on the state where all
   package have the maximum version, then on all the states where at
   all the package have their maximum version but one which has the
   second version, etc... *)
let explore f upgrade_tbl =
  let default_conflict = Conflicts (fun _ -> assert false)  in
  let upgrades =
    Hashtbl.fold (fun pkg constrs acc -> (pkg, constrs) :: acc) upgrade_tbl [] in
  let bounds = List.map (fun (_,v) -> Array.length v - 1) upgrades in
  let constrs t =
    List.map2 (fun (n, vs) i -> vs.(i)) upgrades t in
  let t0 = Unix.time () in
  let count = ref 0 in
  let rec aux = function
    | None   -> default_conflict
    | Some t ->
      let constrs = constrs t in
      log "explore %s %s"
        (OpamMisc.string_of_list string_of_int t)
        (OpamFormula.string_of_conjunction OpamCudf.string_of_atom constrs);
      incr count;
      let t1 = Unix.time () in
      if t1 -. t0 > 5. then (
        OpamGlobals.msg "The state-space is too big (at least %d states), so we cannot explore everything\n" !count;
        default_conflict
      ) else match f constrs with
      | Success _ as s -> s
      | _              -> aux (succ ~bounds t) in
  aux (init ~bounds 0)

let filter_dependencies universe constrs =
  let filter pkg =
    List.exists (fun (n,v) ->
      n = pkg.Cudf.package
      && match v with
      | None       -> true
      | Some (_,x) -> x=pkg.Cudf.version
    ) constrs in
  let packages = Cudf.get_packages ~filter universe in
  let graph = OpamCudf.Graph.of_universe universe in
  let packages = OpamCudf.Graph.closure graph (OpamCudf.Set.of_list packages) in
  List.map (fun p -> p.Cudf.package) packages

(* Try to play all the possible upgrade scenarios ... *)
let resolve universe request =
  match OpamCudf.get_final_universe universe request with

  | Conflicts e ->
    log "cudf_resolve_opt conflict!";
    Conflicts e

  | Success u   ->
    log "cudf_resolve_opt success!";

    (* Get all the possible package which can be modified *)
    let names = filter_dependencies universe request.wish_upgrade in

    (* All the packages in the request *)
    let all = Hashtbl.create 1024 in

    (* Package which are maybe not so useful *)
    let minimizable = ref OpamMisc.StringSet.empty in

    (* The packages to upgrade *)
    let upgrade = Hashtbl.create 1024 in

    (* The versions given by the solution *)
    let versions = Hashtbl.create 1024 in
    List.iter (fun pkg -> Hashtbl.add versions pkg.Cudf.package pkg.Cudf.version) (Cudf.get_packages u);
    let version name =
      try Some (Hashtbl.find versions name)
      with Not_found -> None in

    let add_upgrade name =
      let packages = Cudf.get_packages ~filter:(fun p -> p.Cudf.package = name) universe in
      let packages = List.sort (fun p1 p2 -> compare p2.Cudf.version p1.Cudf.version) packages in
      (* only keep the version greater or equal to either:
         - the currently installed package; or
         - the version proposed by the solver *)
      let min_version =
        match version name, List.filter (fun p -> p.Cudf.installed) packages with
        | None  , []  -> min_int
        | None  , [i] -> i.Cudf.version
        | Some v, []  -> v
        | Some v, [i] -> max v i.Cudf.version
        | _ -> assert false (* at most one version is installed *) in
      let packages = List.filter (fun p -> p.Cudf.version >= min_version) packages in
      let atoms = List.map (fun p -> p.Cudf.package, Some (`Eq, p.Cudf.version)) packages in
      Hashtbl.add upgrade name (Array.of_list atoms) in

    (* Register the packages in the request *)
    List.iter (fun (n,_) -> Hashtbl.add all n false) request.wish_install;
    List.iter (fun (n,_) -> Hashtbl.add all n true) request.wish_upgrade;

    (* Register the upgraded packages *)
    let add_constr (n,v as x) =
      match v with
      | Some _ -> Hashtbl.add upgrade n [| x |]
      | None   -> add_upgrade n in

    List.iter add_constr request.wish_upgrade;
    List.iter add_constr (List.filter (fun (n,_) -> List.mem n names) request.wish_install);

    (* Register the new packages *)
    let diff = Common.CudfDiff.diff universe u in
    Hashtbl.iter (fun name s ->
      if not (Common.CudfAdd.Cudf_set.is_empty s.Common.CudfDiff.installed) then (
        if not (Hashtbl.mem all name) then
          minimizable := OpamMisc.StringSet.add name !minimizable;
        if not (Hashtbl.mem upgrade name) then
          add_upgrade name)
    ) diff;

    let wish_install = List.map (fun (n,v) ->
      n,
      match v with
      | None   ->
        if not (List.mem n names) then
          match Cudf.get_installed universe n with
          | []   -> None
          | p::_ -> Some (`Eq, p.Cudf.version)
        else
          None
      | _ -> v
    ) request.wish_install in

    let resolve wish_upgrade =
      let request = { request with wish_install; wish_upgrade } in
      OpamCudf.get_final_universe universe request in

    match explore resolve upgrade with
    | Conflicts _ -> OpamCudf.resolve universe request
    | Success u   ->
      log "succes=%s" (OpamCudf.string_of_universe u);
      try
        let diff = OpamCudf.Diff.diff universe (minimize !minimizable u) in
        Success (OpamCudf.actions_of_diff diff)
      with Cudf.Constraint_violation s ->
        OpamGlobals.error_and_exit "constraint violations: %s" s
