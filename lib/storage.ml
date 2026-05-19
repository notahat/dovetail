(* Temporary migration shim for slice 16 step 2b.
   Consumers will reach this module via [Dovetail_storage.Engine] once
   they have been rewritten; this shim keeps the old [Dovetail.Storage]
   name resolving until then. Delete in step 2b. *)
include Dovetail_storage.Engine
