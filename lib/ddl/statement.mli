(** Data-definition AST: the statement universe.

    The DDL universe is empty -- every statement form ([:list tables],
    [:create table], [:drop table], [:describe]) has been retired in favour of
    pipe-form operators carried by {!Ast.t}. {!t} is uninhabited; the
    {!Ast.program} wrapper still carries a {!Ddl} arm pointing here for one more
    slice before the wrapper collapses to a bare pipeline. *)

type t = |
