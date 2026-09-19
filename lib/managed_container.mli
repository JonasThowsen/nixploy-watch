open Core

type state = Running | Stopped of { status : string; exit_code : int option }
type t

val all_managed_of_json : string -> t list Or_error.t
(** Parses [podman ps --all --format json] output and keeps only containers
    carrying nixploy's ownership labels ([io.nixploy.managed=true] with a
    project and target). Unlabelled containers are ignored, not rejected. *)

val id : t -> string
val name : t -> string
val project : t -> string
val target : t -> string

val application : t -> string
(** ["project/target"]; containers of one application share it across blue/green
    slots and redeployments. *)

val revision : t -> string option
val state : t -> state
val state_description : t -> string
val restarts : t -> int
val started_at : t -> Time_ns.t option

module For_testing : sig
  val create :
    id:string ->
    ?name:string ->
    project:string ->
    target:string ->
    ?revision:string ->
    state:state ->
    ?restarts:int ->
    ?started_at:Time_ns.t ->
    unit ->
    t
end
