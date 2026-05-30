type options = {
  show_logical : bool;
  show_physical : bool;
  demo_data : bool;
  sql : bool;
  environment_path : string;
}

let default_environment_path = "./dovetail-data"
let show_logical_flag = "--show-logical"
let show_physical_flag = "--show-physical"
let demo_data_flag = "--demo-data"
let sql_flag = "--sql"

let parse arguments =
  let rec walk ~show_logical ~show_physical ~demo_data ~sql ~environment_path =
    function
    | [] ->
        let environment_path =
          Option.value environment_path ~default:default_environment_path
        in
        Ok { show_logical; show_physical; demo_data; sql; environment_path }
    | argument :: rest when argument = show_logical_flag ->
        if show_logical then Error "duplicate --show-logical flag"
        else
          walk ~show_logical:true ~show_physical ~demo_data ~sql
            ~environment_path rest
    | argument :: rest when argument = show_physical_flag ->
        if show_physical then Error "duplicate --show-physical flag"
        else
          walk ~show_logical ~show_physical:true ~demo_data ~sql
            ~environment_path rest
    | argument :: rest when argument = demo_data_flag ->
        if demo_data then Error "duplicate --demo-data flag"
        else
          walk ~show_logical ~show_physical ~demo_data:true ~sql
            ~environment_path rest
    | argument :: rest when argument = sql_flag ->
        if sql then Error "duplicate --sql flag"
        else
          walk ~show_logical ~show_physical ~demo_data ~sql:true
            ~environment_path rest
    | path :: rest ->
        if Option.is_some environment_path then
          Error "multiple environment paths"
        else
          walk ~show_logical ~show_physical ~demo_data ~sql
            ~environment_path:(Some path) rest
  in
  walk ~show_logical:false ~show_physical:false ~demo_data:false ~sql:false
    ~environment_path:None arguments
