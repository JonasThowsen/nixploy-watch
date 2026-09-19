open Async
open Core
open Nixploy_watch

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    eprintf "FAIL: %s\n%!" name)

let ok_exn name = function
  | Ok value -> value
  | Error error ->
      failwithf "%s: unexpected error %s" name (Error.to_string_hum error) ()

let contains text substring = String.is_substring text ~substring
let time seconds = Time_ns.of_span_since_epoch (Time_ns.Span.of_int_sec seconds)
let minutes n = Time_ns.Span.of_int_sec (n * 60)

(* Managed_container *)

let () =
  let json =
    {|[
      {"Id":"aaa","Names":["nixploy-shop-1a2b-production-blue"],"State":"running",
       "Restarts":2,"StartedAt":1700000000,
       "Labels":{"io.nixploy.managed":"true","io.nixploy.project":"shop",
                 "io.nixploy.target":"production","io.nixploy.revision":"abc123"}},
      {"Id":"bbb","Names":["nixploy-shop-1a2b-production-green"],"State":"exited",
       "ExitCode":137,"Restarts":0,"StartedAt":0,
       "Labels":{"io.nixploy.managed":"true","io.nixploy.project":"shop",
                 "io.nixploy.target":"production"}},
      {"Id":"ccc","Names":["postgres"],"State":"running","Labels":{}},
      {"Id":"ddd","Names":["legacy"],"State":"running",
       "Labels":{"nixploy.project":"shop"}}
    ]|}
  in
  let containers =
    Managed_container.all_managed_of_json json |> ok_exn "container list"
  in
  check "only labelled containers are kept" (List.length containers = 2);
  let blue = List.hd_exn containers and green = List.last_exn containers in
  check "application groups by project/target"
    (String.equal (Managed_container.application blue) "shop/production");
  check "revision label is read"
    (Option.equal String.equal
       (Managed_container.revision blue)
       (Some "abc123"));
  check "restarts are read" (Managed_container.restarts blue = 2);
  check "running state"
    (match Managed_container.state blue with
    | Running -> true
    | Stopped _ -> false);
  check "stopped state includes exit code"
    (String.equal
       (Managed_container.state_description green)
       "exited (exit code 137)");
  check "zero StartedAt means never started"
    (Option.is_none (Managed_container.started_at green));
  check "empty podman output"
    (Managed_container.all_managed_of_json "null"
    |> ok_exn "null" |> List.is_empty)

(* Log_window *)

let () =
  let stdout =
    String.concat ~sep:"\n"
      [
        "2026-09-19T10:00:01.5+02:00 GET /health 200 in 3ms";
        "2026-09-19T10:00:03+02:00 GET /health 200 in 12ms";
        "2026-09-19T10:00:05.000000001+02:00 GET /health 200 in 7ms";
      ]
  and stderr =
    String.concat ~sep:"\n"
      [
        "2026-09-19T08:00:02Z ** (DBConnection.ConnectionError) connection \
         refused";
        "   continuation line without a timestamp";
        "2026-09-19T08:00:04Z login password=hunter2 user=bob";
        "2026-09-19T08:00:06Z Authorization: Bearer sk-secret, next";
        "2026-09-19T08:00:07Z \027[31mred\027[0m text \255 end";
      ]
  in
  let window = Log_window.of_podman_logs [ stdout; stderr ] in
  let texts =
    List.map (Log_window.entries window) ~f:(fun entry -> entry.Log_window.text)
  in
  check "counts every raw line" (Log_window.total_lines window = 8);
  check "merges messages differing only in digits"
    (List.exists (Log_window.entries window) ~f:(fun entry ->
         entry.count = 3 && contains entry.text "GET /health"));
  check "orders stdout and stderr by time across offsets"
    (match texts with
    | "GET /health 200 in 3ms" :: second :: _ ->
        contains second "connection refused"
    | _ -> false);
  check "keeps untimestamped continuation next to its line"
    (match List.nth texts 2 with
    | Some text -> contains text "continuation"
    | None -> false);
  check "redacts key=value secrets"
    (List.exists texts ~f:(fun text ->
         contains text "password=[REDACTED] user=bob"));
  check "redacts authorization up to the comma"
    (List.exists texts ~f:(fun text ->
         contains text "Authorization: [REDACTED], next"));
  check "no secret survives"
    (not
       (List.exists texts ~f:(fun text ->
            contains text "hunter2" || contains text "sk-secret")));
  check "strips ANSI escapes and replaces invalid UTF-8"
    (List.exists texts ~f:(fun text ->
         String.equal text "red text \xef\xbf\xbd end"));
  check "tagged text uses line ids"
    (String.is_prefix
       (Log_window.tagged_text window)
       ~prefix:"L000| 10:00:01 [x3] GET");
  check "line ids round-trip"
    (Option.equal Int.equal
       (Log_window.index_of_line_id (Log_window.line_id 42))
       (Some 42));
  check "empty input"
    (Log_window.is_empty (Log_window.of_podman_logs [ ""; "\n" ]))

