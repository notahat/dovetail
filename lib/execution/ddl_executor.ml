module Ddl = Dovetail_ddl
module Schema = Dovetail_core.Schema
module Storage = Dovetail_storage

(* Look up [table_name] in the catalog and return its schema wrapped in
   [Described]. The catalog-aware "no such table" check happens here so
   the user-facing error names the operation they typed; the [DDL:
   describe ...] prefix matches the slice-13 reframe convention. *)
let describe_table environment transaction table_name :
    Ddl.Statement.read_result =
  match Storage.Catalog.get environment transaction ~table_name with
  | Some schema -> Described { table_name; schema }
  | None ->
      failwith (Printf.sprintf "DDL: describe %S: no such table" table_name)

let execute_read environment transaction :
    Ddl.Statement.t -> Ddl.Statement.read_result = function
  | List_tables ->
      Listed (Storage.Catalog.list_table_names environment transaction)
  | Drop_table _ | Create_table _ ->
      (* Routing invariant: Drop_table and Create_table are write
         statements; the REPL must classify and route them to
         execute_write. *)
      assert false
  | Describe { table_name } -> describe_table environment transaction table_name

(* Drop both halves of [table_name] (catalog entry and storage subDB)
   inside the caller's write transaction. The catalog-aware "no such
   table" check happens here, sharing the write transaction so it cannot
   race against a concurrent create. The storage subDB is dropped before
   the catalog entry so an interrupted commit leaves no orphan rows
   behind under a still-present catalog binding -- LMDB makes the pair
   atomic in normal operation, but the ordering is defensive against any
   future code path that splits the commit boundary. *)
let drop_table environment transaction table_name : Ddl.Statement.write_result =
  (match Storage.Catalog.get environment transaction ~table_name with
  | Some _ -> ()
  | None ->
      failwith (Printf.sprintf "DDL: drop table %S: no such table" table_name));
  Storage.Engine.drop_map environment transaction
    ~name:(Storage.Catalog.table_subdb_name table_name);
  Storage.Catalog.delete environment transaction ~table_name;
  Dropped table_name

(* Build the [Schema.t] that a [Create_table] statement should write into
   the catalog. The DDL surface has no qualifier on its [field] type, so
   the executor stamps [Some table_name] onto every field -- this is the
   shape the read path expects, and the rest of the catalog (including
   tests' low-level seeders) matches it. Field order and primary-key
   order are preserved exactly as the user typed them;
   [Statement.validate] is responsible for the structural checks
   (non-empty lists, no duplicates, PK columns drawn from the field
   list) and is expected to have run already. *)
let schema_of_create_fields ~table_name (fields : Ddl.Statement.field list)
    ~primary_key : Schema.t =
  let schema_fields =
    List.map
      (fun (field : Ddl.Statement.field) : Schema.field ->
        { name = field.name; kind = field.kind; qualifier = Some table_name })
      fields
  in
  { fields = schema_fields; primary_key }

(* Create both halves of [table_name] (catalog entry and storage subDB)
   inside the caller's write transaction. The catalog-aware "table
   already exists" check happens here, sharing the write transaction so
   it cannot race against a concurrent create. The storage subDB is
   created before the catalog entry; if anything raises in between, the
   transaction aborts and rolls both halves back. *)
let create_table environment transaction ~table_name ~fields ~primary_key :
    Ddl.Statement.write_result =
  (match Storage.Catalog.get environment transaction ~table_name with
  | None -> ()
  | Some _ ->
      failwith
        (Printf.sprintf "DDL: create table %S: table already exists" table_name));
  let schema = schema_of_create_fields ~table_name fields ~primary_key in
  let _map =
    Storage.Engine.create_map environment transaction
      ~name:(Storage.Catalog.table_subdb_name table_name)
  in
  Storage.Catalog.put environment transaction ~table_name schema;
  Created table_name

let execute_write environment transaction :
    Ddl.Statement.t -> Ddl.Statement.write_result = function
  | List_tables | Describe _ ->
      (* Routing invariant: List_tables and Describe are read statements;
         the REPL must classify and route them to execute_read. *)
      assert false
  | Drop_table { table_name } -> drop_table environment transaction table_name
  | Create_table { table_name; fields; primary_key } ->
      create_table environment transaction ~table_name ~fields ~primary_key
