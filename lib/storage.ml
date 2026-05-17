type environment = Lmdb.Env.t
type -'perm transaction = 'perm Lmdb.Txn.t constraint 'perm = [< `Read | `Write ]
type map = (string, string, [ `Uni ]) Lmdb.Map.t

let open_environment ?(map_size = 1 lsl 30) ?(max_maps = 4096) path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755;
  Lmdb.Env.create Lmdb.Rw ~map_size ~max_maps path

let close_environment = Lmdb.Env.close

(* [Lmdb.Txn.go] returns [None] only when the callback calls [Lmdb.Txn.abort];
   we never do, so the [None] arms below are internal invariants. *)
let with_read_transaction environment f =
  match Lmdb.Txn.go Lmdb.Ro environment f with
  | Some result -> result
  | None -> assert false

let with_write_transaction environment f =
  match Lmdb.Txn.go Lmdb.Rw environment f with
  | Some result -> result
  | None -> assert false

let open_map environment transaction ~name =
  match
    Lmdb.Map.open_existing Nodup ~key:Lmdb.Conv.string ~value:Lmdb.Conv.string
      ~txn:transaction ~name environment
  with
  | map -> Some map
  | exception Lmdb.Not_found -> None

let create_map environment transaction ~name =
  Lmdb.Map.create Nodup ~key:Lmdb.Conv.string ~value:Lmdb.Conv.string
    ~txn:transaction ~name environment

let put map transaction ~key ~value =
  Lmdb.Map.set map ~txn:transaction key value

let get map transaction ~key =
  match Lmdb.Map.get map ~txn:transaction key with
  | v -> Some v
  | exception Lmdb.Not_found -> None

(* The lmdb binding raises [Lmdb.Not_found] when the key is absent; we
   swallow it to honour the no-op-on-absent contract. *)
let delete map transaction ~key =
  match Lmdb.Map.remove map ~txn:transaction key with
  | () -> ()
  | exception Lmdb.Not_found -> ()

(* Open a cursor for the duration of [continue] and expose a one-shot
   sequence that pulls each pair lazily.

   The dispenser walks a three-state machine: [`Before_first] is the
   initial state and triggers a [Cursor.first] on the first pull;
   [`Active] means at least one pair has been yielded and subsequent
   pulls use [Cursor.next]; [`Exhausted] is terminal, reached when
   either cursor call raises [Lmdb.Not_found], and pins [None] for the
   rest of the sequence. The lmdb package doesn't expose a cursor
   reset, so re-iteration is not supported -- once [`Exhausted], that's
   it. *)
let with_iter_seq map transaction continue =
  let transaction = (transaction :> [ `Read ] Lmdb.Txn.t) in
  Lmdb.Cursor.go Lmdb.Ro ~txn:transaction map (fun cursor ->
      let state = ref `Before_first in
      let next_pair () =
        match !state with
        | `Exhausted -> None
        | `Before_first -> (
            match Lmdb.Cursor.first cursor with
            | pair ->
                state := `Active;
                Some pair
            | exception Lmdb.Not_found ->
                state := `Exhausted;
                None)
        | `Active -> (
            match Lmdb.Cursor.next cursor with
            | pair -> Some pair
            | exception Lmdb.Not_found ->
                state := `Exhausted;
                None)
      in
      continue (Seq.of_dispenser next_pair))
