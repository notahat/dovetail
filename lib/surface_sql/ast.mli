(** Surface AST for the SQL query language.

    The AST is the structure produced by the {!Parser} from a textual SQL
    statement. It mirrors the surface syntax: every node corresponds to
    something the user typed, and nothing more. {!Lower} converts the AST into a
    logical plan, where the operators take their meaning from relational algebra
    rather than SQL keywords.

    This is the SQL surface's own AST, kept deliberately separate from the
    relational-algebra surface's AST. The two surfaces share only [core] and
    [plan]; the structural overlap with the RA surface's expression sublanguage
    is duplicated rather than shared until a third surface or real drift makes
    extraction pay. *)

module Scalar = Dovetail_core.Scalar

type column_reference = { qualifier : string option; name : string }
(** A reference to a column. [qualifier] is always [None] in the current slice:
    only bare column names are accepted, and [users.id] is a parse error. The
    field is carried so the shape is ready for qualified references when joins
    arrive. *)

(** A comparison operator in a predicate. [NotEqual] is produced by both the
    [<>] and [!=] surface spellings. *)
type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual

(** A WHERE predicate. The grammar mirrors the relational-algebra surface's
    expression sublanguage: a comparison between two operands, the boolean
    connectives [AND] / [OR] / [NOT], and atoms that are literals or bare column
    references. A bare boolean column or [TRUE] / [FALSE] stands alone as a
    predicate; the kind check (predicate position must be boolean) happens at
    the logical layer, not here. *)
type expression =
  | Literal of Scalar.value
  | Column of column_reference
  | Compare of { left : expression; op : comparison_op; right : expression }
  | And of expression * expression
  | Or of expression * expression
  | Not of expression

type select_list =
  | All
      (** The [*] select list: keep every column of the FROM relation, in its
          natural order. *)
  | Columns of column_reference list
      (** A [a, b, c] select list: keep the named columns, in the order written.
          Columns are bare-only in the current slice; the list is non-empty. *)

type t =
  | Select of {
      select_list : select_list;
      from : string;
      where : expression option;
    }
      (** [Select { select_list; from; where }] is the surface form
          [SELECT <select_list> FROM <from> [WHERE <where>]]. [from] is the bare
          table name as written; qualified names and multiple tables arrive with
          joins. [where] is [None] when no WHERE clause is present. *)
