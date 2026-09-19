open Async
open Core

type t = {
  stdout : string;
  stderr : string;
  exit_status : Core_unix.Exit_or_signal.t;
}

let max_diagnostic_bytes = 2_000

let run ?stdin ~timeout ~prog ~args () =
  let open Deferred.Or_error.Let_syntax in
  let%bind process = Process.create ~prog ~args () in
  let stdin_writer = Process.stdin process in
  Writer.set_raise_when_consumer_leaves stdin_writer false;
  Option.iter stdin ~f:(Writer.write stdin_writer);
  let%bind.Deferred () = Writer.close stdin_writer in
  let output = Process.collect_output_and_wait process in
  match%bind.Deferred Clock_ns.with_timeout timeout output with
  | `Result { stdout; stderr; exit_status } ->
      return { stdout; stderr; exit_status }
  | `Timeout ->
      Signal_unix.send_i Signal.kill (`Pid (Process.pid process));
      let%bind.Deferred (_ : Process.Output.t) = output in
      Deferred.Or_error.errorf "%s timed out after %s" prog
        (Time_ns.Span.to_string_hum timeout)

let run_stdout ?stdin ~timeout ~prog ~args () =
  let open Deferred.Or_error.Let_syntax in
  let%bind result = run ?stdin ~timeout ~prog ~args () in
  match result.exit_status with
  | Ok () -> return result.stdout
  | Error _ as failure ->
      Deferred.Or_error.errorf "%s failed (%s): %s" prog
        (Core_unix.Exit_or_signal.to_string_hum failure)
        (String.prefix (String.strip result.stderr) max_diagnostic_bytes)
