(** 入口：stdio 循环 → Mcp.dispatch → stdout。

    stdout 是 MCP 协议通道，只能写协议消息；日志一律 stderr。 *)

open Stardew_mcp

let () =
  (* Windows 下防止 \n 被转成 \r\n（行协议按 \n 分隔） *)
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  Config.init ();
  Config.info "junimo-mcp 启动（api=%s）" (Config.api_url ());
  let rec loop () =
    match input_line stdin with
    | line ->
        let line = String.trim line in
        (if line <> "" then
           match Mcp.handle_message line with
           | Some resp ->
               print_string resp;
               print_char '\n';
               flush stdout
           | None -> ());
        loop ()
    | exception End_of_file -> ()
    | exception e ->
        Config.warn "stdin 读取异常：%s" (Printexc.to_string e)
  in
  loop ();
  Config.info "stdin 关闭，退出"
