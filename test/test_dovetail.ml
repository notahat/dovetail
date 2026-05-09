let test_smoke () = Alcotest.(check pass) "smoke test passes" () ()

let () =
  Alcotest.run "dovetail"
    [ ("smoke", [ Alcotest.test_case "smoke" `Quick test_smoke ]) ]
