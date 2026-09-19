open Core

type facts = {
  project : string;
  target : string;
  container : string;
  revision : string option;
  container_state : string;
  restarts_since_last_check : int;
  window_start : Time_ns.t option;
  window_end : Time_ns.t;
}

type classification = {
  classifier : Classifier.t;
  probability : float;
  evidence : (int * float) list;
}

type t = { model : string; classifications : classification list }

let model t = t.model
let classifications t = t.classifications

let flagged ~threshold t =
  List.filter t.classifications ~f:(fun classification ->
      Classifier.email classification.classifier
      && Float.(classification.probability >= threshold))
  |> List.sort ~compare:(fun left right ->
      Float.descending left.probability right.probability)

(* Question ids are never sent to the model; the prefixes keep a classifier
   named like another's evidence question from colliding with it. *)
let classifier_key classifier = "classifier_" ^ Classifier.name classifier
let evidence_key classifier = "evidence_" ^ Classifier.name classifier

(* Choice needs at least two options to compare. *)
let asks_for_evidence window classifier =
  Classifier.email classifier && Log_window.entry_count window >= 2

let time_string time =
  Time_ns.to_sec_string time ~zone:Time_float.Zone.utc ^ " UTC"

let log_format =
  "Each line of `log` is `Lnnn| HH:MM:SS [xN] message`. Messages that differ \
   only in numbers are merged and [xN] counts their occurrences in the window. \
   Credential values are replaced with [REDACTED]."

let state_json facts window =
  let option_string = function Some value -> `String value | None -> `Null in
  `Assoc
    [
      ( "container",
        `Assoc
          [
            ("project", `String facts.project);
            ("target", `String facts.target);
            ("name", `String facts.container);
            ("revision", option_string facts.revision);
            ("state", `String facts.container_state);
            ("restarts_since_last_check", `Int facts.restarts_since_last_check);
          ] );
      ( "window",
        `Assoc
          [
            ( "from",
              match facts.window_start with
              | Some start -> `String (time_string start)
              | None -> `String "last lines before the container stopped" );
            ("to", `String (time_string facts.window_end));
            ("log_lines_written", `Int (Log_window.total_lines window));
            ("distinct_messages_shown", `Int (Log_window.entry_count window));
            ("messages_left_out", `Int (Log_window.omitted_messages window));
          ] );
      ("log_format", `String log_format);
      ("log", `String (Log_window.tagged_text window));
    ]

let request_json ~model ~classifiers facts window =
  let noul classifier =
    ( classifier_key classifier,
      `Assoc
        [
          ("type", `String "noul");
          ("instructions", `String (Classifier.question classifier));
          ( "criteria",
            `Assoc
              [
                ("true", `String (Classifier.yes classifier));
                ("false", `String (Classifier.no classifier));
              ] );
        ] )
  in
  let evidence classifier =
    ( evidence_key classifier,
      `Assoc
        [
          ("type", `String "choice");
          ( "instructions",
            `String
              (sprintf
                 "Which line of `log` best shows the following? %s If no line \
                  does, pick the line closest to it."
                 (Classifier.yes classifier)) );
          ( "criteria",
            `Assoc
              (List.init (Log_window.entry_count window) ~f:(fun index ->
                   (Log_window.line_id index, `Null))) );
        ] )
  in
  `Assoc
    [
      ("model", `String model);
      ("state", state_json facts window);
      ( "questions",
        `Assoc
          (List.map classifiers ~f:noul
          @ List.filter_map classifiers ~f:(fun classifier ->
              Option.some_if
                (asks_for_evidence window classifier)
                (evidence classifier))) );
    ]

let of_response ~classifiers window body =
  let module Json = Yojson.Safe.Util in
  Or_error.try_with (fun () ->
      let json = Yojson.Safe.from_string body in
      let answers = Json.member "answers" json in
      let classification classifier =
        let probability =
          Json.member (classifier_key classifier) answers
          |> Json.member "noul" |> Json.to_number
        in
        let evidence =
          if asks_for_evidence window classifier then
            Json.member (evidence_key classifier) answers
            |> Json.member "probabilities"
            |> Json.to_assoc
            |> List.filter_map ~f:(fun (id, probability) ->
                Log_window.index_of_line_id id
                |> Option.map ~f:(fun index ->
                    (index, Json.to_number probability)))
            |> List.sort ~compare:(fun (_, left) (_, right) ->
                Float.descending left right)
          else if Classifier.email classifier then [ (0, 1.) ]
          else []
        in
        { classifier; probability; evidence }
      in
      {
        model = Json.member "model" json |> Json.to_string;
        classifications = List.map classifiers ~f:classification;
      })
  |> Or_error.tag
       ~tag:
         (sprintf "unexpected TypeSafe response: %s" (String.prefix body 500))

module For_testing = struct
  let create ~model classifications = { model; classifications }
end
