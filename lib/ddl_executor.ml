module Ddl = Dovetail_ddl

let execute_read environment transaction :
    Ddl.Statement.t -> Ddl.Statement.read_result = function
  | List_tables -> Listed (Catalog.list_table_names environment transaction)
  | Drop_table _ ->
      (* Routing invariant: Drop_table is a write statement; the REPL
         must classify and route it to execute_write. *)
      assert false

(* Drop both halves of [table_name] (catalog entry and storage subDB)
   inside the caller's write transaction. The catalog-aware "no such
   table" check happens here, sharing the write transaction so it cannot
   race against a concurrent create. The storage subDB is dropped before
   the catalog entry so an interrupted commit leaves no orphan rows
   behind under a still-present catalog binding -- LMDB makes the pair
   atomic in normal operation, but the ordering is defensive against any
   future code path that splits the commit boundary. *)
let drop_table environment transaction table_name : Ddl.Statement.write_result =
  (match Catalog.get environment transaction ~table_name with
  | Some _ -> ()
  | None ->
      failwith (Printf.sprintf "DDL: drop table %S: no such table" table_name));
  Storage.drop_map environment transaction
    ~name:(Catalog.table_subdb_name table_name);
  Catalog.delete environment transaction ~table_name;
  Dropped table_name

let execute_write environment transaction :
    Ddl.Statement.t -> Ddl.Statement.write_result = function
  | List_tables ->
      (* Routing invariant: List_tables is a read statement; the REPL
         must classify and route it to execute_read. *)
      assert false
  | Drop_table { table_name } -> drop_table environment transaction table_name
