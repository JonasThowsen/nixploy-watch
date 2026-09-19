open Async
open Core

let timeout = Time_ns.Span.of_sec 60.

let list_managed ~podman =
  Command_runner.run_stdout ~timeout ~prog:podman
    ~args:
      [
        "ps";
        "--all";
        "--filter";
        "label=io.nixploy.managed=true";
        "--format";
        "json";
      ]
    ()
  >>| Or_error.bind ~f:Managed_container.all_managed_of_json

let since_argument time =
  Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc

let read_logs ~podman container ~since ~tail =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Command_runner.run ~timeout ~prog:podman
      ~args:
        ([ "logs"; "--timestamps"; "--tail"; Int.to_string tail ]
        @ (match since with
          | Some since -> [ "--since"; since_argument since ]
          | None -> [])
        @ [ Managed_container.id container ])
      ()
  in
  match result.exit_status with
  | Ok () -> return (Log_window.of_podman_logs [ result.stdout; result.stderr ])
  | Error _ as failure ->
      Deferred.Or_error.errorf "podman logs %s failed (%s): %s"
        (Managed_container.name container)
        (Core_unix.Exit_or_signal.to_string_hum failure)
        (String.prefix (String.strip result.stderr) 2_000)
