open ExtString

module Namespace =
struct
  open Printf

  type name = Name of Cudf_types.pkgname
  let name_compare = compare

  type version = { deb : Debian.Format822.version }

  let string_of_nv (Name n) version = sprintf "%s-%s" n version.deb
  let string_of_name (Name n) = n
  let string_user_of_name (Name n) = n
  let string_user_of_version version = version.deb

  let version_of_string version = { deb = version }
 
  let nv_of_string s = 
    let n, version = String.split s "-" in
      Name n, version_of_string version

  let default_version = "0"

  let user_print oc (Name n, v) =
    BatString.print oc (Printf.sprintf "%s %s" n v.deb)
end

type name_version = Namespace.name * Namespace.version

module N_map = BatMap.Make (struct open Namespace type t = name let compare = name_compare end)
module V_set = BatSet.Make (struct open Namespace type t = version let compare = compare end)

module NV_orderedtype = 
struct
  open Namespace
  type t = name_version
  let compare (n1, v1) (n2, v2) = 
    let c = name_compare n1 n2 in
      if c = 0 then
        compare v1 v2
      else
        c
end

module NV_map = BatMap.Make (NV_orderedtype)
module NV_set = BatSet.Make (NV_orderedtype)
