type options = { show_physical : bool; environment_path : string }

let default_environment_path = "./dovetail-data"
let show_physical_flag = "--show-physical"

let parse arguments =
  let rec walk ~show_physical ~environment_path = function
    | [] ->
        let environment_path =
          Option.value environment_path ~default:default_environment_path
        in
        Ok { show_physical; environment_path }
    | argument :: rest when argument = show_physical_flag ->
        if show_physical then Error "duplicate --show-physical flag"
        else walk ~show_physical:true ~environment_path rest
    | path :: rest ->
        if Option.is_some environment_path then
          Error "multiple environment paths"
        else walk ~show_physical ~environment_path:(Some path) rest
  in
  walk ~show_physical:false ~environment_path:None arguments
