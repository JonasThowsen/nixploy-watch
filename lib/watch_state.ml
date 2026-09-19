open Async
open Core

type container = { checked_until : Time_ns.t; restarts : int }
type application = { last_alert : Time_ns.t option }

type t = {
  containers : container String.Map.t;
  applications : application String.Map.t;
}

let empty = { containers = String.Map.empty; applications = String.Map.empty }
let time_to_json time = `Int (Time_ns.to_int_ns_since_epoch time)

let time_of_json = function
  | `Int ns -> Ok (Time_ns.of_int_ns_since_epoch ns)
  | _ -> Or_error.error_string "state time must be an integer"

let to_json_string t =
  `Assoc
    [
      ( "containers",
        `Assoc
          (Map.to_alist t.containers
          |> List.map ~f:(fun (id, container) ->
              ( id,
                `Assoc
                  [
                    ("checked_until", time_to_json container.checked_until);
                    ("restarts", `Int container.restarts);
                  ] ))) );
      ( "applications",
        `Assoc
          (Map.to_alist t.applications
          |> List.map ~f:(fun (key, application) ->
              ( key,
                `Assoc
                  [
                    ( "last_alert",
                      Option.value_map application.last_alert ~default:`Null
                        ~f:time_to_json );
                  ] ))) );
    ]
  |> Yojson.Safe.to_string

let map_of_json json ~f =
  let open Or_error.Let_syntax in
  match json with
  | `Null -> Ok String.Map.empty
  | `Assoc entries ->
      let%bind entries =
        List.map entries ~f:(fun (key, value) ->
            f value >>| fun value -> (key, value))
        |> Or_error.all
      in
      String.Map.of_alist_or_error entries
  | _ -> Or_error.error_string "state section must be an object"

let field fields key =
  List.Assoc.find fields ~equal:String.equal key |> Option.value ~default:`Null

let of_json_string input =
  let open Or_error.Let_syntax in
  let%bind json = Or_error.try_with (fun () -> Yojson.Safe.from_string input) in
  match json with
  | `Assoc fields ->
      let%bind containers =
        map_of_json (field fields "containers") ~f:(function
          | `Assoc container -> (
              let%bind checked_until =
                time_of_json (field container "checked_until")
              in
              match field container "restarts" with
              | `Int restarts -> Ok { checked_until; restarts }
              | _ ->
                  Or_error.error_string "container restarts must be an integer")
          | _ -> Or_error.error_string "container state must be an object")
      and applications =
        map_of_json (field fields "applications") ~f:(function
          | `Assoc application -> (
              match field application "last_alert" with
              | `Null -> Ok { last_alert = None }
              | time ->
                  time_of_json time >>| fun time -> { last_alert = Some time })
          | _ -> Or_error.error_string "application state must be an object")
      in
      Ok { containers; applications }
  | _ -> Or_error.error_string "state must be a JSON object"

let load ~path =
  match%bind Async.Sys.file_exists_exn path with
  | false -> return (Ok empty)
  | true ->
      Monitor.try_with_or_error (fun () -> Reader.file_contents path)
      >>| Or_error.bind ~f:of_json_string
      >>| Or_error.tag ~tag:(sprintf "could not read state file %s" path)

let save ~path t =
  let temporary = path ^ ".tmp" in
  Monitor.try_with_or_error (fun () ->
      let%bind () =
        Writer.save temporary ~contents:(to_json_string t) ~fsync:true
      in
      Async.Unix.rename ~src:temporary ~dst:path)
  |> Deferred.Or_error.tag ~tag:(sprintf "could not write state file %s" path)
