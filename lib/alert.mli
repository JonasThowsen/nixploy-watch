(** What an email reports, when one may be sent, and how it reads. *)

open Core

type problem =
  | Flagged of {
      facts : Judgment.facts;
      window : Log_window.t;
      judgment : Judgment.t;
      flagged : Judgment.classification list;  (** Non-empty. *)
    }
  | Not_checked of { container : Managed_container.t; error : Error.t }
  | Watcher_failed of Error.t

val should_alert :
  cooldown:Time_ns.Span.t ->
  last_alert:Time_ns.t option ->
  now:Time_ns.t ->
  bool

type email = { subject : string; text : string }

val render : application:string -> problem list -> email
val resend_request : from:string -> to_:string list -> email -> Yojson.Safe.t
