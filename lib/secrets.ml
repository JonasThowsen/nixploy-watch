open Async
open Core

type t = { typesafe_api_key : string; resend_api_key : string }

let typesafe_api_key t = t.typesafe_api_key
let resend_api_key t = t.resend_api_key

let unquote value =
  let length = String.length value in
  if
    length >= 2
    && (Char.equal value.[0] '"' || Char.equal value.[0] '\'')
    && Char.equal value.[length - 1] value.[0]
  then String.sub value ~pos:1 ~len:(length - 2)
  else value

(* Errors name variables, never values. *)
let of_dotenv input =
  let variables =
    String.split_lines input
    |> List.filter_map ~f:(fun line ->
        let line = String.strip line in
        if String.is_empty line || String.is_prefix line ~prefix:"#" then None
        else
          String.lsplit2 line ~on:'='
          |> Option.map ~f:(fun (name, value) ->
              (String.strip name, unquote (String.strip value))))
  in
  let required name =
    match List.Assoc.find variables ~equal:String.equal name with
    | Some value when not (String.is_empty value) -> Ok value
    | _ -> Or_error.errorf "secrets file does not define %s" name
  in
  let open Or_error.Let_syntax in
  let%map typesafe_api_key = required "TYPESAFE_API_KEY"
  and resend_api_key = required "RESEND_API_KEY" in
  { typesafe_api_key; resend_api_key }

let load ?(sops = "sops") ~path () =
  Command_runner.run_stdout ~timeout:(Time_ns.Span.of_min 1.) ~prog:sops
    ~args:
      [ "--decrypt"; "--input-type"; "dotenv"; "--output-type"; "dotenv"; path ]
    ()
  >>| Or_error.bind ~f:of_dotenv
  >>| Or_error.tag ~tag:(sprintf "could not load secrets from %s" path)
