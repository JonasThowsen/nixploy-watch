open Async
open Core
open Nixploy_watch

let read_classifiers = function
  | None -> return (Ok Classifier.defaults)
  | Some path ->
      Monitor.try_with_or_error (fun () -> Reader.file_contents path)
      >>| Or_error.bind ~f:Classifier.list_of_json_string
      >>| Or_error.tag ~tag:(sprintf "could not load classifiers from %s" path)

let state_file_path = function
  | Some path -> Ok path
  | None -> (
      match Sys.getenv "STATE_DIRECTORY" with
      | Some directory ->
          (* systemd may list several directories separated by colons. *)
          let directory = List.hd_exn (String.split directory ~on:':') in
          Ok (Filename.concat directory "state.json")
      | None -> Or_error.error_string "--state-file is required outside systemd"
      )

let print_email (email : Alert.email) =
  printf "--- would email ---\nSubject: %s\n\n%s--- end ---\n" email.subject
    email.text;
  return (Ok ())

let check_command =
  Async.Command.async_or_error
    ~summary:
      "Classify recent logs of nixploy-managed containers and email on problems"
    ~readme:(fun () ->
      "Run once per interval (the NixOS module uses a systemd timer). The \
       secrets file is a SOPS-encrypted dotenv defining TYPESAFE_API_KEY and \
       RESEND_API_KEY; sops finds its key through SOPS_AGE_KEY_FILE or \
       SOPS_AGE_SSH_PRIVATE_KEY_FILE.")
    (let%map_open.Command secrets =
       flag "--secrets" (required string)
         ~doc:
           "FILE SOPS-encrypted dotenv with TYPESAFE_API_KEY and RESEND_API_KEY"
     and state_file =
       flag "--state-file" (optional string)
         ~doc:
           "FILE where checks are remembered (default: \
            $STATE_DIRECTORY/state.json)"
     and to_ =
       flag "--to"
         (one_or_more_as_list string)
         ~doc:"ADDRESS alert recipient (repeatable)"
     and from =
       flag "--from" (required string)
         ~doc:"ADDRESS sender, e.g. 'nixploy-watch <alerts@example.com>'"
     and classifiers =
       flag "--classifiers" (optional string)
         ~doc:"FILE JSON classifiers (default: built-in; see `classifiers`)"
     and model =
       flag "--model"
         (optional_with_default "jev-latest" string)
         ~doc:"MODEL TypeSafe model (default: jev-latest)"
     and threshold =
       flag "--threshold"
         (optional_with_default 0.5 float)
         ~doc:"P classifier probability that counts as yes (default: 0.5)"
     and cooldown_minutes =
       flag "--cooldown-minutes"
         (optional_with_default 60 int)
         ~doc:
           "N minimum minutes between emails for one application (default: 60)"
     and interval_minutes =
       flag "--interval-minutes"
         (optional_with_default 15 int)
         ~doc:
           "N how far back a newly seen container is first checked (default: \
            15)"
     and podman =
       flag "--podman"
         (optional_with_default "podman" string)
         ~doc:"PROG Podman executable (default: podman)"
     and typesafe_url =
       flag "--typesafe-url"
         (optional_with_default Https.typesafe_url string)
         ~doc:"URL System One endpoint (for testing)"
     and resend_url =
       flag "--resend-url"
         (optional_with_default Https.resend_url string)
         ~doc:"URL Resend emails endpoint (for testing)"
     and dry_run =
       flag "--dry-run" no_arg
         ~doc:" print alerts instead of emailing them and do not save state"
     in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       let%bind state_file = Deferred.return (state_file_path state_file) in
       let%bind classifiers = read_classifiers classifiers in
       let%bind () =
         if Float.(threshold > 0. && threshold <= 1.) then return ()
         else Deferred.Or_error.error_string "--threshold must be in (0, 1]"
       in
       let%bind secrets = Secrets.load ~path:secrets () in
       let%bind state =
         match%bind.Deferred Watch_state.load ~path:state_file with
         | Ok state -> return state
         | Error error ->
             (* A corrupt state file must not stop monitoring; the cost is one
                re-checked window per container. *)
             eprintf "ignoring unreadable state: %s\n"
               (Error.to_string_hum error);
             return Watch_state.empty
       in
       let config : Watch.config =
         {
           model;
           classifiers;
           threshold;
           cooldown = Time_ns.Span.of_int_sec (cooldown_minutes * 60);
           interval = Time_ns.Span.of_int_sec (interval_minutes * 60);
         }
       in
       let runtime : Watch.runtime =
         {
           now = Time_ns.now;
           list_containers = (fun () -> Podman.list_managed ~podman);
           read_logs = Podman.read_logs ~podman;
           evaluate =
             Https.typesafe_system_one ~url:typesafe_url
               ~api_key:(Secrets.typesafe_api_key secrets);
           send_email =
             (if dry_run then print_email
              else fun email ->
                Https.resend_email ~url:resend_url
                  ~api_key:(Secrets.resend_api_key secrets)
                  (Alert.resend_request ~from ~to_ email));
         }
       in
       let%bind.Deferred outcome = Watch.run_once config runtime state in
       List.iter outcome.report ~f:print_endline;
       let%bind () =
         if dry_run then return ()
         else Watch_state.save ~path:state_file outcome.state
       in
       if outcome.failed then
         Deferred.Or_error.error_string
           "some checks or alerts failed; see above"
       else return ())

let classifiers_command =
  Command.basic
    ~summary:"Print the built-in classifiers as JSON, to copy and edit"
    (Command.Param.return (fun () ->
         print_string (Classifier.list_to_json_string Classifier.defaults)))

let () =
  Command.group
    ~summary:
      "Watch nixploy-managed containers with Jev and email about problems"
    [ ("check", check_command); ("classifiers", classifiers_command) ]
  |> Command_unix.run
