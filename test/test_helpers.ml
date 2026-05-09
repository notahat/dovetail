(** Shared test fixtures.

    These helpers set up scope-bound resources -- temp directories and LMDB
    environments -- in the {!Fun.protect} style, guaranteeing cleanup whether
    the body returns normally or raises. *)

open Dovetail

(** Recursively remove [path]. Uses [lstat] so symlinks are unlinked rather than
    followed. Raises through any underlying [Unix] error. *)
let rec remove_recursive path =
  match (Unix.lstat path).st_kind with
  | S_DIR ->
      Sys.readdir path
      |> Array.iter (fun entry -> remove_recursive (Filename.concat path entry));
      Unix.rmdir path
  | _ -> Unix.unlink path

(** [with_temp_dir f] creates a fresh, uniquely-named temp directory, runs [f]
    with its path, and removes the directory on exit. The directory name
    includes the pid and a random number so concurrent test runs don't collide.

    Cleanup is unconditional: it runs whether [f] returns normally or raises,
    via {!Fun.protect}. *)
let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let unique_name =
    Printf.sprintf "dovetail-test-%d-%d" (Unix.getpid ()) (Random.bits ())
  in
  let directory = Filename.concat base unique_name in
  Unix.mkdir directory 0o755;
  Fun.protect
    ~finally:(fun () -> remove_recursive directory)
    (fun () -> f directory)

(** [with_environment path f] opens an LMDB environment at [path], runs
    [f environment], and closes the environment on exit. *)
let with_environment path f =
  let environment = Storage.open_environment path in
  Fun.protect
    ~finally:(fun () -> Storage.close_environment environment)
    (fun () -> f environment)
