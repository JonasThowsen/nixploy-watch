(** A yes/no question Jev answers about every log window, and whether a "yes"
    should email the operator. *)

open Core

type t

val create :
  name:string ->
  question:string ->
  yes:string ->
  no:string ->
  email:bool ->
  t Or_error.t
(** [name] is 1-64 characters of [a-z0-9_]. [question] may refer to the state
    fields [log] and [container] in backticks; [yes] and [no] describe what each
    answer means. *)

val name : t -> string
val question : t -> string
val yes : t -> string
val no : t -> string
val email : t -> bool

val defaults : t list
(** Problems that email by default: crash, unhandled_errors, dependency_failure,
    failing_requests, resource_exhaustion and configuration_problem. Recorded in
    the journal only: security_event and noisy_warnings. *)

val list_of_json_string : string -> t list Or_error.t
(** A non-empty JSON array of [{name, question, yes, no, email}] objects with
    unique names. *)

val list_to_json_string : t list -> string
