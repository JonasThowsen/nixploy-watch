open Core

type problem =
  | Flagged of {
      facts : Judgment.facts;
      window : Log_window.t;
      judgment : Judgment.t;
      flagged : Judgment.classification list;
    }
  | Not_checked of { container : Managed_container.t; error : Error.t }
  | Watcher_failed of Error.t

let should_alert ~cooldown ~last_alert ~now =
  match last_alert with
  | None -> true
  | Some last_alert -> Time_ns.Span.(Time_ns.diff now last_alert >= cooldown)

type email = { subject : string; text : string }

let context_lines = 2
let recent_lines = 15
let max_evidence_lines = 3

let headline = function
  | Flagged { flagged; _ } ->
      List.map flagged ~f:(fun classification ->
          Classifier.name classification.Judgment.classifier)
  | Not_checked _ -> [ "could not be checked" ]
  | Watcher_failed _ -> [ "watcher failed" ]

let evidence_block entries (index, probability) =
  let first = Int.max 0 (index - context_lines) in
  let last = Int.min (Array.length entries - 1) (index + context_lines) in
  sprintf "  Evidence %s (p=%.2f):" (Log_window.line_id index) probability
  :: List.init
       (last - first + 1)
       ~f:(fun offset ->
         let line = first + offset in
         sprintf "  %s %s"
           (if line = index then ">" else " ")
           (Log_window.render_entry entries.(line)))

let flagged_section ~(facts : Judgment.facts) ~window ~judgment ~flagged =
  let entries = Array.of_list (Log_window.entries window) in
  let window_description =
    match facts.window_start with
    | Some start ->
        sprintf "Window: %s to %s UTC"
          (Time_ns.to_sec_string start ~zone:Time_float.Zone.utc)
          (Time_ns.to_sec_string facts.window_end ~zone:Time_float.Zone.utc)
    | None -> "Window: the last lines the container wrote before it stopped"
  in
  let header =
    [
      sprintf "Container %s (%s%s)" facts.container facts.container_state
        (Option.value_map facts.revision ~default:""
           ~f:(sprintf ", revision %s"));
      sprintf "%s, %d log lines, %d distinct messages%s." window_description
        (Log_window.total_lines window)
        (Log_window.entry_count window)
        (match Log_window.omitted_messages window with
        | 0 -> ""
        | omitted -> sprintf " (%d less relevant ones left out)" omitted);
    ]
    @
    if facts.restarts_since_last_check > 0 then
      [
        sprintf "The container restarted %d time(s) since the last check."
          facts.restarts_since_last_check;
      ]
    else []
  in
  let flagged_blocks =
    List.concat_map flagged
      ~f:(fun (classification : Judgment.classification) ->
        let evidence =
          match classification.evidence with
          | [] -> []
          | strongest :: rest ->
              strongest
              :: List.filter rest ~f:(fun (_, probability) ->
                  Float.(probability >= 0.25))
              |> Fn.flip List.take max_evidence_lines
              |> List.filter ~f:(fun (index, _) ->
                  index >= 0 && index < Array.length entries)
        in
        ""
        :: sprintf "%s: yes (p=%.2f). %s"
             (Classifier.name classification.classifier)
             classification.probability
             (Classifier.yes classification.classifier)
        :: List.concat_map evidence ~f:(evidence_block entries))
  in
  let others =
    List.filter (Judgment.classifications judgment)
      ~f:(fun (classification : Judgment.classification) ->
        not
          (List.exists flagged ~f:(fun (flagged : Judgment.classification) ->
               String.equal
                 (Classifier.name flagged.classifier)
                 (Classifier.name classification.classifier))))
    |> List.map ~f:(fun (classification : Judgment.classification) ->
        sprintf "%s %.2f%s"
          (Classifier.name classification.classifier)
          classification.probability
          (if Classifier.email classification.classifier then ""
           else " (journal only)"))
  in
  let recent =
    List.drop (Array.to_list entries) (Array.length entries - recent_lines)
    |> List.map ~f:(fun entry -> "  " ^ Log_window.render_entry entry)
  in
  header @ flagged_blocks
  @ [ ""; "Other classifiers: " ^ String.concat ~sep:", " others; "" ]
  @ ("Most recent messages:" :: recent)
  @ [ ""; sprintf "Judged by %s." (Judgment.model judgment) ]

let section = function
  | Flagged { facts; window; judgment; flagged } ->
      flagged_section ~facts ~window ~judgment ~flagged
  | Not_checked { container; error } ->
      [
        sprintf "Could not check container %s (%s):"
          (Managed_container.name container)
          (Managed_container.state_description container);
        "  " ^ Error.to_string_hum error;
      ]
  | Watcher_failed error ->
      [
        "nixploy-watch could not run its check:";
        "  " ^ Error.to_string_hum error;
      ]

let render ~application problems =
  let headlines =
    List.concat_map problems ~f:headline
    |> List.dedup_and_sort ~compare:String.compare
  in
  {
    subject =
      sprintf "[nixploy-watch] %s: %s" application
        (String.concat ~sep:", " headlines);
    text =
      String.concat ~sep:"\n"
        (List.intersperse
           (List.map problems ~f:section)
           ~sep:[ ""; String.make 72 '-'; "" ]
        |> List.concat)
      ^ "\n";
  }

let resend_request ~from ~to_ email =
  `Assoc
    [
      ("from", `String from);
      ("to", `List (List.map to_ ~f:(fun address -> `String address)));
      ("subject", `String email.subject);
      ("text", `String email.text);
    ]
