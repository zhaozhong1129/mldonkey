
(* Copyright 2001, 2002 b8_bavard, b8_fee_carabine, INRIA *)
(*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

open Int64
open Printf2

let (++) = Int64.add
let (--) = Int64.sub
let chunk_min_size = ref (Int64.of_int 65000)

let max_buffered = ref (Int64.of_int (1024*1024))

let verbose = false
let max_cache_size = ref 50

let mini (x: int) (y: int) =
  if x > y then y else x

let rights = 0o664

let ro_flag =  [Unix.O_RDONLY]
let rw_flag =  [Unix.O_CREAT; Unix.O_RDWR]

let really_write fd s pos len =
  try
    Unix2.really_write fd s pos len
  with e ->
      lprintf "Exception in really_write: pos=%d len=%d, string length=%d\n"
        pos len (String.length s);
      raise e

module FDCache = struct

    type t = {
        mutable fd : Unix.file_descr option;
        mutable filename : string;
(*        mutable exist : bool; *)
      }

    let cache_size = ref 0
    let cache = Fifo.create ()

    let create f =
(*      let exist = Sys.file_exists f in *)
      {
        filename = f;
        fd = None;
(*        exist = exist; *)
      }

    let close t =
      match t.fd with
      | Some fd ->
(*          lprintf "close_one: closing %d\n" (Obj.magic fd); *)
          (try Unix.close fd with _ -> ());
          t.fd <- None;
          decr cache_size
      | None -> ()

    let rec close_one () =
      if not (Fifo.empty cache) then
        let t = Fifo.take cache in
        match t.fd with
          None ->
            close_one ()
        | Some fd ->
            close t


    let local_force_fd t =
      let fd =
        match t.fd with
          None ->
            if !cache_size >= !max_cache_size then  close_one ();
            let fd =
              try
                Unix.openfile t.filename rw_flag rights
              with Unix.Unix_error(Unix.EACCES,_,_) ->
                  Unix.openfile t.filename ro_flag 0o400
            in
            incr cache_size;
(*            lprintf "local_force: opening %d\n" (Obj.magic fd);  *)
            Fifo.put cache t;
            t.fd <- Some fd;
            fd
        | Some fd -> fd
      in
(*      lprintf "local_force_fd %d\n" (Obj.magic fd); *)
      fd

    let close_all () =
      while not (Fifo.empty cache) do
        close_one ()
      done

    let rename t f =
      close t;
      Unix2.rename t.filename f

    let ftruncate64 t len =
      Unix2.c_ftruncate64 (local_force_fd t) len

    let getsize64 t = Unix2.c_getsize64 t.filename

    let mtime64 t =
      let st = Unix.LargeFile.stat t.filename in
      st.Unix.LargeFile.st_mtime

    let exists t =
      Sys.file_exists t.filename

    let remove t =
      if exists t then Sys.remove t.filename

    let read file file_pos string string_pos len =
      let fd = local_force_fd file in
      let final_pos = Unix2.c_seek64 fd file_pos Unix.SEEK_SET in
      if verbose then lprintf "really_read %d\n" len;
      Unix2.really_read fd string string_pos len

    let write file file_pos string string_pos len =
      let fd = local_force_fd file in
      let final_pos = Unix2.c_seek64 fd file_pos Unix.SEEK_SET in
      if verbose then lprintf "really_write %d\n" len;
      really_write fd string string_pos len

    let copy_chunk t1 t2 pos1 pos2 len64 =
      let buffer_len = 128 * 1024 in
      let buffer_len64 = Int64.of_int buffer_len in
      let buffer = String.make buffer_len '\001' in
      let rec iter remaining pos1 pos2 =
        let len64 = min remaining buffer_len64 in
        let len = Int64.to_int len64 in
        if len > 0 then begin
            read t1 pos1 buffer 0 len;
            write t2 pos2 buffer 0 len;
            iter (remaining -- len64) (pos1 ++ len64) (pos2 ++ len64)
          end
      in
      iter len64 pos1 pos2

  end

module type File =   sig
    type t
    val create : string -> t
    val fd_of_chunk : t -> int64 -> int64 ->
      Unix.file_descr * int64 * string option
    val close : t -> unit
    val rename : t -> string -> unit
    val ftruncate64 : t -> int64 -> unit
    val getsize64 : t -> int64
    val mtime64 : t -> float
    val exists : t -> bool
    val remove : t -> unit
    val read : t -> int64 -> string -> int -> int -> unit
    val write : t -> int64 -> string -> int -> int -> unit
  end


module DiskFile = struct

    type t = FDCache.t

    let create = FDCache.create

    let fd_of_chunk t pos_s len_s =
      let fd = FDCache.local_force_fd t in
      fd, pos_s, None

    let close = FDCache.close

    let rename = FDCache.rename

    let ftruncate64 = FDCache.ftruncate64

    let getsize64 = FDCache.getsize64
    let mtime64 = FDCache.mtime64
    let exists = FDCache.exists
    let remove = FDCache.remove
    let read = FDCache.read
    let write = FDCache.write
  end

let zero_chunk_len = Int64.of_int 65536
let zero_chunk_name = "zero_chunk"
let zero_chunk_fd_option = ref None
let zero_chunk_fd () =
  match !zero_chunk_fd_option with
    Some fd -> fd
  | None ->
      let fd = FDCache.create zero_chunk_name in
      FDCache.ftruncate64 fd zero_chunk_len;
      zero_chunk_fd_option := Some fd;
      fd

module MultiFile = struct

    type file = {
        mutable filename : string;
        mutable pos : int64;
        mutable len : int64;
        mutable current_len : int64;
        mutable fd : FDCache.t;
        mutable tail : file list;
      }

    type t = {
        mutable dirname : string;
        mutable size : int64;
        mutable files : file list;
        mutable tree : btree;
      }

    and btree =
      Node of int64 * btree * btree
    | Leaf of file

    let rec make_tree files =
      match files with
        [||] -> assert false
      | [| file |] -> Leaf file
      | _ ->
          let len = Array.length files in
          let middle = len / 2 in
          let pos = files.(middle).pos in
          Node (pos,
            make_tree (Array.sub files 0 middle),
            make_tree (Array.sub files middle (len - middle)))

    let make_tree files =
      make_tree (Array.of_list (
          List.filter (fun file -> file.len > zero) files))

    let rec find_file tree file_pos =
      match tree with
        Leaf file -> file
      | Node (pos, tree1, tree2) ->
          find_file
            (if file_pos < pos then tree1 else tree2) file_pos

    let rec print_tree indent tree =
      match tree with
        Leaf file -> lprintf "%s  - %s (%Ld,%Ld)\n"
            indent file.filename file.pos file.len
      | Node (pos, tree1, tree2) ->
          lprintf "%scut at %Ld\n" indent pos;
          print_tree (indent ^ "  ") tree1;
          print_tree (indent ^ "  ") tree2

    let rights = 0o664
    let access = [Unix.O_CREAT; Unix.O_RDWR]

    let create dirname files =
      Unix2.safe_mkdir dirname;
      let rec iter files pos files2 =
        match files with
          [] ->
            let rec reverse_files files tail =
              match files with
                [] -> tail
              | file :: others ->
                  file.tail <- tail;
                  reverse_files others (file :: tail)
            in
            let files = reverse_files files2 [] in
            {
              dirname = dirname;
              size = pos;
              files = List.rev files2;
              tree = make_tree files;
            }
        | (filename, size) :: tail ->
            let temp_filename = Filename.concat dirname filename in
            Unix2.safe_mkdir (Filename.dirname temp_filename);
            let fd = FDCache.create temp_filename in
            let _ = FDCache.local_force_fd fd in
            iter tail (pos ++ size)
            ({
                filename = filename;
                pos = pos;
                len = size;
                current_len = FDCache.getsize64 fd;
                fd = fd;
                tail = [];
              } :: files2)

      in
      iter files zero []

    let build t = ()

    let find_file t chunk_begin =
      let file = find_file t.tree chunk_begin in
      file, file.tail

    let do_on_remaining tail arg remaining f =

      let rec iter_files list arg remaining =
        match list with
          [] -> assert false
        | file :: tail ->

            let len = min remaining file.len in
            let arg = f file arg len in
            let remaining = remaining -- len in
            if remaining > zero then
              iter_files tail arg remaining

      in
      iter_files tail arg remaining

    let rec fill_zeros file_out file_pos max_len =
      if max_len > zero then
        let max_possible_write = min max_len zero_chunk_len in
        FDCache.copy_chunk (zero_chunk_fd()) file_out
          zero file_pos max_possible_write;
        fill_zeros file_out (file_pos ++ max_possible_write)
        (max_len -- max_possible_write)


    let fd_of_chunk t chunk_begin chunk_len =
      let (file, tail) = find_file t chunk_begin in
      let chunk_end = chunk_begin ++ chunk_len in
      let file_begin = file.pos in
      let max_current_pos = file_begin ++ file.current_len in
      if max_current_pos >= chunk_end then
        let fd = FDCache.local_force_fd file.fd in
        fd, chunk_begin -- file_begin, None
      else
      let temp_file = Filename.temp_file "chunk" ".tmp" in
      let file_out = FDCache.create temp_file in

(* first file *)
      let in_pos = chunk_begin -- file_begin in
      let in_len = max_current_pos -- chunk_begin in
      FDCache.copy_chunk file.fd file_out
        in_pos  zero in_len;
      let zeros =
        min (chunk_len -- in_len) (file.len -- file.current_len)
      in
      fill_zeros file_out in_len zeros;
      let in_len = in_len ++ zeros in

(* other files *)
      do_on_remaining tail in_len  (chunk_len -- in_len)
      (fun file file_pos len ->
          let max_current_pos = min len file.current_len in
          FDCache.copy_chunk file.fd file_out
            zero file_pos max_current_pos;
          let file_pos = file_pos ++ max_current_pos in
          let zeros = len -- max_current_pos in
          fill_zeros file_out file_pos zeros;
          file_pos ++ zeros
      );
      FDCache.close file_out;
      let fd = FDCache.local_force_fd file_out in
      fd, zero, Some temp_file


    let close t =
      List.iter (fun file -> FDCache.close file.fd) t.files

    let rename t f =
      close t;
      Unix2.rename t.dirname f

      (*
      List.iter (fun file ->
          file.fd.FDCache.filename <- Filename.concat t.dirname file.filename
      ) t.files
*)

    let ftruncate64 t size =
      t.size <- size

    let getsize64 t = t.size

    let mtime64 t =
      let st = Unix.LargeFile.stat t.dirname in
      st.Unix.LargeFile.st_mtime

    let exists t =
      Sys.file_exists t.dirname

    let remove t =
      close t;
      if Sys.file_exists t.dirname then
        Unix2.remove_all_directory t.dirname

    let file_write file in_file_pos s in_string_pos len =
      let len64 = Int64.of_int len in
      let in_file_len = in_file_pos ++ len64 in
      FDCache.write file.fd in_file_pos s in_string_pos len;
      file.current_len <- max file.current_len in_file_len

    let file_read file in_file_pos s in_string_pos len =
      let len64 = Int64.of_int len in
      let in_file_len = in_file_pos ++ len64 in
      if in_file_len <= file.current_len then
        FDCache.read file.fd in_file_pos s in_string_pos len
      else
      let possible_len64 = max zero (file.current_len -- in_file_pos) in
      let possible_len = Int64.to_int possible_len64 in
      if possible_len64 > zero then
        FDCache.read file.fd in_file_pos s in_string_pos possible_len;
      String.fill s (in_string_pos + possible_len) (len - possible_len) '\000'

    let io f t chunk_begin string string_pos len =
      let (file, tail) = find_file t chunk_begin in

      let chunk_len = Int64.of_int len in
      let chunk_end = chunk_begin ++ chunk_len in
      let file_begin = file.pos in
      let file_end = file_begin ++ file.len in
      if file_end >= chunk_end then
        f file (chunk_begin -- file_begin)
        string string_pos len
      else

(* first file *)
      let in_pos = chunk_begin -- file_begin in
      let first_read = file_end -- chunk_begin in
      let in_len = Int64.to_int first_read in
      f file in_pos string string_pos in_len;

(* other files *)
      do_on_remaining tail (string_pos + in_len)
      (chunk_len -- first_read)
      (fun file string_pos len64 ->
          let len = Int64.to_int len64 in
          f file zero string string_pos len;
          string_pos + len
      )

    let read t chunk_begin string string_pos len =
      io file_read t chunk_begin string string_pos len

    let write t chunk_begin string string_pos len =
      io file_write t chunk_begin string string_pos len ;
      let len64 = Int64.of_int len in
      t.size <- max t.size (chunk_begin ++ len64);
      let time = Unix.time () in
      Unix.utimes t.dirname time time;
      ()

  end

module SparseFile = struct
    
    type chunk = {
        mutable chunkname : string;
        mutable pos : int64;
        mutable len : int64;
        mutable fd : FDCache.t;
      }
    
    type t = {
        mutable filename : string;
        mutable dirname : string;
        mutable size : int64;
        mutable chunks : chunk array;
      }
    
    let rights = 0o664
    let access = [Unix.O_CREAT; Unix.O_RDWR]
    
    let zero_chunk () =
      {
        chunkname = zero_chunk_name;
        pos = zero;
        len = zero_chunk_len;
        fd = zero_chunk_fd ();
      }
    
    let create filename =
(*      lprintf "SparseFile.create %s\n" filename; *)
      let dirname = filename ^ ".chunks" in
(*      lprintf "Creating directory %s\n" dirname; *)
      Unix2.safe_mkdir dirname;
      {
        filename = filename;
        dirname = dirname;
        chunks = [||];
        size = zero;
      }
    
    let find_read_pos t pos =
      let nchunks = Array.length t.chunks in
      let rec iter t start len =
        if len <= 0 then start else
        let milen = len/2 in
        let med = start + milen in
        let chunk = t.chunks.(med) in
        if chunk.pos <= pos && pos -- chunk.pos < chunk.len then med else
        if chunk.pos > pos then
          if med = start then start else
            iter t start milen
        else
        let next = med+1 in
        iter t next (start+len-next)
      in
      iter t 0 nchunks
    
    let find_write_pos t pos =
      let nchunks = Array.length t.chunks in
      let rec iter t start len =
        if len <= 0 then start else
        let milen = len/2 in
        let med = start + milen in
        let chunk = t.chunks.(med) in
        if chunk.pos <= pos && pos -- chunk.pos <= chunk.len then med else
        if chunk.pos > pos then
          if med = start then start else
            iter t start milen
        else
        let next = med+1 in
        iter t next (start+len-next)
      in
      iter t 0 nchunks

(*
    let find_read_pos2 t pos =
      let rec iter t i len =
        if i = len then i else
        let chunk = t.chunks.(i) in
        if chunk.pos ++ chunk.len > pos then i else
          iter t (i+1) len
      in
      iter t 0 (Array.length t.chunks)

    let find_write_pos2 t pos =
      let rec iter t i len =
        if i = len then i else
        let chunk = t.chunks.(i) in
        if chunk.pos ++ chunk.len >= pos then i else
          iter t (i+1) len
      in
      iter t 0 (Array.length t.chunks)

    let _ =
      let one = Int64.of_int 1 in
      let two = Int64.of_int 2 in
      let three = Int64.of_int 3 in
      for i = 0 to 3 do
        let chunks = Array.init i (fun i ->
              let name = string_of_int i in
              let pos = 3 * i + 1 in
              let fd = FDCache.create name access rights in
              lprintf " %d [%d - %d]" i pos (pos+2);
              {
                chunkname = name;
                pos = Int64.of_int pos;
                len = two;
                fd = fd;
              }
          ) in
        lprintf "\n";
        let t = {
            filename = "";
            dirname = "";
            size = zero;
            chunks = chunks;
          } in
        for j = 0 to 3 * i + 3 do
          let pos = (Int64.of_int j) in
          let i1 = find_write_pos t pos in
          lprintf "(%d -> %d) " j i1;
          let i2 = find_write_pos2 t pos in
          assert (i1 = i2)
        done;
        lprintf "\n";
      done;
      exit 0
*)
    
    let build t = ()
    
    let fd_of_chunk t chunk_begin chunk_len =
      
      let index = find_read_pos t chunk_begin in
      let nchunks = Array.length t.chunks in
      
      if index < nchunks &&
        ( let chunk = t.chunks.(index) in
          chunk.pos <= chunk_begin &&
          chunk.len >= (chunk_len -- (chunk_begin -- chunk.pos))
        ) then
        
        let chunk = t.chunks.(index) in
        let in_chunk_pos = chunk_begin -- chunk.pos in
        let fd = FDCache.local_force_fd chunk.fd in
        fd, in_chunk_pos, None
      
      else
      
      let temp_file = Filename.temp_file "chunk" ".tmp" in
      let file_out = FDCache.create temp_file in
      
      let rec iter pos index chunk_begin chunk_len =
        
        if chunk_len > zero then
          let chunk =
            if index >= nchunks then 
              let z = zero_chunk () in
              z.pos <- chunk_begin;
              z
            else
            let chunk = t.chunks.(index) in
            let next_pos = chunk.pos in
            if next_pos > chunk_begin then 
              let z = zero_chunk () in
              z.pos <- chunk_begin;
              z.len <- min zero_chunk_len (next_pos -- chunk_begin);
              z
            else
              chunk
          in
          
          let in_chunk_pos = chunk_begin -- chunk.pos in
          let max_len = min chunk_len (chunk.len -- in_chunk_pos) in
          
          FDCache.copy_chunk chunk.fd file_out
            in_chunk_pos pos max_len;
          iter (pos ++ max_len) (index+1) (chunk_begin ++ max_len)
          (chunk_len -- max_len)
      
      in
      iter zero (find_read_pos t chunk_begin) chunk_begin chunk_len;
      
      FDCache.close file_out;
      let fd = FDCache.local_force_fd file_out in
      fd, zero, Some temp_file
    
    let close t =
      Array.iter (fun file -> FDCache.close file.fd) t.chunks
    
    let rename t f =
      close t;
      
      let chunk_begin = zero in
      let chunk_len = t.size in
      let index = 0 in
      let nchunks = Array.length t.chunks in
      
      let file_out = FDCache.create f in
      
      let rec iter pos index chunk_begin chunk_len =
        
        if chunk_len > zero then
          let chunk =
            if index >= nchunks then 
              let z = zero_chunk () in
              z.pos <- chunk_begin;
              z
            else
            let chunk = t.chunks.(index) in
            let next_pos = chunk.pos in
            if next_pos > chunk_begin then 
              let z = zero_chunk () in
              z.pos <- chunk_begin;
              z.len <- min zero_chunk_len (next_pos -- chunk_begin);
              z
              else
              chunk
          in

          let in_chunk_pos = chunk_begin -- chunk.pos in
          let max_len = min chunk_len (chunk.len -- in_chunk_pos) in

          FDCache.copy_chunk chunk.fd file_out
            in_chunk_pos pos max_len;

          if chunk.fd != zero_chunk_fd () then FDCache.remove chunk.fd;

          iter (pos ++ max_len) (index+1) (chunk_begin ++ max_len)
          (chunk_len -- max_len)

      in
      iter zero 0 chunk_begin chunk_len;
      FDCache.close file_out;
      ()
(*
      Sys.rename t.dirname f;
      List.iter (fun file ->
          file.fd.FDCache.filename <- Filename.concat t.dirname file.filename
      ) t.files
*)

    let ftruncate64 t size =
      t.size <- size

    let getsize64 t = t.size

    let mtime64 t =
      let st = Unix.LargeFile.stat t.dirname in
      st.Unix.LargeFile.st_mtime

    let exists t =
      Sys.file_exists t.dirname

    let remove t =
      close t;
(*      lprintf "Removing %s\n" t.dirname; *)
      Unix2.remove_all_directory t.dirname

    let read t chunk_begin string string_pos chunk_len =
      let chunk_len64 = Int64.of_int chunk_len in

      let nchunks = Array.length t.chunks in
      let rec iter string_pos index chunk_begin chunk_len64 =

        if chunk_len64 > zero then
          let chunk =
            if index >= nchunks then
              let z = zero_chunk () in
              z.pos <- chunk_begin;
              z
            else
            let chunk = t.chunks.(index) in
            let next_pos = chunk.pos in
            if next_pos > chunk_begin then 
              let z = zero_chunk () in
              z.pos <- chunk_begin;
              z.len <- min zero_chunk_len (next_pos -- chunk_begin);
              z
            else
              chunk
          in

          let in_chunk_pos = chunk_begin -- chunk.pos in
          let max_len64 = min chunk_len64 (chunk.len -- in_chunk_pos) in
          let max_len = Int64.to_int max_len64 in

          FDCache.read chunk.fd in_chunk_pos string string_pos max_len;
          iter (string_pos + max_len) (index+1) (chunk_begin ++ max_len64)
          (chunk_len64 -- max_len64)


      in
      iter string_pos (find_read_pos t chunk_begin) chunk_begin chunk_len64

    let write t chunk_begin string string_pos len =
      let index = find_write_pos t chunk_begin in

      let len64 = Int64.of_int len in

      let nchunks = Array.length t.chunks in

      if index = Array.length t.chunks then begin
(*          lprintf "Adding chunk at end\n"; *)
          let chunk_name = Int64.to_string chunk_begin in
          let chunk_name = Filename.concat t.dirname chunk_name in
          let fd = FDCache.create chunk_name in
          let chunk = {
              chunkname = chunk_name;
              pos = chunk_begin;
              len = zero;
              fd = fd;
            } in
          let new_array = Array.create (nchunks+1) chunk in
          Array.blit t.chunks 0 new_array 0 nchunks;
          t.chunks <- new_array

        end else
      if t.chunks.(index).pos > chunk_begin then begin
(*          lprintf "Inserting chunk\n"; *)
          let chunk_name = Int64.to_string chunk_begin in
          let chunk_name = Filename.concat t.dirname chunk_name in
          let fd = FDCache.create chunk_name in
          let chunk = {
              chunkname = chunk_name;
              pos = chunk_begin;
              len = zero;
              fd = fd;
            } in
          let new_array = Array.create (nchunks+1) chunk in
          Array.blit t.chunks 0 new_array 0 index;
          Array.blit t.chunks index new_array (index+1) (nchunks-index);
          t.chunks <- new_array;
        end;

      let nchunks = Array.length t.chunks in
      let rec iter index chunk_begin string_pos len =
        if len > 0 then
          let next_index, max_len, max_len64 =
            if index = nchunks-1 then
              index, len, Int64.of_int len
            else
            let max_pos = t.chunks.(index+1).pos in
            let max_possible_len64 = max_pos -- chunk_begin in
            let len64 = Int64.of_int len in
            let max_len64 = min max_possible_len64 len64 in
            let max_len = Int64.to_int max_len64 in
            if max_len64 = max_possible_len64 then
              index+1, max_len, max_len64
            else
              index, max_len, max_len64
          in

          let chunk = t.chunks.(index) in
          let begin_pos = chunk_begin -- chunk.pos in
          FDCache.write chunk.fd begin_pos string string_pos max_len;
          chunk.len <- chunk.len ++ max_len64;

          iter next_index (chunk_begin ++ max_len64)
          (string_pos + max_len) (len - max_len)
      in
      iter index chunk_begin string_pos len;

      t.size <- max t.size (chunk_begin ++ len64);

      let time = Unix.time () in
      Unix.utimes t.dirname time time
  end


type file_kind =
  MultiFile of MultiFile.t
| DiskFile of DiskFile.t
| SparseFile of SparseFile.t

type t = {
    file_kind : file_kind;
    mutable filename : string;
    mutable error : exn option;
    mutable buffers : (string * int * int * int64 * int64) list;
  }

module H = Weak2.Make(struct
      type old_t = t
      type t = old_t
      let hash t = Hashtbl.hash t.filename

      let equal x y  = x.filename = y.filename
    end)

let dummy =  {
    file_kind = DiskFile (DiskFile.create "");
    filename = "";
    error = None;
    buffers = [];
  }

let table = H.create 100

let create f creator =
  try
    let fd = H.find table { dummy with filename = f } in
(*    lprintf "%s already exists\n" f; *)
    fd
  with _ ->
      let t =  {
          file_kind = creator f;
          filename = f;
          error = None;
          buffers = [];
        } in
      H.add table t;
      t

let create_diskfile filename _ _ =
  create filename (fun f -> DiskFile (DiskFile.create f))

let create_multifile filename _ _ files =
  create filename (fun f ->
      MultiFile (MultiFile.create f files))

let create_sparsefile filename =
  create filename (fun f ->
      SparseFile (SparseFile.create f))

let ftruncate64 t len =
  match t.file_kind with
  | DiskFile t -> DiskFile.ftruncate64 t len
  | MultiFile t -> MultiFile.ftruncate64 t len
  | SparseFile t -> SparseFile.ftruncate64 t len

let mtime64 t =
  match t.file_kind with
  | DiskFile t -> DiskFile.mtime64 t
  | MultiFile t -> MultiFile.mtime64 t
  | SparseFile t -> SparseFile.mtime64 t

let getsize64 t =
  match t.file_kind with
  | DiskFile t -> DiskFile.getsize64 t
  | MultiFile t -> MultiFile.getsize64 t
  | SparseFile t -> SparseFile.getsize64 t

(*
For chunked files, we should read read the meta-file instead of the file.
*)

let fds_size = Unix2.c_getdtablesize ()

let buffered_bytes = ref Int64.zero
let modified_files = ref []

(*
let _ =

  lprintf "Your system supports %d file descriptors\n" fds_size;
  lprintf "You can download files up to %s\n\n"
    ( match Unix2.c_sizeofoff_t () with
	|  4 -> "2GB"
	|  _ -> Printf.sprintf "2^%d-1 bits (do the maths ;-p)"
	     ((Unix2.c_sizeofoff_t () *8)-1)			
    )
*)

(* at most 50 files can be opened simultaneously *)

(*
 let seek64 t pos com =
  Unix2.c_seek64 (force_fd t) pos com


*)


let filename t = t.filename

let write file file_pos string string_pos len =
  match file.file_kind with
  | DiskFile t -> DiskFile.write t file_pos string string_pos len
  | MultiFile t -> MultiFile.write t file_pos string string_pos len
  | SparseFile t -> SparseFile.write t file_pos string string_pos len

let buffer = Buffer.create 65000


let flush_buffer t offset =
  if verbose then lprintf "flush_buffer\n";
  let s = Buffer.contents buffer in
  Buffer.clear buffer;
  let len = String.length s in
  try
    if verbose then lprintf "seek64 %Ld\n" offset;
    write t offset s 0 len;
(*
    let fd, offset =  fd_of_chunk t offset (Int64.of_int len) in
    let final_pos = Unix2.c_seek64 fd offset Unix.SEEK_SET in
    if verbose then lprintf "really_write %d\n" len;
    Unix2.really_write fd s 0 len;
*)
    buffered_bytes := !buffered_bytes -- (Int64.of_int len);
    if verbose then lprintf "written %d bytes (%Ld)\n" len !buffered_bytes;
  with e ->
      lprintf "exception %s in flush_buffer\n" (Printexc2.to_string e);
      t.buffers <- (s, 0, len, offset, Int64.of_int len) :: t.buffers;
      raise e

let flush_fd t =
  if t.buffers = [] then () else
  let list =
    List.sort (fun (_, _, _, o1, l1) (_, _, _, o2, l2) ->
        let c = compare o1 o2 in
        if c = 0 then compare l2 l1 else c)
    t.buffers
  in
  if verbose then lprintf "flush_fd\n";
  t.buffers <- list;
  let rec iter_out () =
    match t.buffers with
      [] -> ()
    | (s, pos_s, len_s, offset, len) :: tail ->
        Buffer.clear buffer;
        Buffer.add_substring buffer s pos_s len_s;
        t.buffers <- tail;
        iter_in offset len

  and iter_in offset len =
    match t.buffers with
      [] -> flush_buffer t offset
    | (s, pos_s, len_s, offset2, len2) :: tail ->
        let in_offset = offset ++ len -- offset2 in
        if in_offset = Int64.zero then begin
            Buffer.add_substring buffer s pos_s len_s;
            t.buffers <- tail;
            iter_in offset (len ++ len2);
          end else
        if in_offset < Int64.zero then begin
            flush_buffer t offset;
            iter_out ()
          end else
        let keep_len = len2 -- in_offset in
        if verbose then lprintf "overlap %Ld\n" keep_len;
        t.buffers <- tail;
        if keep_len <= Int64.zero then begin
            buffered_bytes := !buffered_bytes -- len2;
            iter_in offset len
          end else begin
            let new_pos = len2 -- keep_len in
            Buffer.add_substring buffer s
              (pos_s + Int64.to_int new_pos) (Int64.to_int keep_len);
            buffered_bytes := !buffered_bytes -- new_pos;
            iter_in offset (len ++ keep_len)
          end
  in
  iter_out ()

let read t file_pos string string_pos len =
  flush_fd t;
  match t.file_kind with
  | DiskFile t -> DiskFile.read t file_pos string string_pos len
  | MultiFile t -> MultiFile.read t file_pos string string_pos len
  | SparseFile t -> SparseFile.read t file_pos string string_pos len

let flush _ =
  try
    if verbose then lprintf "flush all\n";
    let rec iter list =
      match list with
        [] -> []
      | t :: tail ->
          try
            flush_fd t;
            t.error <- None;
            iter tail
          with e ->
              t.error <- Some e;
              t :: (iter tail)
    in
    modified_files := iter !modified_files;
    if !buffered_bytes <> Int64.zero then
      lprintf "[ERROR] remaining bytes after flush\n"
  with e ->
      lprintf "[ERROR] Exception %s in Unix32.flush\n"
        (Printexc2.to_string e)

let buffered_write t offset s pos_s len_s =
  let len = Int64.of_int len_s in
  match t.error with
    None ->
      if len > Int64.zero then begin
          if not (List.memq t !modified_files) then
            modified_files := t:: !modified_files;
          t.buffers <- (s, pos_s, len_s, offset, len) :: t.buffers;
          buffered_bytes := !buffered_bytes ++ len;
          if verbose then
            lprintf "buffering %Ld bytes (%Ld)\n" len !buffered_bytes;

(* Don't buffer more than 1 Mo *)
          if !buffered_bytes > !max_buffered then flush ()
        end
  | Some e ->
      raise e

let buffered_write_copy t offset s pos_s len_s =
  buffered_write t offset (String.sub s pos_s len_s) 0 len_s

(*
let write t offset s pos_s len_s =
  let fd, offset = fd_of_chunk t offset (Int64.of_int len_s) in
  let final_pos = Unix2.c_seek64 fd offset Unix.SEEK_SET in
  if final_pos <> offset then begin
      lprintf "BAD LSEEK in Unix32.write %Ld/%Ld\n" final_pos offset;
      raise Not_found
    end;

(* if !verbose then begin
      lprintf "{%d-%d = %Ld-%Ld}\n" (t.Q.bloc_begin)
      (t.Q.bloc_len) (begin_pos)
      (end_pos);
    end; *)
  Unix2.really_write fd s pos_s len_s

let read t offset s pos_s len_s =
  flush_fd t;
  let fd, offset = fd_of_chunk t offset (Int64.of_int len_s) in
  let final_pos = Unix2.c_seek64 fd offset Unix.SEEK_SET in

  if final_pos <> offset then begin
      lprintf "BAD LSEEK in Unix32.read %Ld/%Ld\n" final_pos offset;
      raise Not_found
    end;
  Unix2.really_read fd s pos_s len_s
*)

(* zero_chunk is only useful on sparse file systems, not on Windows
  for example *)

let allocate_chunk t offset len64 =
(*
  let len = Int64.to_int len64 in
  let fd, offset = fd_of_chunk t offset len64 in
  let final_pos = Unix2.c_seek64 fd offset Unix.SEEK_SET in
  if final_pos <> offset then begin
      lprintf "BAD LSEEK in Unix32.zero_chunk %Ld/%Ld\n"
        final_pos offset;
      raise Not_found
    end; *)
  let buffer_size = 128 * 1024 in
  let buffer = String.make buffer_size '\001' in
  let rec iter remaining offset =
    let len = mini remaining buffer_size in
    if len > 0 then begin
      write t offset buffer 0 len;
      iter (remaining - len) (offset ++ (Int64.of_int len))
    end
  in
  iter len64 offset

let copy_chunk t1 t2 pos1 pos2 len =
  flush_fd t1;
  flush_fd t2;
  let buffer_size = 128 * 1024 in
  let buffer = String.make buffer_size '\001' in
  let rec iter remaining pos1 pos2 =
    let len = mini remaining buffer_size in
    if len > 0 then begin
      read t1 pos1 buffer 0 len;
      write t2 pos2 buffer 0 len;
      let len64 = Int64.of_int len in
      iter (remaining - len) (pos1 ++ len64) (pos2 ++ len64)
    end
  in
  iter len pos1 pos2

(*
(* Close two file descriptors *)
  assert (!max_cache_size > 2);
  flush_fd t1;
  flush_fd t2;
  FDCache.close_one ();
  FDCache.close_one ();
(*  lprintf "Copying chunk\n"; *)
  let file_in,pos1 = fd_of_chunk t1 pos1 len in
  let file_out,pos2 = fd_of_chunk t2 pos2 len in
  let pos1_after = Unix2.c_seek64 file_in pos1 Unix.SEEK_SET in
  let pos2_after = Unix2.c_seek64 file_out pos2 Unix.SEEK_SET in
(*  lprintf "Seek %Ld/%Ld %Ld/%Ld\n" pos1_after pos1 pos2_after pos2; *)
  let buffer_len = 32768 in
  let len = Int64.to_int len in
  let buffer = String.create buffer_len in
  let rec iter file_in file_out len =
    if len > 0 then
      let can_read = mini buffer_len len in
      let nread = Unix.read file_in buffer 0 can_read in
(*      lprintf "Unix2.really_write %d\n" nread; *)
      Unix2.really_write file_out buffer 0 nread;
      iter file_in file_out (len-nread)
  in
  iter file_in file_out len;
(*  lprintf "Chunk copied\n"; *)
  ()
*)


let close_all = FDCache.close_all
let close t =
  flush_fd t;
  match t.file_kind with
  | DiskFile t -> DiskFile.close t
  | MultiFile t -> MultiFile.close t
  | SparseFile t -> SparseFile.close t

(* let create_ro filename = create_diskfile filename ro_flag 0o666 *)
let create_rw filename = create_diskfile filename rw_flag 0o666
let create_ro = create_rw

let fd_of_chunk t pos len =
  match t.file_kind with
  | DiskFile t -> DiskFile.fd_of_chunk t pos len
  | MultiFile tt ->
      flush_fd t;
      MultiFile.fd_of_chunk tt pos len
  | SparseFile t -> SparseFile.fd_of_chunk t pos len

let exists t =
  flush_fd t;
  match t.file_kind with
  | DiskFile t -> DiskFile.exists t
  | MultiFile t -> MultiFile.exists t
  | SparseFile t -> SparseFile.exists t

let remove t =
  flush_fd t;
  close t;
  match t.file_kind with
  | DiskFile t -> DiskFile.remove t
  | MultiFile t -> MultiFile.remove t
  | SparseFile t -> SparseFile.remove t

let getsize s =  getsize64 (create_ro s)
let mtime s =  mtime64 (create_ro s)

let file_exists s = exists (create_ro s)

let rename t f =
  flush_fd t;
  close t;
  match t.file_kind with
  | DiskFile t -> DiskFile.rename t f
  | MultiFile t -> MultiFile.rename t f
  | SparseFile t -> SparseFile.rename t f


(* module MultiFile_Test = (MultiFile : File) *)
module DiskFile_Test = (DiskFile : File)
module SparseFile_Test = (SparseFile : File)
