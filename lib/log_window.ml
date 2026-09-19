open Core

type entry = { time : string option; count : int; text : string }

type t = {
  entries : entry list;
  entry_count : int;
  total_lines : int;
  omitted_messages : int;
}

let max_entries = 250
let max_bytes = 48_000
let max_line_bytes = 400

let empty =
  { entries = []; entry_count = 0; total_lines = 0; omitted_messages = 0 }

let is_empty t = List.is_empty t.entries
let entries t = t.entries
let entry_count t = t.entry_count
let total_lines t = t.total_lines
let omitted_messages t = t.omitted_messages
let line_id index = sprintf "L%03d" index

let index_of_line_id id =
  match String.chop_prefix id ~prefix:"L" with
  | Some digits when String.for_all digits ~f:Char.is_digit ->
      Int.of_string_opt digits
  | _ -> None

(* Same keys and value rules as nixploy's Podman log redaction, so the watcher
   never sends more to TypeSafe or Resend than `nixploy logs` would show. *)
let secret_keys =
  [
    "authorization";
    "database_url";
    "api_key";
    "api-key";
    "password";
    "passwd";
    "token";
    "secret";
    "cookie";
  ]

let redact line =
  let length = String.length line in
  let lowercase = String.lowercase line in
  let buffer = Buffer.create length in
  let rec skip_spaces index =
    if index < length && Char.is_whitespace line.[index] then
      skip_spaces (index + 1)
    else index
  in
  let rec loop position =
    let found =
      List.filter_map secret_keys ~f:(fun key ->
          String.substr_index lowercase ~pos:position ~pattern:key
          |> Option.map ~f:(fun index -> (index, key)))
      |> List.min_elt ~compare:(fun (left, _) (right, _) ->
          Int.compare left right)
    in
    match found with
    | None ->
        Buffer.add_substring buffer line ~pos:position ~len:(length - position)
    | Some (index, key) ->
        let after_key = index + String.length key in
        let after_key =
          if after_key < length && Char.equal line.[after_key] '"' then
            after_key + 1
          else after_key
        in
        let separator = skip_spaces after_key in
        if
          separator >= length
          || not
               (Char.equal line.[separator] ':'
               || Char.equal line.[separator] '=')
        then (
          Buffer.add_substring buffer line ~pos:position
            ~len:(after_key - position);
          loop after_key)
        else
          let value_start = skip_spaces (separator + 1) in
          let quote =
            if
              value_start < length
              && (Char.equal line.[value_start] '"'
                 || Char.equal line.[value_start] '\'')
            then Some line.[value_start]
            else None
          in
          let secret_start =
            if Option.is_some quote then value_start + 1 else value_start
          in
          let ends_value character =
            match quote with
            | Some quote -> Char.equal character quote
            | None ->
                if String.equal key "authorization" || String.equal key "cookie"
                then Char.equal character ',' || Char.equal character ';'
                else
                  Char.is_whitespace character
                  || Char.equal character ',' || Char.equal character ';'
          in
          let rec value_end index =
            if index >= length || ends_value line.[index] then index
            else value_end (index + 1)
          in
          let secret_end = value_end secret_start in
          Buffer.add_substring buffer line ~pos:position
            ~len:(secret_start - position);
          if secret_end > secret_start then
            Buffer.add_string buffer "[REDACTED]";
          loop secret_end
  in
  loop 0;
  Buffer.contents buffer

(* Drops ANSI escape sequences and control characters and replaces invalid
   UTF-8, so the JSON sent to TypeSafe and Resend is always valid text. *)
let sanitize text =
  let length = String.length text in
  let buffer = Stdlib.Buffer.create length in
  let rec skip_escape index =
    if index >= length then index
    else
      let code = Char.to_int text.[index] in
      if code >= 0x40 && code <= 0x7e then index + 1 else skip_escape (index + 1)
  in
  let rec loop index =
    if index < length then (
      if
        Char.equal text.[index] '\027'
        && index + 1 < length
        && Char.equal text.[index + 1] '['
      then loop (skip_escape (index + 2))
      else
        let decoded = Stdlib.String.get_utf_8_uchar text index in
        let consumed = Stdlib.Uchar.utf_decode_length decoded in
        (if not (Stdlib.Uchar.utf_decode_is_valid decoded) then
           Stdlib.Buffer.add_utf_8_uchar buffer Stdlib.Uchar.rep
         else
           let uchar = Stdlib.Uchar.utf_decode_uchar decoded in
           let code = Stdlib.Uchar.to_int uchar in
           if code = 0x09 then Stdlib.Buffer.add_char buffer ' '
           else if code < 0x20 || (code >= 0x7f && code < 0xa0) then ()
           else Stdlib.Buffer.add_utf_8_uchar buffer uchar);
        loop (index + consumed))
  in
  loop 0;
  Stdlib.Buffer.contents buffer

