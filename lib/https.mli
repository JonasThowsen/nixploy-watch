(** JSON POSTs through curl. The whole request, including the bearer token and
    body, is passed as a curl config on stdin so no secret reaches argv. *)

open Async
open Core

type response = { status : int; body : string }

val post_json :
  ?curl:string ->
  ?retry_delays:Time_ns.Span.t list ->
  url:string ->
  bearer:string ->
  Yojson.Safe.t ->
  response Deferred.Or_error.t
(** Retries transport failures, 429 and 5xx (including TypeSafe's 529) once per
    entry of [retry_delays] (default 2s, 10s). *)

val typesafe_url : string
val resend_url : string

val typesafe_system_one :
  ?url:string -> api_key:string -> Yojson.Safe.t -> string Deferred.Or_error.t
(** Returns the response body of a successful evaluation. *)

val resend_email :
  ?url:string -> api_key:string -> Yojson.Safe.t -> unit Deferred.Or_error.t

module For_testing : sig
  val curl_config : url:string -> bearer:string -> string -> string
  val parse_output : string -> response Or_error.t
end
