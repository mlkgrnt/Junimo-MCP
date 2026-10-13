(** 农活工具的共用计算与编排原语。 *)

type direction = Horizontal | Vertical

let direction_of_string = function
  | "vertical" -> Vertical
  | _ -> Horizontal

(** 蛇形格子序列：rows 行 × length 格；行/列 index 为奇数的反向。
    水平：行沿 y 排、行内沿 x；垂直：列沿 x 排、列内沿 y。 *)
let snake_cells ~start_x ~start_y ~rows ~length ~direction () =
  let rows = max 1 rows and length = max 1 length in
  List.concat
    (List.init rows (fun r ->
         let rev = r mod 2 = 1 in
         List.init length (fun i ->
             let i = if rev then length - 1 - i else i in
             match direction with
             | Horizontal -> (start_x + i, start_y + r)
             | Vertical -> (start_x + r, start_y + i))))

(** 对格子 (tx,ty) 操作时的标准站位：正上方 (tx, ty-1)（面朝下 2）。
    这是全项目统一操作姿态（mod 端 farmhand 吸 GrabTile 有偏移，原作者实测结论）。 *)
let stand_pos (tx, ty) = (tx, ty - 1)

(** 把格子列表按"逐行蛇形"排序（水浇扫描后整理用）：
    按 y 分组升序；偶数行内 x 升序、奇数行内 x 降序。 *)
let sort_row_snake (cells : (int * int) list) : (int * int) list =
  List.stable_sort
    (fun (x1, y1) (x2, y2) ->
      if y1 <> y2 then compare y1 y2
      else if y1 mod 2 = 0 then compare x1 x2
      else compare x2 x1)
    cells
