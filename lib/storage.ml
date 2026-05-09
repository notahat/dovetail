type env = Lmdb.Env.t

type -'perm txn = 'perm Lmdb.Txn.t constraint 'perm = [< `Read | `Write ]

type map = (string, string, [ `Uni ]) Lmdb.Map.t

let open_env ?(map_size = 1 lsl 30) ?(max_maps = 4096) path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755;
  Lmdb.Env.create Lmdb.Rw ~map_size ~max_maps path

let close_env = Lmdb.Env.close

let with_read_txn env f =
  match Lmdb.Txn.go Lmdb.Ro env f with
  | Some x -> x
  | None -> failwith "Storage.with_read_txn: transaction was aborted"

let with_write_txn env f =
  match Lmdb.Txn.go Lmdb.Rw env f with
  | Some x -> x
  | None -> failwith "Storage.with_write_txn: transaction was aborted"

let open_map env txn ~name =
  match
    Lmdb.Map.open_existing Nodup ~key:Lmdb.Conv.string
      ~value:Lmdb.Conv.string ~txn ~name env
  with
  | map -> Some map
  | exception Lmdb.Not_found -> None

let create_map env txn ~name =
  Lmdb.Map.create Nodup ~key:Lmdb.Conv.string ~value:Lmdb.Conv.string ~txn
    ~name env

let put map txn ~key ~value = Lmdb.Map.set map ~txn key value

let get map txn ~key =
  match Lmdb.Map.get map ~txn key with
  | v -> Some v
  | exception Lmdb.Not_found -> None

let iter_seq map txn =
  (* Cursor.go takes a perm-restricted txn matching its perm argument;
     contravariance lets a [`Read | `Write] txn be used as [`Read]. *)
  let txn = (txn :> [ `Read ] Lmdb.Txn.t) in
  Lmdb.Cursor.go Lmdb.Ro ~txn map (fun cursor ->
      let rec collect acc =
        match Lmdb.Cursor.next cursor with
        | pair -> collect (pair :: acc)
        | exception Lmdb.Not_found -> List.rev acc
      in
      match Lmdb.Cursor.first cursor with
      | pair -> List.to_seq (collect [ pair ])
      | exception Lmdb.Not_found -> Seq.empty)
