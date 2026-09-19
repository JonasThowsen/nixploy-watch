open Core

type state = Running | Stopped of { status : string; exit_code : int option }

type t = {
  id : string;
  name : string;
  project : string;
  target : string;
  revision : string option;
  state : state;
  restarts : int;
  started_at : Time_ns.t option;
}

let id t = t.id
let name t = t.name
let project t = t.project
let target t = t.target
let application t = t.project ^ "/" ^ t.target
let revision t = t.revision
let state t = t.state
let restarts t = t.restarts
let started_at t = t.started_at

let state_description t =
  match t.state with
  | Running -> "running"
  | Stopped { status; exit_code = Some code } ->
      sprintf "%s (exit code %d)" status code
  | Stopped { status; exit_code = None } -> status

let string_field fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) when not (String.is_empty value) -> Some value
  | _ -> None

let int_field fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> Int.of_string_opt value
  | _ -> None

let container_name fields =
  match List.Assoc.find fields ~equal:String.equal "Names" with
  | Some (`List (`String name :: _)) -> Some name
  | Some (`String name) -> Some name
  | _ -> None

let of_json = function
  | `Assoc fields -> (
      let labels =
        match List.Assoc.find fields ~equal:String.equal "Labels" with
        | Some (`Assoc labels) -> labels
        | _ -> []
      in
      match
        ( string_field labels "io.nixploy.managed",
          string_field labels "io.nixploy.project",
          string_field labels "io.nixploy.target",
          string_field fields "Id" )
      with
      | Some "true", Some project, Some target, Some id ->
          let state =
            match string_field fields "State" with
            | Some "running" -> Running
            | status ->
                Stopped
                  {
                    status = Option.value status ~default:"unknown";
                    exit_code = int_field fields "ExitCode";
                  }
          in
          Ok
            (Some
               {
                 id;
                 name =
                   Option.value (container_name fields)
                     ~default:(String.prefix id 12);
                 project;
                 target;
                 revision = string_field labels "io.nixploy.revision";
                 state;
                 restarts =
                   Option.value (int_field fields "Restarts") ~default:0;
                 started_at =
                   int_field fields "StartedAt"
                   |> Option.filter ~f:Int.is_positive
                   |> Option.map ~f:(fun seconds ->
                       Time_ns.of_span_since_epoch
                         (Time_ns.Span.of_int_sec seconds));
               })
      | _ -> Ok None)
  | _ -> Or_error.error_string "Podman container must be a JSON object"

let all_managed_of_json input =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string input)
    |> Or_error.tag ~tag:"Podman container list is not JSON"
  in
  match json with
  | `Null -> Ok []
  | `List containers ->
      List.map containers ~f:of_json |> Or_error.all >>| List.filter_opt
  | _ -> Or_error.error_string "Podman container list must be a JSON array"

module For_testing = struct
  let create ~id ?(name = id) ~project ~target ?revision ~state ?(restarts = 0)
      ?started_at () =
    { id; name; project; target; revision; state; restarts; started_at }
end
