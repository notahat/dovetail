(** Callback types for threading the evaluator's recursion into the per-operator
    modules.

    An operator that must evaluate a sub-plan can't call {!Eval.eval} directly:
    {!Eval} depends on the operator modules, so the reverse dependency would be
    a compile-time module cycle. Instead {!Eval} hands the operator one of these
    recursors as a parameter. This module holds only the types, so it depends on
    neither {!Eval} nor the operator modules. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term
module Relation = Dovetail_core.Relation

type ('perm, 'a) eval =
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
  constraint 'perm = [< `Read | `Write > `Read ]
(** The full-term recursor: evaluates a sub-plan and hands the consumer the
    resulting [Term.t]. Operators that branch on non-relation term arms
    (unqualify, tables) take this form. *)

type ('perm, 'a) eval_relation =
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  Plan.Physical.t ->
  ([ `Set | `Bag ] Relation.t -> 'a) ->
  'a
  constraint 'perm = [< `Read | `Write > `Read ]
(** The relation-form recursor: evaluates a relational sub-plan and hands the
    consumer its [Relation.t] directly. Most operators take this form. *)
