(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

module SharedMemory = Hack_parallel.Std.SharedMem

let unsafe_little_endian_representation ~key =
  (* Ensure that key is a well-formed digest. *)
  Digest.to_hex key
  |> Digest.from_hex
  |> fun digest ->
  assert (Digest.equal digest key);

  (* Mimic what hack_parallel does, which is cast a key to a uint64_t pointer and dereference. This
     code is not portable by any means. *)
  let rec compute_little_endian accumulator index =
    let accumulator =
      Int64.mul accumulator (Int64.of_int 256) |> Int64.add (Int64.of_int (Char.code key.[index]))
    in
    if index = 0 then
      accumulator
    else
      compute_little_endian accumulator (index - 1)
  in
  (* Take the first 8 bytes in reverse order. *)
  compute_little_endian Int64.zero 7


type decodable = ..

type decoding_error =
  [ `Malformed_key
  | `Unknown_type
  | `Decoder_failure of exn
  ]

let registry = Hashtbl.create 13

let register prefix decoder =
  let prefix = Prefix.make_key prefix "" in
  assert (not (Hashtbl.mem registry prefix));
  Hashtbl.add registry prefix decoder


let decode ~key ~value =
  match String.index key '$' with
  | exception Not_found -> Result.Error `Malformed_key
  | dollar -> (
      let prefix_size = dollar + 1 in
      let prefix = String.sub key 0 prefix_size in
      match Hashtbl.find registry prefix with
      | exception Not_found -> Result.Error `Unknown_type
      | decoder -> (
          let key = String.sub key prefix_size (String.length key - prefix_size) in
          match decoder key value with
          | result -> Result.Ok result
          | exception exn -> Result.Error (`Decoder_failure exn) ) )


module type KeyType = sig
  include SharedMem.UserKeyType

  type out

  val from_string : string -> out
end

module type ValueType = sig
  include Value.Type

  val unmarshall : string -> t
end

module Register (Key : KeyType) (Value : ValueType) () : sig
  type decodable += Decoded of Key.out * Value.t option

  val serialize_key : Key.t -> string

  val hash_of_key : Key.t -> string

  val compute_hashes_to_keys : keys:Key.t list -> string Core.String.Map.t
end = struct
  (* Register decoder *)
  type decodable += Decoded of Key.out * Value.t option

  let () =
    let decode key value =
      let value =
        try Some (Value.unmarshall value) with
        | _ -> None
      in
      Decoded (Key.from_string key, value)
    in
    register Value.prefix decode


  let serialize_key key = Key.to_string key |> Prefix.make_key Value.prefix |> Base64.encode_exn

  let hash_of_key key =
    key
    |> Key.to_string
    |> Prefix.make_key Value.prefix
    |> Digest.string
    |> (fun key -> unsafe_little_endian_representation ~key)
    |> Int64.to_string


  let compute_hashes_to_keys ~keys =
    let add map key = Core.Map.set map ~key:(hash_of_key key) ~data:(serialize_key key) in
    Core.List.fold keys ~init:Core.String.Map.empty ~f:add
end

module NoCache (Key : KeyType) (Value : ValueType) : sig
  type decodable += Decoded of Key.out * Value.t option

  val serialize_key : Key.t -> string

  val hash_of_key : Key.t -> string

  val compute_hashes_to_keys : keys:Key.t list -> string Core.String.Map.t

  include
    SharedMemory.NoCache
      with type t = Value.t
       and type key = Key.t
       and module KeySet = Set.Make(Key)
       and module KeyMap = MyMap.Make(Key)
end = struct
  include Register (Key) (Value) ()

  include SharedMemory.NoCache (Key) (Value)
end

module WithCache (Key : KeyType) (Value : ValueType) : sig
  type decodable += Decoded of Key.out * Value.t option

  val serialize_key : Key.t -> string

  val hash_of_key : Key.t -> string

  val compute_hashes_to_keys : keys:Key.t list -> string Core.String.Map.t

  include
    SharedMemory.WithCache
      with type t = Value.t
       and type key = Key.t
       and module KeySet = Set.Make(Key)
       and module KeyMap = MyMap.Make(Key)
end = struct
  include Register (Key) (Value) ()

  include SharedMemory.WithCache (Key) (Value)
end

type bytes = int

type configuration = {
  heap_handle: Hack_parallel.Std.SharedMem.handle;
  minor_heap_size: bytes;
}

let configuration : configuration option ref = ref None

let initial_heap_size = 4096 * 1024 * 1024 (* 4 GB *)

let worker_garbage_control =
  { (Gc.get ()) with Gc.minor_heap_size = 256 * 1024; (* 256 KB *)
                                                      space_overhead = 100 }


