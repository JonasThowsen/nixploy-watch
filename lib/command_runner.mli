open Async
open Core

type t = {
  stdout : string;
  stderr : string;
  exit_status : Core_unix.Exit_or_signal.t;
}

val run :
  ?stdin:string ->
  timeout:Time_ns.Span.t ->
  prog:string ->
  args:string list ->
  unit ->
  t Deferred.Or_error.t
(** Runs [prog] with a fixed argv (no shell). Secrets must travel on [stdin],
    never [args]. The process is killed when [timeout] elapses. *)

val run_stdout :
  ?stdin:string ->
  timeout:Time_ns.Span.t ->
  prog:string ->
  args:string list ->
  unit ->
  string Deferred.Or_error.t
(** Like [run], but a nonzero exit is an error carrying bounded stderr. *)
