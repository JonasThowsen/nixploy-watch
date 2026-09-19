open Async
open Core

type response = { status : int; body : string }

let request_timeout_seconds = 60
let typesafe_url = "https://api.typesafe.ai/v1/systemone"
let resend_url = "https://api.resend.com/emails"
let user_agent = "nixploy-watch/0.1"

(* curl config strings are double-quoted with backslash escapes. *)
let quote value =
  let buffer = Buffer.create (String.length value + 2) in
  Buffer.add_char buffer '"';
  String.iter value ~f:(function
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '"' -> Buffer.add_string buffer "\\\""
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\r' -> Buffer.add_string buffer "\\r"
    | '\t' -> Buffer.add_string buffer "\\t"
    | character -> Buffer.add_char buffer character);
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let curl_config ~url ~bearer body =
  [
    ("url", url);
    ("request", "POST");
    ("header", "Authorization: Bearer " ^ bearer);
    ("header", "Content-Type: application/json");
    ("header", "User-Agent: " ^ user_agent);
    ("data-binary", body);
    ("max-time", Int.to_string request_timeout_seconds);
    ("write-out", "\n%{http_code}");
  ]
  |> List.map ~f:(fun (key, value) -> sprintf "%s = %s" key (quote value))
  |> List.append [ "silent"; "show-error" ]
  |> String.concat ~sep:"\n"
  |> fun config -> config ^ "\n"

let parse_output output =
  match String.rsplit2 output ~on:'\n' with
  | Some (body, status) -> (
      match Int.of_string_opt (String.strip status) with
      | Some status -> Ok { status; body }
      | None -> Or_error.errorf "curl reported no HTTP status: %S" status)
  | None -> Or_error.error_string "curl reported no HTTP status"

let retryable = function
  | Error _ -> true
  | Ok { status; _ } -> status = 429 || status >= 500

let post_json ?(curl = "curl")
    ?(retry_delays = [ Time_ns.Span.of_sec 2.; Time_ns.Span.of_sec 10. ]) ~url
    ~bearer json =
  let config = curl_config ~url ~bearer (Yojson.Safe.to_string json) in
  let attempt () =
    Command_runner.run_stdout ~stdin:config
      ~timeout:(Time_ns.Span.of_int_sec (request_timeout_seconds + 10))
      ~prog:curl ~args:[ "--config"; "-" ] ()
    >>| Or_error.bind ~f:parse_output
  in
  let rec loop delays =
    let%bind result = attempt () in
    match delays with
    | delay :: remaining when retryable result ->
        let%bind () = Clock_ns.after delay in
        loop remaining
    | _ -> return result
  in
  loop retry_delays

let successful ~service result =
  let open Deferred.Or_error.Let_syntax in
  let%bind { status; body } = result in
  if status >= 200 && status < 300 then return body
  else
    Deferred.Or_error.errorf "%s returned HTTP %d: %s" service status
      (String.prefix (String.strip body) 1_000)

let typesafe_system_one ?(url = typesafe_url) ~api_key request =
  post_json ~url ~bearer:api_key request |> successful ~service:"TypeSafe"

let resend_email ?(url = resend_url) ~api_key request =
  post_json ~url ~bearer:api_key request
  |> successful ~service:"Resend"
  |> Deferred.Or_error.ignore_m

module For_testing = struct
  let curl_config = curl_config
  let parse_output = parse_output
end
