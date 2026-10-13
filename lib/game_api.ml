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

let post_ep path (body : Yojson.Safe.t) =
  Http_client.post_json_json (base () ^ path) (Yojson.Safe.to_string body)
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
