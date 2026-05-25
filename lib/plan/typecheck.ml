module Catalog = Dovetail_core.Catalog

type error = |

let render (error : error) : string = match error with _ -> .
let typecheck ~catalog:_ logical = Ok logical
