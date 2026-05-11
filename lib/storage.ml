type environment = Lmdb.Env.t
type -'perm transaction = 'perm Lmdb.Txn.t constraint 'perm = [< `Read | `Write ]
type map = (string, string, [ `Uni ]) Lmdb.Map.t

let open_environment ?(map_size = 1 lsl 30) ?(max_maps = 4096) path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755;
  Lmdb.Env.create Lmdb.Rw ~map_size ~max_maps path

let close_environment = Lmdb.Env.close

let with_read_transaction environment f =
  match Lmdb.Txn.go Lmdb.Ro environment f with
  | Some x -> x
  | None -> failwith "Storage.with_read_transaction: transaction was aborted"

let with_write_transaction environment f =
  match Lmdb.Txn.go Lmdb.Rw environment f with
  | Some x -> x
  | None -> failwith "Storage.with_write_transaction: transaction was aborted"

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

(* Open a cursor for the duration of [continue] and expose a one-shot
   sequence that pulls each pair lazily. The [exhausted] flag closes the
   seq once it has either run to its end or been re-entered after
   exhaustion -- the lmdb package doesn't expose a cursor reset, so
   re-iteration is not supported. *)
let with_iter_seq map transaction continue =
  let transaction = (transaction :> [ `Read ] Lmdb.Txn.t) in
  Lmdb.Cursor.go Lmdb.Ro ~txn:transaction map (fun cursor ->
      let exhausted = ref false in
      let started = ref false in
      let next_pair () =
        if !exhausted then None
        else
          let step =
            if !started then
              match Lmdb.Cursor.next cursor with
              | pair -> Some pair
              | exception Lmdb.Not_found -> None
            else (
              started := true;
              match Lmdb.Cursor.first cursor with
              | pair -> Some pair
              | exception Lmdb.Not_found -> None)
          in
          (match step with None -> exhausted := true | Some _ -> ());
          step
      in
      continue (Seq.of_dispenser next_pair))
