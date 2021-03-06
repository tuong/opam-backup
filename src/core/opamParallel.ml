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

let log fmt = OpamGlobals.log "PARALLEL" fmt

module type G = sig
  include Graph.Sig.G
  include Graph.Topological.G with type t := t and module V := V
end

type error =
  | Process_error of OpamProcess.result
  | Internal_error of string

module type SIG = sig

  module G : G

  (** [iter n t pre child paren] parallel iteration on [n]
      cores. [child] is evaluated in a remote process and when it as
      finished, whereas [pre] and [post] are evaluated on the current
      process (respectively before and after the child process has
      been created). *)
  val parallel_iter: int -> G.t ->
    pre:(G.V.t -> unit) ->
    child:(G.V.t -> unit) ->
    post:(G.V.t -> unit) ->
    unit

  exception Errors of (G.V.t * error) list * G.V.t list

end

module Make (G : G) = struct

  module G = G

  module V = struct include G.V let compare = compare end
  module M = Map.Make (V)
  module S = Set.Make (V)

  type t = {
    graph  : G.t ;      (* The original graph *)
    visited: S.t ;      (* The visited nodes *)
    roots  : S.t ;      (* The current roots *)
    degree : int M.t ;  (* Node degrees *)
  }

  let init graph =
    let degree = ref M.empty in
    let add_degree v d = degree := M.add v d !degree in
    let roots =
      G.fold_vertex
        (fun v todo ->
          let d = G.in_degree graph v in
          if d = 0 then
            S.add v todo
          else (
            add_degree v d;
            todo
          )
        ) graph S.empty in
    { graph ; roots ; degree = !degree ; visited = S.empty }

  let visit t x =
    if S.mem x t.visited then
      invalid_arg "This node has already been visited.";
    if not (S.mem x t.roots) then
      invalid_arg "This node is not a root node";
      (* Add the node to the list of visited nodes *)
    let t = { t with visited = S.add x t.visited } in
      (* Remove the node from the list of root nodes *)
    let roots = S.remove x t.roots in
    let degree = ref t.degree in
    let remove_degree x = degree := M.remove x !degree in
    let replace_degree x d = degree := M.add x d (M.remove x !degree) in
      (* Update the children of the node by decreasing by 1 their in-degree *)
    let roots =
      G.fold_succ
        (fun x l ->
          let d = M.find x t.degree in
          if d = 1 then (
            remove_degree x;
            S.add x l
          ) else (
            replace_degree x (d-1);
            l
          )
        ) t.graph x roots in
    { t with roots; degree = !degree }

  (* the [Unix.wait] might return a processus which has not been created
     by [Unix.fork]. [wait pids] waits until a process in [pids]
     terminates. *)
  (* XXX: this will not work under windows *)

  let string_of_pids pids =
    Printf.sprintf "{%s}"
      (String.concat ","
         (OpamMisc.IntMap.fold (fun e _ l -> string_of_int e :: l) pids []))

  let string_of_status st =
    let st, n = match st with
      | Unix.WEXITED n -> "exit", n
      | Unix.WSIGNALED n -> "signal", n
      | Unix.WSTOPPED n -> "stop", n in
    Printf.sprintf "%s %d" st n

  let wait pids =
    let rec aux () =
      let pid, status = Unix.wait () in
      if OpamMisc.IntMap.mem pid pids then (
        log "%d is dead (%s)" pid (string_of_status status);
        pid, status
      ) else (
        log "%d: unknown child (pids=%s)!"
          pid
          (string_of_pids pids);
        aux ()
      ) in
    aux ()

  exception Errors of (G.V.t * error) list * G.V.t list

  let (--) = S.diff
  let (++) = S.union
  let (=|=) s1 s2 =
    S.cardinal s1 = S.cardinal s2

  (* write and close the output channel *)
  let write_error oc r =
    log "write_error";
    Marshal.to_channel oc r [];
    close_out oc

  (* read and close the input channel *)
  let read_error ic =
    log "read_error";
    let r : error =
      try Marshal.from_channel ic
      with _ -> Internal_error "Cannot read the error file" in
    close_in ic;
    r

  let parallel_iter n g ~pre ~child ~post =
    let t = ref (init g) in
    (* pid -> node * (fd to read the error code) *)
    let pids = ref OpamMisc.IntMap.empty in
    (* The nodes to process *)
    let todo = ref (!t.roots) in
    (* node -> error *)
    let errors = ref M.empty in

    (* All the node with a current worker currently doing some processing. *)
    let worker_nodes () =
      OpamMisc.IntMap.fold (fun _ (n, _) accu -> S.add n accu) !pids S.empty in
    (* All the error nodes. *)
    let error_nodes () =
      M.fold (fun n _ accu -> S.add n accu) !errors S.empty in
    (* All the node not successfully proceeded. This include error worker and error nodes. *)
    let all_nodes = G.fold_vertex S.add !t.graph S.empty in
    let remaining_nodes () =
      all_nodes -- !t.visited in

    log "Iterate over %d task(s) with %d process(es)" (G.nb_vertex g) n;

    (* nslots is the number of free slots *)
    let rec loop nslots =

      if OpamMisc.IntMap.is_empty !pids
      && (S.is_empty !t.roots || not (M.is_empty !errors) && !t.roots =|= error_nodes ()) then

        (* Nothing more to do *)
        if M.is_empty !errors then
          log "loop completed (without errors)"
        else
          let remaining = remaining_nodes () -- error_nodes () in
          raise (Errors (M.bindings !errors, S.elements remaining))

      else if nslots <= 0 || (worker_nodes () ++ error_nodes ()) =|= !t.roots then (

        (* if either 1/ no slots are available or 2/ no action can be performed,
           then wait for a child process to finish its work *)
        log "waiting for a child process to finish";
        let pid, status = wait !pids in
        let n, from_child = OpamMisc.IntMap.find pid !pids in
        pids := OpamMisc.IntMap.remove pid !pids;
        begin match status with
          | Unix.WEXITED 0 ->
              t := visit !t n;
              post n
          | _ ->
              let from_child = from_child () in
              let error = read_error from_child in
              errors := M.add n error !errors
        end;
        loop (nslots + 1)
      ) else (

        (* otherwise, if the todo list is empty, then refill it *)
        if S.is_empty !todo then (
          log "refilling the TODO list";
          todo := !t.roots -- worker_nodes () -- error_nodes ();
        );

        (* finally, if the todo list contains at least a node action,
           then simply process it *)
        let n = S.choose !todo in
        todo := S.remove n !todo;

        (* Set-up a channel from the child to the parent *)
        let error_file = OpamSystem.temp_file "error" in

        match Unix.fork () with
        | -1  -> OpamGlobals.error_and_exit "Cannot fork a new process"
        | 0   ->
            log "Spawning a new process";
            Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> OpamGlobals.error "Interrupted"; exit 1));
            let return p =
              let to_parent = open_out_bin error_file in
              write_error to_parent p;
              exit 1 in
            begin
              try child n; log "OK"; exit 0
              with
              | OpamSystem.Process_error p  -> return (Process_error p)
              | OpamSystem.Internal_error s -> return (Internal_error s)
              | e ->
                  let b = OpamMisc.pretty_backtrace () in
                  let e = Printexc.to_string e in
                  let error =
                    if b = ""
                    then e
                    else e ^ "\n" ^ b in
                  return (Internal_error error)
            end
        | pid ->
            log "Creating process %d" pid;
            let from_child () = open_in_bin error_file in
            pids := OpamMisc.IntMap.add pid (n, from_child) !pids;
            pre n;
            loop (nslots - 1)
      ) in
    loop n

end