(* Distinct without digits, so messages are not merged. *)
let rec letters index =
  let character = String.of_char (Char.of_int_exn (97 + (index mod 26))) in
  if index < 26 then character else letters ((index / 26) - 1) ^ character

let () =
  let line index text =
    sprintf "2026-09-19T10:%02d:%02dZ %s"
      (index / 60 mod 60)
      (index mod 60) text
  in
  let lines =
    line 0 "FATAL early crash in worker"
    :: List.init 600 ~f:(fun index ->
        line (index + 1) (sprintf "request %s served" (letters index)))
  in
  let window = Log_window.of_podman_logs [ String.concat ~sep:"\n" lines ] in
  check "bounded to max entries"
    (Log_window.entry_count window <= Log_window.max_entries);
  check "reports omitted messages" (Log_window.omitted_messages window > 0);
  check "keeps problem lines when over budget"
    (List.exists (Log_window.entries window) ~f:(fun entry ->
         contains entry.text "FATAL early crash"));
  check "keeps the most recent other lines"
    (match List.last (Log_window.entries window) with
    | Some entry -> contains entry.text "served"
    | None -> false)

(* Classifier *)

let () =
  let json = Classifier.list_to_json_string Classifier.defaults in
  let parsed =
    Classifier.list_of_json_string json |> ok_exn "defaults round-trip"
  in
  check "defaults round-trip"
    (List.equal String.equal
       (List.map parsed ~f:Classifier.name)
       (List.map Classifier.defaults ~f:Classifier.name));
  check "some defaults email and some do not"
    (List.exists Classifier.defaults ~f:Classifier.email
    && List.exists Classifier.defaults ~f:(Fn.non Classifier.email));
  let item name =
    sprintf {|{"name":"%s","question":"q?","yes":"y","no":"n","email":true}|}
      name
  in
  check "duplicate names are rejected"
    (Result.is_error
       (Classifier.list_of_json_string
          (sprintf "[%s,%s]" (item "a") (item "a"))));
  check "invalid names are rejected"
    (Result.is_error
       (Classifier.list_of_json_string (sprintf "[%s]" (item "Bad Name"))));
  check "empty list is rejected"
    (Result.is_error (Classifier.list_of_json_string "[]"));
  check "email must be boolean"
    (Result.is_error
       (Classifier.list_of_json_string
          {|[{"name":"a","question":"q","yes":"y","no":"n","email":"yes"}]|}))

(* Judgment *)

let classifier ~name ~email =
  Classifier.create ~name ~question:(name ^ "?") ~yes:(name ^ " yes")
    ~no:(name ^ " no") ~email
  |> ok_exn "classifier"

let crash = classifier ~name:"crash" ~email:true
let warnings = classifier ~name:"warnings" ~email:false
let classifiers = [ crash; warnings ]

(* Answers every question in a request: Nouls from [probabilities], Choices
   pointing at L001. *)
