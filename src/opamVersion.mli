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

(** Compiler and OPAM versions *)

(** Binary relations *)
type relop = [`Eq|`Geq|`Gt|`Leq|`Lt]

(** OCaml compiler versions *)
module Compiler: sig

  include OpamMisc.ABSTRACT

  (** Compiler constraint *)
  type constr = relop * t

  (** Return the version of the compiler currently installed *)
  val current: unit -> t option

  (** Compare OCaml versions *)
  val compare: t -> relop -> t -> bool

  (** List the compiler available in a directory *)
  val list: OpamFilename.Dir.t -> Set.t

end

(** OPAM versions *)
module OPAM: OpamMisc.ABSTRACT