let initialize log_level =
  match !configuration with
  | None ->
      let minor_heap_size = 4 * 1024 * 1024 in
      (* 4 MB *)
      let space_overhead = 50 in
      (* Only sets the GC for the master process - the parallel workers use GC settings with less
         overhead. *)
      Gc.set { (Gc.get ()) with Gc.minor_heap_size; space_overhead };
      let shared_mem_config =
        {
          SharedMemory.global_size = initial_heap_size;
          heap_size = initial_heap_size;
          dep_table_pow = 19;
          hash_table_pow = 22;
          shm_dirs = ["/dev/shm"; "/pyre"];
          shm_min_avail = 1024 * 1024 * 512;
          (* 512 MB *)
          log_level;
        }
      in
      let heap_handle = SharedMemory.init shared_mem_config in
      configuration := Some { heap_handle; minor_heap_size };
      { heap_handle; minor_heap_size }
  | Some configuration -> configuration


let get_heap_handle { Configuration.Analysis.debug; _ } =
  let log_level =
    if debug then
      1
    else
      0
  in
  let { heap_handle; _ } = initialize log_level in
  heap_handle


let report_statistics () =
  Measure.print_stats ();
  Measure.print_distributions ()


let save_shared_memory ~path =
  SharedMemory.collect `aggressive;
  SharedMem.save_table path


let load_shared_memory ~path = SharedMem.load_table path

module SingletonKey = struct
  type t = int

  let to_string = Core.Int.to_string

  let compare = Core.Int.compare

  type out = int

  let from_string = Core.Int.of_string

  let key = 0
end

module type SerializableValueType = sig
  type t

  module Serialized : ValueType

  val serialize : t -> Serialized.t

  val deserialize : Serialized.t -> t
end

module Serializer (Value : SerializableValueType) = struct
  module Table = NoCache (SingletonKey) (Value.Serialized)

  let store table =
    let data = Value.serialize table in
    Table.add SingletonKey.key data


  let load () =
    let table = Table.find_unsafe SingletonKey.key |> Value.deserialize in
    Table.remove_batch (Table.KeySet.singleton SingletonKey.key);
    table
end

open Core

module Dependency = struct
  type t = int

  let compare = compare_int

  let sexp_of_t = sexp_of_int

  let t_of_sexp = int_of_sexp

  let make v =
    let mask = (1 lsl 31) - 1 in
    Hashtbl.hash v land mask
end

module DependencySet = Core.Set.Make (Dependency)

module DependencyGraph = struct
  external hh_add_dep : int -> unit = "hh_add_dep"

  external hh_get_dep : int -> int list = "hh_get_dep"

  external hh_get_dep_sqlite : int -> int list = "hh_get_dep_sqlite"

  external hh_allow_dependency_table_reads : bool -> bool = "hh_allow_dependency_table_reads"

  external hh_assert_allow_dependency_table_reads
    :  unit ->
    unit
    = "hh_assert_allow_dependency_table_reads"

  let hh_add_dep x = WorkerCancel.with_worker_exit (fun () -> hh_add_dep x)

  let hh_get_dep x = WorkerCancel.with_worker_exit (fun () -> hh_get_dep x)

  let add x y = hh_add_dep ((x lsl 31) lor y)

  let get x =
    hh_assert_allow_dependency_table_reads ();
    let deps = DependencySet.empty in
    let deps = List.fold_left ~init:deps ~f:DependencySet.add (hh_get_dep x) in
    let deps = List.fold_left ~init:deps ~f:DependencySet.add (hh_get_dep_sqlite x) in
    deps
end

(* This is not currently used, but I'd like to keep it in the module for
   documentation/discoverability purposes *)
let _ = DependencyGraph.hh_allow_dependency_table_reads

module DependencyDecoder = struct
  module IntegerKey = struct
    type t = int

    let to_string = Int.to_string

    let compare = Int.compare

    type out = int

    let from_string = Int.of_string
  end

  module StringValue = struct
    type t = string

    let prefix = Prefix.make ()

    let description = "Dependency Decoder"

    (* Strings are not marshalled by shared memory *)
    let unmarshall value = value
  end

  include WithCache (IntegerKey) (StringValue)

  let get_unsafe hash = get hash |> fun optional -> Option.value_exn optional
end

let add_dependency ~table ~key file =
  let file_hash = Dependency.make file in
  DependencyDecoder.add file_hash file;
  DependencyGraph.add (Dependency.make (table, key)) file_hash


let get_dependents ~table ~key =
  DependencyGraph.get (Dependency.make (table, key))
  |> DependencySet.to_list
  |> List.map ~f:DependencyDecoder.get_unsafe
