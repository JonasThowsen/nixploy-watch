(** What the watcher remembers between runs, stored as JSON in the systemd state
    directory. *)

open Async
open Core

type container = {
  checked_until : Time_ns.t;
      (** The next window starts here; only advanced after a successful
          evaluation, so a failed check is retried with a longer window. *)
  restarts : int;
}

type application = { last_alert : Time_ns.t option }

type t = {
  containers : container String.Map.t;  (** Keyed by container id. *)
  applications : application String.Map.t;  (** Keyed by ["project/target"]. *)
}

val empty : t
val of_json_string : string -> t Or_error.t
val to_json_string : t -> string

val load : path:string -> t Deferred.Or_error.t
(** A missing file is the empty state. *)

val save : path:string -> t -> unit Deferred.Or_error.t
(** Writes a temporary file and renames it over [path]. *)
