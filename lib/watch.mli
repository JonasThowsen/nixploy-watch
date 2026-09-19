(** One check of every nixploy application on this host.

    For each running container, the log lines written since its last successful
    check are classified by Jev. An application whose containers are all stopped
    is classified from the tail of its most recently started container. One
    email per application reports every emailing classifier at or above the
    threshold, at most once per cooldown. *)

open Async
open Core

type config = {
  model : string;
  classifiers : Classifier.t list;
  threshold : float;
  cooldown : Time_ns.Span.t;
  interval : Time_ns.Span.t;
      (** How far back the first check of a newly seen container looks. *)
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
      (** POST a System One request; returns the response body. *)
  send_email : Alert.email -> unit Deferred.Or_error.t;
}

type outcome = {
  state : Watch_state.t;
  report : string list;
      (** One line per container or event, for the journal. *)
  failed : bool;
      (** A container could not be checked or an alert could not be sent. *)
}

val watcher_key : string
(** The state and alert key for failures of the watcher itself. *)

val run_once : config -> runtime -> Watch_state.t -> outcome Deferred.t
