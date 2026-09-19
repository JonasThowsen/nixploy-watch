open Async
open Core

type config = {
  model : string;
  classifiers : Classifier.t list;
  threshold : float;
  cooldown : Time_ns.Span.t;
  interval : Time_ns.Span.t;
}

type runtime = {
  now : unit -> Time_ns.t;
  list_containers : unit -> Managed_container.t list Deferred.Or_error.t;
  read_logs :
    Managed_container.t ->
    since:Time_ns.t option ->
    tail:int ->
    Log_window.t Deferred.Or_error.t;
  evaluate : Yojson.Safe.t -> string Deferred.Or_error.t;
  send_email : Alert.email -> unit Deferred.Or_error.t;
}

type outcome = { state : Watch_state.t; report : string list; failed : bool }

let watcher_key = "nixploy-watch"
let running_tail = 5_000
let stopped_tail = 100

type check = {
  problems : Alert.problem list;
  saved : (string * Watch_state.container) option;
  line : string;
}

let facts_for ~now ~since ~restarts container : Judgment.facts =
  {
    project = Managed_container.project container;
    target = Managed_container.target container;
    container = Managed_container.name container;
    revision = Managed_container.revision container;
    container_state = Managed_container.state_description container;
    restarts_since_last_check = restarts;
    window_start = since;
    window_end = now;
  }

let classify config runtime facts window =
  let open Deferred.Or_error.Let_syntax in
  let%bind body =
    runtime.evaluate
      (Judgment.request_json ~model:config.model ~classifiers:config.classifiers
         facts window)
  in
  Judgment.of_response ~classifiers:config.classifiers window body
  |> Deferred.return

let describe_judgment config judgment =
  Judgment.classifications judgment
  |> List.filter ~f:(fun (classification : Judgment.classification) ->
      Float.(classification.probability >= config.threshold))
  |> List.map ~f:(fun (classification : Judgment.classification) ->
      sprintf "%s=%.2f"
        (Classifier.name classification.classifier)
        classification.probability)
  |> function
  | [] -> "nothing above threshold"
  | above -> String.concat ~sep:" " above

(* Evaluates one log window. The caller decides from the problems whether the
   window counts as checked. *)
let check_window config runtime ~container ~facts ~read =
  let name = Managed_container.name container in
  let not_checked what error =
    {
      problems = [ Alert.Not_checked { container; error } ];
      saved = None;
      line =
        sprintf "%s: could not %s: %s" name what (Error.to_string_hum error);
    }
  in
  match%bind read () with
  | Error error -> return (not_checked "read logs" error)
  | Ok window when Log_window.is_empty window ->
      return { problems = []; saved = None; line = name ^ ": no new log lines" }
  | Ok window -> (
      match%map classify config runtime facts window with
      | Error error -> not_checked "classify logs" error
      | Ok judgment ->
          let flagged = Judgment.flagged ~threshold:config.threshold judgment in
          {
            problems =
              (if List.is_empty flagged then []
               else [ Alert.Flagged { facts; window; judgment; flagged } ]);
            saved = None;
            line =
              sprintf "%s: %d lines, %s" name
                (Log_window.total_lines window)
                (describe_judgment config judgment);
          })

let check_running config runtime (state : Watch_state.t) ~now container =
  let previous = Map.find state.containers (Managed_container.id container) in
  let since =
    match previous with
    | Some previous -> previous.checked_until
    | None -> (
        let floor = Time_ns.sub now config.interval in
        match Managed_container.started_at container with
        | Some started when Time_ns.(started > floor) -> started
        | _ -> floor)
  in
  let restarts =
    match previous with
    | Some previous ->
        Int.max 0 (Managed_container.restarts container - previous.restarts)
    | None -> 0
  in
  let facts = facts_for ~now ~since:(Some since) ~restarts container in
  let%map check =
    check_window config runtime ~container ~facts ~read:(fun () ->
        runtime.read_logs container ~since:(Some since) ~tail:running_tail)
  in
  let succeeded =
    not
      (List.exists check.problems ~f:(function
        | Alert.Not_checked _ -> true
        | Flagged _ | Watcher_failed _ -> false))
  in
  let checked_until = if succeeded then now else since in
  {
    check with
    saved =
      Some
        ( Managed_container.id container,
          {
            Watch_state.checked_until;
            restarts = Managed_container.restarts container;
          } );
  }