let truncate text =
  if String.length text <= max_line_bytes then text
  else
    (* Back off to a UTF-8 character boundary. *)
    let rec boundary index =
      if index > 0 && Char.to_int text.[index] land 0xc0 = 0x80 then
        boundary (index - 1)
      else index
    in
    String.prefix text (boundary max_line_bytes) ^ "…"

let parse_line line =
  match String.lsplit2 line ~on:' ' with
  | Some (stamp, text)
    when String.length stamp >= 19 && Char.equal stamp.[10] 'T' -> (
      match
        Option.try_with (fun () -> Time_ns.of_string_with_utc_offset stamp)
      with
      | Some time -> (Some time, Some (String.sub stamp ~pos:11 ~len:8), text)
      | None -> (None, None, line))
  | _ -> (None, None, line)

(* A line without a parsable timestamp inherits the previous line's time so it
   stays next to it when stdout and stderr are merged. *)
let timed_lines output =
  String.split_lines output
  |> List.filter ~f:(fun line -> not (String.is_empty (String.strip line)))
  |> List.folding_map ~init:None ~f:(fun previous line ->
      let time, clock, text = parse_line line in
      let effective = Option.first_some time previous in
      (effective, (effective, clock, text)))

let merge_key text =
  let buffer = Buffer.create (String.length text) in
  String.iteri text ~f:(fun index character ->
      if Char.is_digit character then (
        if index = 0 || not (Char.is_digit text.[index - 1]) then
          Buffer.add_char buffer '#')
      else Buffer.add_char buffer character);
  Buffer.contents buffer

let collapse lines =
  let seen = Hashtbl.create (module String) in
  let order = Queue.create () in
  List.iter lines ~f:(fun (_, time, text) ->
      let text = text |> sanitize |> redact |> String.strip |> truncate in
      if not (String.is_empty text) then
        let key = merge_key text in
        match Hashtbl.find seen key with
        | Some entry -> entry := { !entry with count = !entry.count + 1 }
        | None ->
            let entry = ref { time; count = 1; text } in
            Hashtbl.set seen ~key ~data:entry;
            Queue.enqueue order entry);
  Queue.to_list order |> List.map ~f:( ! )

let problem_words =
  [
    "error";
    "exception";
    "fatal";
    "panic";
    "fail";
    "crash";
    "traceback";
    "timeout";
    "timed out";
    "refused";
    "killed";
    "out of memory";
    "denied";
    "unavailable";
    "warn";
  ]

let looks_like_problem text =
  let lowercase = String.lowercase text in
  List.exists problem_words ~f:(fun word ->
      String.is_substring lowercase ~substring:word)

let entry_size entry = String.length entry.text + 24

let bound entries =
  let total_size = List.sum (module Int) entries ~f:entry_size in
  if List.length entries <= max_entries && total_size <= max_bytes then
    (entries, 0)
  else
    let indexed = List.mapi entries ~f:(fun index entry -> (index, entry)) in
    let problems, others =
      List.partition_tf indexed ~f:(fun (_, entry) ->
          looks_like_problem entry.text)
    in
    let kept, _, _ =
      List.fold
        (List.rev problems @ List.rev others)
        ~init:([], 0, 0)
        ~f:(fun (kept, count, bytes) (index, entry) ->
          let size = entry_size entry in
          if count < max_entries && bytes + size <= max_bytes then
            ((index, entry) :: kept, count + 1, bytes + size)
          else (kept, count, bytes))
    in
    let kept =
      List.sort kept ~compare:(fun (left, _) (right, _) ->
          Int.compare left right)
      |> List.map ~f:snd
    in
    (kept, List.length entries - List.length kept)

let of_podman_logs outputs =
  let lines =
    List.concat_map outputs ~f:timed_lines
    |> List.stable_sort ~compare:(fun (left, _, _) (right, _, _) ->
        Option.compare Time_ns.compare left right)
  in
  let entries, omitted_messages = bound (collapse lines) in
  {
    entries;
    entry_count = List.length entries;
    total_lines = List.length lines;
    omitted_messages;
  }

let render_entry entry =
  [
    entry.time;
    (if entry.count > 1 then Some (sprintf "[x%d]" entry.count) else None);
    Some entry.text;
  ]
  |> List.filter_opt |> String.concat ~sep:" "

let tagged_text t =
  List.mapi t.entries ~f:(fun index entry ->
      sprintf "%s| %s" (line_id index) (render_entry entry))
  |> String.concat ~sep:"\n"

module For_testing = struct
  let redact = redact
  let sanitize = sanitize
end
