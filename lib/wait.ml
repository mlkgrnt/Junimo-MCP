(** 等待器：轮询与动作结算。 *)

let sleep_ms ms = if ms > 0 then Unix.sleepf (float_of_int ms /. 1000.)

(** 动作结算延迟：/tool /use /interact /key 之后固定等待（原作 TOOL_DELAY 0.45~0.55s）。 *)
let settle () = sleep_ms 550

(** 轮询直到 f() 为 true 或超时。返回是否成功。 *)
let poll_until ?(timeout = 30.0) ?(interval = 0.25) (f : unit -> bool) : bool =
  let t0 = Unix.gettimeofday () in
  let rec loop () =
    if f () then true
    else if Unix.gettimeofday () -. t0 > timeout then false
    else (
      sleep_ms (int_of_float (interval *. 1000.));
      loop ())
  in
  loop ()

(** 从 /move 响应 {"message": "Moving to (x,y), steps=N"} 中解析 N。
    解析不到返回 None。 *)
let move_steps (resp : Yojson.Safe.t) : int option =
  let msg =
    match resp with
    | `Assoc f -> (
        match List.assoc_opt "message" f with Some (`String s) -> s | _ -> "")
    | _ -> ""
  in
  let n = String.length msg in
  let rec find i =
    if i + 6 > n then None
    else if String.sub msg i 6 = "steps=" then Some (i + 6)
    else find (i + 1)
  in
  match find 0 with
  | None -> None
  | Some j ->
      let k = ref j in
      while !k < n && msg.[!k] >= '0' && msg.[!k] <= '9' do
        incr k
      done;
      if !k > j then
        try Some (int_of_string (String.sub msg j (!k - j))) with _ -> None
      else None

(** 判定 /move 是否落入了 mod 的"直线穿墙"回退。
   回退特征：返回 steps=1（BFS 没找到路，把目标直接塞进队列），
    而实际距离 > 1（会无视障碍、甚至飘出地图边界——M3 实测教训）。
    距离 ≤1 时 steps=1 是正常相邻移动。 *)
let linear_fallback (resp : Yojson.Safe.t) ~(dist : int) : bool =
  match move_steps resp with Some 1 -> dist > 1 | _ -> false

type move_result = Arrived | Timeout | No_path

(** 发送 /move 并等待到达。
    到达判定（PRD 4.5）：起步先等 300ms（寻路 race），再轮询直到
    「连续 2 次 isMoving=false 且切比雪夫距离 ≤1」。
    超时自动 /stop；检测到直线回退（No_path）也立即 /stop 并放弃。 *)
let move_to ?(timeout = 30.0) ~x ~y () : Game_state.t * move_result =
  let dist =
    match (Game_state.fetch ()).player with
    | Some p -> max (abs (p.px - x)) (abs (p.py - y))
    | None -> 0
  in
  let resp = Game_api.move ~x ~y () in
  if linear_fallback resp ~dist then begin
    (try ignore (Game_api.stop ()) with _ -> ());
    (Game_state.fetch (), No_path)
  end
  else begin
    sleep_ms 300;
    let consecutive = ref 0 in
    let arrived =
      poll_until ~timeout ~interval:0.25 (fun () ->
          match (Game_state.fetch ()).player with
          | Some p ->
              let cheb = max (abs (p.px - x)) (abs (p.py - y)) in
              if (not p.is_moving) && cheb <= 1 then (
                incr consecutive;
                !consecutive >= 2)
              else (
                consecutive := 0;
                false)
          | None -> false)
    in
    if arrived then (Game_state.fetch (), Arrived)
    else begin
      (try ignore (Game_api.stop ()) with _ -> ());
      (Game_state.fetch (), Timeout)
    end
  end

(** 长距分段接力（M4）：mod 的 BFS 有 500 步上限，长距 /move 必然回退直线穿墙。
    策略：把路程拆成 ≤seg 格的段，每段用 move_to（自带回退防护）走；
    - 某段失败但位置有前进 → 继续下一段；
    - 某段失败且原地不动 → 缩减段长重试（最多 2 次缩段）；
    - 仍失败 / 总超时 / 迭代超限 → 返回失败。
    全程走完即精确到达（末段就是目标格本身）。 *)
let travel_to ?(timeout = 90.0) ?(seg = 10) ~x ~y () : Game_state.t * move_result =
  let t0 = Unix.gettimeofday () in
  let cur_seg = ref (max 2 seg) in
  let shrinks = ref 0 in
  let iterations = ref 0 in
  let outcome = ref None in
  while !outcome = None do
    incr iterations;
    let st = Game_state.fetch () in
    (match st.player with
    | None -> outcome := Some (st, No_path)
    | Some p ->
        let dx = x - p.px and dy = y - p.py in
        let cheb = max (abs dx) (abs dy) in
        if cheb <= 1 then outcome := Some (st, Arrived)
        else if Unix.gettimeofday () -. t0 > timeout then
          outcome := Some (st, Timeout)
        else if !iterations > 100 then outcome := Some (st, No_path)
        else begin
          let s = !cur_seg in
          let wx =
            p.px + (if abs dx > s then (if dx > 0 then s else -s) else dx)
          in
          let wy =
            p.py + (if abs dy > s then (if dy > 0 then s else -s) else dy)
          in
          let before = (p.px, p.py) in
          let _, r = move_to ~timeout:(min 20.0 (timeout /. 2.)) ~x:wx ~y:wy () in
          match r with
          | Arrived -> () (* 下一段 *)
          | (No_path | Timeout) as bad ->
              let moved =
                match (Game_state.fetch ()).player with
                | Some q -> (q.px, q.py) <> before
                | None -> false
              in
              if moved then () (* 有进展，继续 *)
              else if !shrinks < 2 then begin
                incr shrinks;
                cur_seg := max 3 (!cur_seg / 2)
              end
              else outcome := Some (Game_state.fetch (), bad)
        end)
  done;
  match !outcome with Some r -> r | None -> (Game_state.fetch (), No_path)
