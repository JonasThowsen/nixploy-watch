(** One TypeSafe System One request per log window: a Noul question per
    classifier, plus, for each emailing classifier, a Choice over line ids that
    selects the line that best shows it. *)

open Core

type facts = {
  project : string;
  target : string;
  container : string;
  revision : string option;
  container_state : string;
  restarts_since_last_check : int;
  window_start : Time_ns.t option;
      (** [None] when the window is the tail of a stopped container. *)
  window_end : Time_ns.t;
}

type classification = {
  classifier : Classifier.t;
  probability : float;
  evidence : (int * float) list;
      (** Entry indices, most probable first; empty for classifiers that do not
          email. *)
}

type t

val request_json :
  model:string ->
  classifiers:Classifier.t list ->
  facts ->
  Log_window.t ->
  Yojson.Safe.t

val of_response :
  classifiers:Classifier.t list -> Log_window.t -> string -> t Or_error.t

val model : t -> string

val classifications : t -> classification list
(** In classifier order. *)

val flagged : threshold:float -> t -> classification list
(** Emailing classifiers at or above [threshold], most probable first. *)

module For_testing : sig
  val create : model:string -> classification list -> t
end