let fake_jev ~probabilities request =
  let module Json = Yojson.Safe.Util in
  let questions = Json.member "questions" request |> Json.to_assoc in
  let answer (key, question) =
    match Json.member "type" question |> Json.to_string with
    | "noul" ->
        let name = String.chop_prefix_exn key ~prefix:"classifier_" in
        ( key,
          `Assoc
            [
              ("type", `String "noul");
              ( "noul",
                `Float
                  (List.Assoc.find probabilities ~equal:String.equal name
                  |> Option.value ~default:0.01) );
            ] )
    | _ ->
        let options = Json.member "criteria" question |> Json.to_assoc in
        let share = 0.1 /. Float.of_int (List.length options - 1) in
        ( key,
          `Assoc
            [
              ("type", `String "choice");
              ("choice", `String "L001");
              ( "probabilities",
                `Assoc
                  (List.map options ~f:(fun (id, _) ->
                       ( id,
                         `Float (if String.equal id "L001" then 0.9 else share)
                       ))) );
              ("confidence", `Float 0.8);
            ] )
  in
  `Assoc
    [
      ("model", `String "jev-1.13.0");
      ("answers", `Assoc (List.map questions ~f:answer));
      ("usage", `Assoc [ ("input_tokens", `Int 1); ("output_tokens", `Int 1) ]);
    ]
  |> Yojson.Safe.to_string

let sample_window =
  Log_window.of_podman_logs
    [
      String.concat ~sep:"\n"
        [
          "2026-09-19T10:00:00Z booting";
          "2026-09-19T10:00:01Z ** (exit) killed by OOM";
          "2026-09-19T10:00:02Z restarting";
        ];
    ]

let sample_facts : Judgment.facts =
  {
    project = "shop";
    target = "production";
    container = "blue";
    revision = Some "abc123";
    container_state = "running";
    restarts_since_last_check = 1;
    window_start = Some (time 1000);
    window_end = time 1900;
  }

let () =
  let request =
    Judgment.request_json ~model:"jev-latest" ~classifiers sample_facts
      sample_window
  in
  let module Json = Yojson.Safe.Util in
  let questions =
    Json.member "questions" request |> Json.to_assoc |> List.map ~f:fst
  in
  check "one noul per classifier and evidence only for emailing ones"
    (List.equal String.equal
       (List.sort questions ~compare:String.compare)
       [ "classifier_crash"; "classifier_warnings"; "evidence_crash" ]);
  check "state carries the tagged log"
    (contains
       (Json.member "state" request |> Json.member "log" |> Json.to_string)
       "L001| 10:00:01 ** (exit) killed by OOM");
  check "state carries restarts"
    (Json.member "state" request
    |> Json.member "container"
    |> Json.member "restarts_since_last_check"
    |> Json.to_int = 1);
  let judgment =
    Judgment.of_response ~classifiers sample_window
      (fake_jev ~probabilities:[ ("crash", 0.9); ("warnings", 0.95) ] request)
    |> ok_exn "judgment"
  in
  let flagged = Judgment.flagged ~threshold:0.5 judgment in
  check "only emailing classifiers are flagged"
    (List.map flagged ~f:(fun c -> Classifier.name c.classifier)
    |> List.equal String.equal [ "crash" ]);
  check "evidence points at the chosen line"
    (match flagged with
    | [ { evidence = (1, _) :: _; _ } ] -> true
    | _ -> false);
  check "malformed responses are errors"
    (Result.is_error
       (Judgment.of_response ~classifiers sample_window {|{"answers":{}}|}));
  let single = Log_window.of_podman_logs [ "2026-09-19T10:00:00Z only line" ] in
  let single_request =
    Judgment.request_json ~model:"jev-latest" ~classifiers sample_facts single
  in
  check "no evidence choice with a single entry"
    (not
       (List.exists
          (Json.member "questions" single_request |> Json.to_assoc)
          ~f:(fun (key, _) -> String.is_prefix key ~prefix:"evidence_")))

(* Https, Secrets, Watch_state, Alert *)

let () =
  let config =
    Https.For_testing.curl_config ~url:"https://example.test" ~bearer:"k\"ey"
      {|{"a":"b\"c\\n"}|}
  in
  check "curl config escapes quotes and backslashes"
    (contains config {|data-binary = "{\"a\":\"b\\\"c\\\\n\"}"|});
  check "bearer is only in the config"
    (contains config {|header = "Authorization: Bearer k\"ey"|});
  (match Https.For_testing.parse_output "{\"ok\":true}\n201" with
  | Ok { status = 201; body = "{\"ok\":true}" } -> ()
  | _ -> check "parses status from write-out" false);
  let secrets =
    Secrets.of_dotenv
      "# comment\nTYPESAFE_API_KEY=ts\nRESEND_API_KEY=\"re_x\"\nOTHER=1\n"
    |> ok_exn "dotenv"
  in
  check "reads keys"
    (String.equal (Secrets.typesafe_api_key secrets) "ts"
    && String.equal (Secrets.resend_api_key secrets) "re_x");
  check "missing key is an error"
    (Result.is_error (Secrets.of_dotenv "TYPESAFE_API_KEY=x"));
  let state : Watch_state.t =
    {
      containers =
        String.Map.singleton "aaa"
          { Watch_state.checked_until = time 1234; restarts = 3 };
      applications =
        String.Map.of_alist_exn
          [
            ("shop/production", { Watch_state.last_alert = Some (time 99) });
            ("x/y", { last_alert = None });
          ];
    }
  in
  let round_trip =
    Watch_state.of_json_string (Watch_state.to_json_string state)
    |> ok_exn "state"
  in
  check "state round-trips"
    (String.equal
       (Watch_state.to_json_string round_trip)
       (Watch_state.to_json_string state));
  check "cooldown blocks early alerts"
    (not
       (Alert.should_alert ~cooldown:(minutes 60)
          ~last_alert:(Some (time 0))
          ~now:(time 3599)));
  check "cooldown allows later alerts"
    (Alert.should_alert ~cooldown:(minutes 60)
       ~last_alert:(Some (time 0))
       ~now:(time 3600))

(* Watch.run_once against fakes *)

type fake = {
  mutable now : Time_ns.t;
  mutable containers : Managed_container.t list Or_error.t;
  mutable logs : string;
  mutable probabilities : (string * float) list;
  mutable evaluate_fails : bool;
  mutable reads : (string * Time_ns.t option * int) list;
  mutable emails : Alert.email list;
}

let runtime fake : Watch.runtime =
  {
    now = (fun () -> fake.now);
    list_containers = (fun () -> return fake.containers);
    read_logs =
      (fun container ~since ~tail ->
        fake.reads <-
          (Managed_container.id container, since, tail) :: fake.reads;
        return (Ok (Log_window.of_podman_logs [ fake.logs ])));
    evaluate =
      (fun request ->
        if fake.evaluate_fails then Deferred.Or_error.error_string "HTTP 529"
        else return (Ok (fake_jev ~probabilities:fake.probabilities request)));
    send_email =
      (fun email ->
        fake.emails <- email :: fake.emails;
        return (Ok ()));
  }

let config : Watch.config =
  {
    model = "jev-latest";
    classifiers;
    threshold = 0.5;
    cooldown = minutes 60;
    interval = minutes 15;
  }

let blue ?(state = Managed_container.Running) ?(restarts = 0) ?started_at () =
  Managed_container.For_testing.create ~id:"blue" ~project:"shop"
    ~target:"production" ~state ~restarts ?started_at ()

let new_fake () =
  {
    now = time 10_000;
    containers = Ok [ blue () ];
    logs = "2026-09-19T10:00:00Z ok\n2026-09-19T10:00:01Z still ok";
    probabilities = [];
    evaluate_fails = false;
    reads = [];
    emails = [];
  }

let last_since fake =
  match fake.reads with (_, since, _) :: _ -> since | [] -> None

let tests () =
  (* Healthy: no email, window advances. *)
  let fake = new_fake () in
  let%bind outcome = Watch.run_once config (runtime fake) Watch_state.empty in
  check "healthy sends nothing" (List.is_empty fake.emails);
  check "healthy is not a failure" (not outcome.failed);
  check "first window looks back one interval"
    (Option.equal Time_ns.equal (last_since fake)
       (Some (Time_ns.sub (time 10_000) (minutes 15))));
  check "healthy advances the window"
    (match Map.find outcome.state.containers "blue" with
    | Some { checked_until; _ } -> Time_ns.equal checked_until (time 10_000)
    | None -> false);
  fake.now <- time 10_900;
  let%bind outcome = Watch.run_once config (runtime fake) outcome.state in
  check "next window starts where the last ended"
    (Option.equal Time_ns.equal (last_since fake) (Some (time 10_000)));
  (* A journal-only classifier never emails. *)
  fake.probabilities <- [ ("warnings", 0.99) ];
  fake.now <- time 11_800;
  let%bind outcome = Watch.run_once config (runtime fake) outcome.state in
  check "journal-only classifiers do not email" (List.is_empty fake.emails);
  check "journal-only classifiers are reported"
    (List.exists outcome.report ~f:(fun line -> contains line "warnings=0.99"));
  (* Emailing classifier: one email, then cooldown, then again. *)
  fake.probabilities <- [ ("crash", 0.97) ];
  fake.logs <-
    "2026-09-19T10:00:00Z booting\n\
     2026-09-19T10:00:01Z killed by OOM\n\
     2026-09-19T10:00:02Z restarting";
  fake.now <- time 12_700;
  let%bind outcome = Watch.run_once config (runtime fake) outcome.state in
  check "flagged classifier emails once" (List.length fake.emails = 1);
  (match fake.emails with
  | email :: _ ->
      check "subject names application and classifier"
        (String.equal email.subject "[nixploy-watch] shop/production: crash");
      check "email quotes the evidence line"
        (contains email.text "> 10:00:01 killed by OOM");
      check "email lists other classifiers"
        (contains email.text "warnings 0.01 (journal only)")
  | [] -> ());
  fake.now <- time 13_600;
  let%bind outcome = Watch.run_once config (runtime fake) outcome.state in
  check "cooldown holds back the next email" (List.length fake.emails = 1);
  check "cooldown is reported"
    (List.exists outcome.report ~f:(fun line ->
         contains line "held back by cooldown"));
  fake.now <- time 16_300;
  let%bind outcome = Watch.run_once config (runtime fake) outcome.state in
  check "emails again after the cooldown" (List.length fake.emails = 2);
  (* Restarts are passed to Jev as a fact. *)
  fake.containers <- Ok [ blue ~restarts:2 () ];
  fake.probabilities <- [];
  let restart_requests = ref [] in
  let spy =
    {
      (runtime fake) with
      evaluate =
        (fun request ->
          restart_requests := request :: !restart_requests;
          (runtime fake).evaluate request);
    }
  in
  fake.now <- time 17_200;
  let%bind outcome = Watch.run_once config spy outcome.state in
  check "restart delta reaches Jev"
    (match !restart_requests with
    | request :: _ ->
        Yojson.Safe.Util.(
          member "state" request |> member "container"
          |> member "restarts_since_last_check"
          |> to_int)
        = 2
    | [] -> false);
  (* A failed evaluation is reported and retried from the same point. *)
  fake.evaluate_fails <- true;
  fake.now <- time 30_000;
  let%bind failed = Watch.run_once config (runtime fake) outcome.state in
  check "failed evaluation marks the run failed" failed.failed;
  check "failed evaluation emails a could-not-check alert"
    (match fake.emails with
    | email :: _ -> contains email.subject "could not be checked"
    | [] -> false);
  check "failed evaluation does not advance the window"
    (match Map.find failed.state.containers "blue" with
    | Some { checked_until; _ } -> Time_ns.equal checked_until (time 17_200)
    | None -> false);
  (* Nothing running: classify the stopped container's tail. *)
  let fake = new_fake () in
  fake.containers <-
    Ok
      [
        blue
          ~state:(Stopped { status = "exited"; exit_code = Some 1 })
          ~started_at:(time 5) ();
      ];
  fake.probabilities <- [ ("crash", 0.9) ];
  let%bind _ = Watch.run_once config (runtime fake) Watch_state.empty in
  check "stopped application reads the tail"
    (match fake.reads with [ ("blue", None, 100) ] -> true | _ -> false);
  check "stopped application can alert" (List.length fake.emails = 1);
  (* Listing failure alerts about the watcher itself. *)
  let fake = new_fake () in
  fake.containers <- Or_error.error_string "podman: cannot connect";
  let%bind outcome = Watch.run_once config (runtime fake) Watch_state.empty in
  check "listing failure is a failure" outcome.failed;
  check "listing failure emails"
    (match fake.emails with
    | [ email ] ->
        String.equal email.subject
          "[nixploy-watch] nixploy-watch: watcher failed"
    | _ -> false);
  (* Removed containers are forgotten. *)
  let fake = new_fake () in
  let%bind outcome = Watch.run_once config (runtime fake) Watch_state.empty in
  fake.containers <- Ok [];
  let%map outcome = Watch.run_once config (runtime fake) outcome.state in
  check "removed containers are forgotten"
    (Map.is_empty outcome.state.containers);
  check "reports when nothing is managed"
    (List.equal String.equal outcome.report
       [ "no nixploy-managed containers found" ])

let () =
  Thread_safe.block_on_async_exn tests;
  if !failures > 0 then (
    eprintf "%d check(s) failed\n" !failures;
    exit 1)
  else print_endline "all checks passed"
