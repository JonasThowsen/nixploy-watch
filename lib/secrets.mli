(** API keys from a SOPS-encrypted dotenv file, decrypted with [sops] the way
    nixploy decrypts target secrets. Decryption keys come from sops' usual
    environment ([SOPS_AGE_KEY_FILE] or [SOPS_AGE_SSH_PRIVATE_KEY_FILE]). *)

open Async
open Core

type t

val load : ?sops:string -> path:string -> unit -> t Deferred.Or_error.t
val typesafe_api_key : t -> string
val resend_api_key : t -> string

val of_dotenv : string -> t Or_error.t
(** Requires [TYPESAFE_API_KEY] and [RESEND_API_KEY]; other variables are
    ignored. *)
