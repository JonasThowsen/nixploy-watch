(** Reads the local Podman (the watcher runs on the target host as the account
    that owns nixploy's containers). Read-only: nothing here starts, stops or
    removes anything. *)

open Async
open Core

val list_managed : podman:string -> Managed_container.t list Deferred.Or_error.t

val read_logs :
  podman:string ->
  Managed_container.t ->
  since:Time_ns.t option ->
  tail:int ->
  Log_window.t Deferred.Or_error.t

val since_argument : Time_ns.t -> string
(** RFC 3339 in UTC, as [podman logs --since] expects. *)
