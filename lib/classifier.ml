open Core

type t = {
  name : string;
  question : string;
  yes : string;
  no : string;
  email : bool;
}

let name t = t.name
let question t = t.question
let yes t = t.yes
let no t = t.no
let email t = t.email

let valid_name name =
  (not (String.is_empty name))
  && String.length name <= 64
  && String.for_all name ~f:(fun character ->
      Char.is_lowercase character
      || Char.is_digit character || Char.equal character '_')

let create ~name ~question ~yes ~no ~email =
  let blank text = String.is_empty (String.strip text) in
  if not (valid_name name) then
    Or_error.errorf
      "classifier name %S must be 1-64 characters of a-z, 0-9 and _" name
  else if blank question || blank yes || blank no then
    Or_error.errorf "classifier %s needs a non-empty question, yes and no" name
  else Ok { name; question; yes; no; email }

let defaults =
  [
    {
      name = "crash";
      question =
        "Does `log` or `container` show the application process crashing, \
         panicking, being killed, exiting unexpectedly, restarting, or not \
         running?";
      yes =
        "The process crashed, panicked, was killed (for example by the \
         out-of-memory killer), exited with an error, restarted \
         (`container.restarts_since_last_check` is above 0), or \
         `container.state` is not running.";
      no = "The process kept running normally for the whole window.";
      email = true;
    };
    {
      name = "unhandled_errors";
      question =
        "Does `log` show unhandled exceptions, stack traces, or error-level \
         messages from the application's own code?";
      yes =
        "Exceptions, stack traces or error-level messages that the application \
         did not recover from.";
      no =
        "No errors, or only errors that were handled, retried successfully, or \
         are expected, such as a user entering a wrong password.";
      email = true;
    };
    {
      name = "dependency_failure";
      question =
        "Does `log` show the application failing to reach something it depends \
         on, such as a database, cache, message queue, mail server or external \
         API?";
      yes =
        "Connections refused, timed out or dropped, or failed DNS lookups to a \
         dependency, without a successful recovery afterwards.";
      no =
        "Dependencies respond normally, or a brief failure was retried and \
         recovered.";
      email = true;
    };
    {
      name = "failing_requests";
      question = "Does `log` show user requests or background jobs failing?";
      yes =
        "HTTP 5xx responses, failed or discarded background jobs, or \
         operations reporting failure, more than an isolated occurrence.";
      no =
        "Requests and jobs succeed. Client errors such as 404 or 401 are \
         normal traffic.";
      email = true;
    };
    {
      name = "resource_exhaustion";
      question = "Does `log` show the application running out of a resource?";
      yes =
        "Out of memory, disk full, too many open files or connections, an \
         exhausted connection pool, or requests timing out because the system \
         is overloaded.";
      no = "No sign of resource pressure.";
      email = true;
    };
    {
      name = "configuration_problem";
      question = "Does `log` show missing or invalid configuration?";
      yes =
        "Missing environment variables or secrets, invalid settings, failed or \
         pending database migrations, or permission denied on files the \
         application needs.";
      no = "Configuration loads normally.";
      email = true;
    };
    {
      name = "security_event";
      question = "Does `log` show signs of an attack or a security problem?";
      yes =
        "Bursts of failed logins, scanning for vulnerable paths, injection \
         attempts, or access granted where it should not be.";
      no =
        "Ordinary traffic. Occasional 404s or a single failed login are normal \
         on a public server.";
      email = false;
    };
    {
      name = "noisy_warnings";
      question =
        "Does `log` contain warnings or deprecation notices that do not \
         currently affect users?";
      yes =
        "Warnings, deprecation notices or slow-query notices while the \
         application otherwise works.";
      no = "No such warnings.";
      email = false;
    };
  ]

let validate_all classifiers =
  if List.is_empty classifiers then
    Or_error.error_string "at least one classifier is required"
  else
    match
      List.find_a_dup classifiers ~compare:(fun left right ->
          String.compare left.name right.name)
    with
    | Some duplicate ->
        Or_error.errorf "classifier %s is defined more than once" duplicate.name
    | None -> Ok classifiers

let of_json = function
  | `Assoc fields ->
      let open Or_error.Let_syntax in
      let field key = List.Assoc.find fields ~equal:String.equal key in
      let string key =
        match field key with
        | Some (`String value) -> Ok value
        | _ -> Or_error.errorf "classifier field %s must be a string" key
      in
      let%bind name = string "name"
      and question = string "question"
      and yes = string "yes"
      and no = string "no"
      and email =
        match field "email" with
        | Some (`Bool email) -> Ok email
        | _ -> Or_error.error_string "classifier field email must be a boolean"
      in
      create ~name ~question ~yes ~no ~email
  | _ -> Or_error.error_string "each classifier must be a JSON object"

let list_of_json_string input =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string input)
    |> Or_error.tag ~tag:"classifiers are not valid JSON"
  in
  match json with
  | `List items ->
      let%bind classifiers = List.map items ~f:of_json |> Or_error.all in
      validate_all classifiers
  | _ -> Or_error.error_string "classifiers must be a JSON array"

let to_json t =
  `Assoc
    [
      ("name", `String t.name);
      ("question", `String t.question);
      ("yes", `String t.yes);
      ("no", `String t.no);
      ("email", `Bool t.email);
    ]

let list_to_json_string classifiers =
  Yojson.Safe.pretty_to_string (`List (List.map classifiers ~f:to_json)) ^ "\n"