let check_stopped config runtime ~now containers =
  let latest =
    List.max_elt containers
      ~compare:
        (Comparable.lift
           (Option.compare Time_ns.compare)
           ~f:Managed_container.started_at)
  in
  match latest with
  | None -> return []
  | Some container ->
      let facts = facts_for ~now ~since:None ~restarts:0 container in
      let%map check =
        check_window config runtime ~container ~facts ~read:(fun () ->
            runtime.read_logs container ~since:None ~tail:stopped_tail)
      in
      [ { check with line = check.line ^ " (no container running)" } ]

let alert config runtime ~now ~application ~previous problems =
  let last_alert =
    Option.bind previous ~f:(fun (previous : Watch_state.application) ->
        previous.last_alert)
  in
  if List.is_empty problems then return (last_alert, None, false)
  else if not (Alert.should_alert ~cooldown:config.cooldown ~last_alert ~now)
  then
    return
      ( last_alert,
        Some (sprintf "%s: alert held back by cooldown" application),
        false )
  else
    match%map runtime.send_email (Alert.render ~application problems) with
    | Ok () -> (Some now, Some (sprintf "%s: alert emailed" application), false)
    | Error error ->
        ( last_alert,
          Some
            (sprintf "%s: could not send alert: %s" application
               (Error.to_string_hum error)),
          true )

let check_application config runtime (state : Watch_state.t) ~now
    (application, containers) =
  let running, stopped =
    List.partition_tf containers ~f:(fun container ->
        match Managed_container.state container with
        | Running -> true
        | Stopped _ -> false)
  in
  let%bind checks =
    if List.is_empty running then check_stopped config runtime ~now stopped
    else
      Deferred.List.map ~how:`Sequential running
        ~f:(check_running config runtime state ~now)
  in
  let problems = List.concat_map checks ~f:(fun check -> check.problems) in
  let previous = Map.find state.applications application in
  let%map last_alert, alert_line, alert_failed =
    alert config runtime ~now ~application ~previous problems
  in
  let check_failed =
    List.exists problems ~f:(function
      | Alert.Not_checked _ -> true
      | Flagged _ | Watcher_failed _ -> false)
  in
  ( List.filter_map checks ~f:(fun check -> check.saved),
    (application, { Watch_state.last_alert }),
    List.map checks ~f:(fun check -> application ^ " " ^ check.line)
    @ Option.to_list alert_line,
    check_failed || alert_failed )

let run_once config runtime (state : Watch_state.t) =
  let now = runtime.now () in
  match%bind runtime.list_containers () with
  | Error error ->
      let previous = Map.find state.applications watcher_key in
      let%map last_alert, alert_line, _ =
        alert config runtime ~now ~application:watcher_key ~previous
          [ Alert.Watcher_failed error ]
      in
      {
        state =
          {
            state with
            applications =
              Map.set state.applications ~key:watcher_key
                ~data:{ Watch_state.last_alert };
          };
        report =
          sprintf "could not list containers: %s" (Error.to_string_hum error)
          :: Option.to_list alert_line;
        failed = true;
      }
  | Ok containers ->
      let applications =
        List.map containers ~f:(fun container ->
            (Managed_container.application container, container))
        |> String.Map.of_alist_multi |> Map.to_alist
      in
      let%map results =
        Deferred.List.map ~how:`Sequential applications
          ~f:(check_application config runtime state ~now)
      in
      {
        state =
          {
            containers =
              List.concat_map results ~f:(fun (saved, _, _, _) -> saved)
              |> String.Map.of_alist_reduce ~f:(fun _ latest -> latest);
            applications =
              List.map results ~f:(fun (_, application, _, _) -> application)
              |> String.Map.of_alist_reduce ~f:(fun _ latest -> latest);
          };
        report =
          (match results with
          | [] -> [ "no nixploy-managed containers found" ]
          | _ -> List.concat_map results ~f:(fun (_, _, report, _) -> report));
        failed = List.exists results ~f:(fun (_, _, _, failed) -> failed);
      }
