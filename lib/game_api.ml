(** NagiBridge 端点语义封装。

    职责：URL 拼接、HTTP 调用、{"error": ...} 响应转 Api_error。
    M1 只需要只读端点；动作端点在 M2 起逐步加入。 *)

exception Api_error of string
(* 游戏侧语义错误，如 "World not ready"，或其它的 {"error": ...} *)

let base () = Config.api_url ()

(* 识别 mod 的标准错误响应 {"error": "..."} 并转为异常 *)
let check j =
  match j with
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`String msg) -> raise (Api_error msg)
      | _ -> j)
  | _ -> j

(* ---------- 只读端点 ---------- *)

let status () = Http_client.get_json (base () ^ "/status") |> check
let state () = Http_client.get_json (base () ^ "/state") |> check

let surroundings ?(radius = 10) () =
  let r = max 1 (min 30 radius) in
  Http_client.get_json (Printf.sprintf "%s/surroundings?radius=%d" (base ()) r)
  |> check

let menu () = Http_client.get_json (base () ^ "/menu") |> check

(* ---------- 动作端点（M2 起使用；先放这里，测试覆盖时逐个打开） ---------- *)

let post_ep ?max_time path (body : Yojson.Safe.t) =
  Http_client.post_json_json ?max_time (base () ^ path) (Yojson.Safe.to_string body)
  |> check

let move ~x ~y () = post_ep "/move" (`Assoc [ ("x", `Int x); ("y", `Int y) ])

let stop () = post_ep "/stop" (`Assoc [])

let position ~x ~y () = post_ep "/position" (`Assoc [ ("x", `Int x); ("y", `Int y) ])

let face ~direction () = post_ep "/face" (`Assoc [ ("direction", `Int direction) ])

let warp ~location ?x ?y () =
  let fields =
    [ ("location", `String location) ]
    @ (match x with Some v -> [ ("x", `Int v) ] | None -> [])
    @ (match y with Some v -> [ ("y", `Int v) ] | None -> [])
  in
  post_ep "/warp" (`Assoc fields)

let tool ?(name = "current") () = post_ep "/tool" (`Assoc [ ("name", `String name) ])

