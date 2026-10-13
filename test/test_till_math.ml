(* 蛇形格子计算与站位单测。 *)

open Stardew_mcp

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (
    incr failures;
    Printf.printf "FAIL - %s\n" name)

let show cells =
  String.concat "; " (List.map (fun (x, y) -> Printf.sprintf "(%d,%d)" x y) cells)

let eq_cells name got want =
  check (Printf.sprintf "%s [%s]" name (show got)) (got = want)

let () =
  (* 水平 1x1 *)
  eq_cells "h 1x1"
    (Farm.snake_cells ~start_x:5 ~start_y:5 ~rows:1 ~length:1 ~direction:Horizontal ())
    [ (5, 5) ];
  (* 水平 1 行 3 格 *)
  eq_cells "h 1x3"
    (Farm.snake_cells ~start_x:3 ~start_y:2 ~rows:1 ~length:3 ~direction:Horizontal ())
    [ (3, 2); (4, 2); (5, 2) ];
  (* 水平 2 行 2 格：第二行反向（蛇形） *)
  eq_cells "h 2x2 蛇形"
    (Farm.snake_cells ~start_x:3 ~start_y:2 ~rows:2 ~length:2 ~direction:Horizontal ())
    [ (3, 2); (4, 2); (4, 3); (3, 3) ];
  (* 水平 3 行 2 格：1=正向 2=反向 3=正向 *)
  eq_cells "h 3x2 蛇形"
    (Farm.snake_cells ~start_x:3 ~start_y:2 ~rows:3 ~length:2 ~direction:Horizontal ())
    [ (3, 2); (4, 2); (4, 3); (3, 3); (3, 4); (4, 4) ];
  (* 垂直 2 列 2 格：第二列反向 *)
  eq_cells "v 2x2 蛇形"
    (Farm.snake_cells ~start_x:3 ~start_y:2 ~rows:2 ~length:2 ~direction:Vertical ())
    [ (3, 2); (3, 3); (4, 3); (4, 2) ];
  (* 防御：rows/length 0 视为 1 *)
  eq_cells "h 0x0 视为 1x1"
    (Farm.snake_cells ~start_x:7 ~start_y:8 ~rows:0 ~length:0 ~direction:Horizontal ())
    [ (7, 8) ];
  (* 站位约定：目标格正上方 *)
  check "stand_pos (5,7)=(5,6)" (Farm.stand_pos (5, 7) = (5, 6));
  check "stand_pos (0,0)=(0,-1)" (Farm.stand_pos (0, 0) = (0, -1));
  (* 行蛇形排序：偶行 x 升序、奇行 x 降序 *)
  eq_cells "sort_row_snake"
    (Farm.sort_row_snake [ (5, 5); (3, 5); (4, 4); (2, 4); (6, 5) ])
    [ (2, 4); (4, 4); (6, 5); (5, 5); (3, 5) ];
  Printf.printf "\ntest_till_math: %s\n"
    (if !failures = 0 then "ALL PASS"
     else Printf.sprintf "%d FAILURE(S)" !failures);
  if !failures > 0 then exit 1
