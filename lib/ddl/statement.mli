(** Data-definition AST: the statement universe.

    A DDL statement inspects the catalog itself rather than the rows of any
    table. The parser marks a DDL statement with the leading [:] sigil; the
    [Ast.program] wrapper bridges the DDL and pipeline universes at parse time,
    and the REPL dispatches on the wrapper to call {!Ddl_executor}.

    Today's only constructor is [List_tables]; the table-mutation forms
    ([:create table], [:drop table]) and the introspection form ([:describe])
    have all been retired in favour of pipe-form operators carried by the {!Ast}
    universe.

    DDL does not pass through [Lower] / [Translate] / [Physical] / [Eval] —
    those layers carry no knowledge of DDL. The REPL hands the statement
    straight to {!Ddl_executor.execute_read}. *)

type t =
  | List_tables
      (** [List_tables] is the surface form [:list tables]. Returns every table
          name bound in the catalog, in cursor (byte-sorted) order. Carries no
          body — the empty surface form is the whole statement. *)

type read_result =
  | Listed of string list
      (** A read DDL statement's outcome. [Listed names] is the result of
          [List_tables]: every table name from the catalog, in cursor
          (byte-sorted) order. *)