let use_held () =
  (* 不做 check：/use 的 {"ok":false,"error":...} 是游戏侧校验结果
     （如 "Tile already tilled" / "Already watered"），交由调用方判断成败。
     连接层错误（curl 失败等）仍会在 Http_client 里抛出。 *)
  Http_client.post_json_json (base () ^ "/use") (Yojson.Safe.to_string (`Assoc []))

let interact () = post_ep "/interact" (`Assoc [])

let key ?(key = "confirm") ?(count = 1) () =
  post_ep "/key" (`Assoc [ ("key", `String key); ("count", `Int count) ])

let select ~name () = post_ep "/select" (`Assoc [ ("name", `String name) ])

let harvest ?(radius = 15) () =
  post_ep
    (Printf.sprintf "/harvest?radius=%d" (max 1 (min 50 radius)))
    (`Assoc [])

let refill () = post_ep "/refill" (`Assoc [])

(* ---------- v2 生计端点 ---------- *)

let sleep () = post_ep "/sleep" (`Assoc [])

let buy ?(quantity = 1) ~id () =
  post_ep "/buy" (`Assoc [ ("id", `String id); ("quantity", `Int quantity) ])

let sell ?(all = false) ?name () =
  let fields =
    [ ("all", `Bool all) ]
    @ (match name with Some n -> [ ("name", `String n) ] | None -> [])
  in
  post_ep "/sell" (`Assoc fields)

let chest ~x ~y () = post_ep "/chest" (`Assoc [ ("x", `Int x); ("y", `Int y) ])

let store ~x ~y ?name ?(keep_tools = true) () =
  let fields =
    [ ("x", `Int x); ("y", `Int y); ("keepTools", `Bool keep_tools) ]
    @ (match name with Some n -> [ ("name", `String n) ] | None -> [])
  in
  post_ep "/store" (`Assoc fields)

let map () = Http_client.get_json (base () ^ "/map") |> check

let pause () = post_ep "/pause" (`Assoc [])

let resume () = post_ep "/resume" (`Assoc [])

let menu_click ?option ?button ?x ?y () =
  let fields =
    (match option with Some v -> [ ("option", `Int v) ] | None -> [])
    @ (match button with Some v -> [ ("button", `String v) ] | None -> [])
    @ (match x with Some v -> [ ("x", `Int v) ] | None -> [])
    @ (match y with Some v -> [ ("y", `Int v) ] | None -> [])
  in
  post_ep "/menu/click" (`Assoc fields)

(* ---------- v3 端点（NagiBridge-Remix，2026-10-13） ---------- *)

(* query 参数用 percent-encode（只放行 unreserved；中文名转 %XX） *)
let url_encode s =
  let b = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' ->
          Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

(* 吃手持物（无参；不可食用返回 {ok:false,error:"当前物品不可食用（先 /select...）"}） *)
let eat () = post_ep "/eat" (`Assoc [])

let gift ~target ~item () =
  post_ep "/gift" (`Assoc [ ("target", `String target); ("item", `String item) ])

(* GET /friendship?npc=xx（返回 {ok, npc, points, hearts, giftsThisWeek, giftsToday, known}） *)
let friendship ~npc () =
  Http_client.get_json
    (Printf.sprintf "%s/friendship?npc=%s" (base ()) (url_encode npc))
  |> check

(* GET /find_npc?name=xx（全地图扫描，中英模糊匹配） *)
let find_npc ~name () =
  Http_client.get_json
    (Printf.sprintf "%s/find_npc?name=%s" (base ()) (url_encode name))
  |> check

let scan_chests () = Http_client.get_json (base () ^ "/scan_chests") |> check

let chest_take ~x ~y ?name ?slot ?count () =
  let fields =
    [ ("x", `Int x); ("y", `Int y) ]
    @ (match name with Some n -> [ ("name", `String n) ] | None -> [])
    @ (match slot with Some s -> [ ("slot", `Int s) ] | None -> [])
    @ (match count with Some c -> [ ("count", `Int c) ] | None -> [])
  in
  post_ep "/chest_take" (`Assoc fields)

let chest_take_list ~(items : (string * int option) list) () =
  let arr =
    List.map
      (fun (n, c) ->
        match c with
        | Some c -> `Assoc [ ("name", `String n); ("count", `Int c) ]
        | None -> `String n)
      items
  in
  post_ep "/chest_take_list" (`Assoc [ ("items", `List arr) ])

(* /festival：无活动时返回 {ok:false,error:"No active event"}（正常态）——刻意不 check *)
let festival_raw () = Http_client.get_json (base () ^ "/festival")

let festival_interact ?name () =
  let fields = match name with Some n -> [ ("name", `String n) ] | None -> [] in
  post_ep "/festival/interact" (`Assoc fields)

let festival_answer ~answer ?key () =
  let fields =
    [ ("answer", `Int answer) ]
    @ (match key with Some k -> [ ("key", `String k) ] | None -> [])
  in
  post_ep "/festival/answer" (`Assoc fields)

(* ---------- 批次 3 端点：批量农活 + 一次走全程（2026-10-14） ---------- *)

(* POST /tool_area：矩形批量农活（**真蓄力挥动**，不直写地块）。
   operation = "till" | "water"；矩形 (x1,y1)-(x2,y2) 含端点。
   返回（成功路径）：
     { ok, operation, swings, patches, still_missing:[{x,y,reason}],
       out_of_water, equipment_avoided:[{x,y,what}],
       anchors_skipped_by_equipment, anchors_moved_by_equipment, result:[...] }
   ⚠️ **不做 check**：mod 用 {ok:false, error:"No diggable tiles nearby"} 这类
   正常语义拒绝（矩形里没有目标格、没有对应工具），要和"真的出错"分开判读，
   故原样回给调用方（同 /use 的处理）。连接层错误仍会抛出。 *)
let tool_area ?max_time ~operation ~x1 ~y1 ~x2 ~y2 () =
  Http_client.post_json_json ?max_time
    (base () ^ "/tool_area")
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("operation", `String operation);
           ("x1", `Int x1); ("y1", `Int y1);
           ("x2", `Int x2); ("y2", `Int y2);
         ]))

(* POST /walk_to：一次走全程（mod 内部寻路；跨图自动 warp 到入口再走）。
   ⚠️ **发射后不管**：ok:true 只代表"路线已布好"，人还在走——完成要靠轮询坐标
   （或 /alerts 的 walk_completed）。入口校验失败会回 {ok:false, error:"…"}
   （越界 / 门格 / 站不住），**故不做 check**，由调用方转述成中文。
   location 必须传**当前地图名**（不传会被当成跨图 → 找不到该图）。 *)
let walk_to ~location ~x ~y ?(allow_water = false) ?(allow_warp = false) () =
  let fields =
    [ ("location", `String location); ("x", `Int x); ("y", `Int y) ]
    @ (if allow_water then [ ("allowWater", `Bool true) ] else [])
    @ (if allow_warp then [ ("allowWarp", `Bool true) ] else [])
  in
  Http_client.post_json_json (base () ^ "/walk_to")
    (Yojson.Safe.to_string (`Assoc fields))
