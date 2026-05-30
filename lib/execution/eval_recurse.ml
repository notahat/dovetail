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

type ('perm, 'a) eval_relation =
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  Plan.Physical.t ->
  ([ `Set | `Bag ] Relation.t -> 'a) ->
  'a
  constraint 'perm = [< `Read | `Write > `Read ]
