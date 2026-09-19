(** A bounded, redacted view of the log lines one container wrote in a window.

    Entries are what Jev reads: each is tagged with a line id ([L000] ...) so a
    Choice question can point back at it, which is how alert emails quote
    evidence without the model generating text. *)

type entry = private {
  time : string option;  (** [HH:MM:SS] of the first occurrence. *)
  count : int;  (** Occurrences of messages that differ only in digits. *)
  text : string;
}

type t

val empty : t

val of_podman_logs : string list -> t
(** Takes the stdout and stderr of [podman logs --timestamps], merges them
    chronologically, strips terminal escapes, redacts credential-shaped values,
    merges messages that differ only in digits, and bounds the result to
    [max_entries] entries and [max_bytes] of text. When over budget, messages
    that look like problems are kept before others, then the most recent. *)

val max_entries : int
(** At most 250, below TypeSafe's 255-option limit for Choice questions. *)

val max_bytes : int
val is_empty : t -> bool
val entries : t -> entry list
val entry_count : t -> int
val total_lines : t -> int
val omitted_messages : t -> int
val line_id : int -> string
val index_of_line_id : string -> int option
val render_entry : entry -> string

val tagged_text : t -> string
(** One [Lnnn| HH:MM:SS [xN] message] line per entry. *)

module For_testing : sig
  val redact : string -> string
  val sanitize : string -> string
end
