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

open Printf2
open Md4

open CommonShared
open CommonServer
open CommonComplexOptions
open GuiProto
open CommonClient
open CommonFile
open CommonUser
open CommonSearch
open CommonTypes
open Options
open BasicSocket
open TcpBufferedSocket
open DonkeyMftp
open DonkeyOneFile
open DonkeyProtoCom
open DonkeyTypes
open DonkeyGlobals
open DonkeyComplexOptions
open DonkeyOptions
open CommonOptions
open DonkeyClient  
open CommonGlobals
open DonkeyStats

module Udp = DonkeyProtoUdp 

let search_handler s t =
  let waiting = s.search_waiting - 1 in
  s.search_waiting <- waiting;
  List.iter (fun f ->
      search_found false s f.f_md4 f.f_tags
  ) t
(*  search.search_handler (Waiting s.search_waiting) *)
    
let udp_query_locations file s =
  if !verbose then begin
      lprintf "UDP: query location %s" (Ip.to_string s.server_ip);
      lprint_newline ();
    end;
  let module Udp = DonkeyProtoUdp in
  udp_server_send s (Udp.QueryLocationUdpReq file.file_md4)

  (*
let rec find_search_rec num list =
  match list with
    [] -> raise Not_found
  | s :: tail ->
      if s.search_search.search_num = num then s else 
        find_search_rec num tail
        
let find_search num = find_search_rec num !local_searches
    *)

let cut_for_udp_send max_servers list =
  let min_last_conn = last_time () - 8 * 3600 in
  let rec iter list n left =
    if n = 0 then 
      left, list
    else
    match list with 
      [] -> left, []
    | s :: tail ->
        if connection_last_conn s.server_connection_control > min_last_conn
        then
          iter tail (n-1) (s :: left)
        else
          iter tail n left
  in
  iter list max_servers []

let make_xs ss =
  if ss.search_num <> !xs_last_search then begin
      xs_last_search := ss.search_num;
      xs_servers_list := Hashtbl2.to_list servers_by_key;
    end;
  
  let before, after = cut_for_udp_send !!max_xs_packets !xs_servers_list in
  xs_servers_list := after;
  List.iter (fun s ->
      match s.server_sock with
      | Some sock -> ()
      | None ->
          let module M = DonkeyProtoServer in
          let module Q = M.Query in
          udp_server_send s (Udp.QueryUdpReq ss.search_query);
  ) before;
  
  DonkeyOvernet.overnet_search ss
          
let force_check_locations () =
  try
    
    let before, after = cut_for_udp_send !!max_udp_sends !udp_servers_list in
    udp_servers_list := after;
    
    List.iter (fun file -> 
        if file_state file = FileDownloading then 
(*(* USELESS NOW *)
            Intmap.iter (fun _ c ->
                try connect_client !!client_ip [file] c with _ -> ()) 
            file.file_known_locations;
*)            

          (*
            List.iter (fun s ->
                match s.server_sock with
                  None -> () (* assert false !!! *)
                | Some sock ->
                    (try DonkeyServers.query_location file sock with _ -> ())
            ) (connected_servers());
*)
          
            List.iter (fun s  ->
              if 
                connection_last_conn s.server_connection_control + 3600*8 > last_time () &&
                s.server_next_udp <= last_time () then
                  match s.server_sock with
                  None -> 
                    
                    udp_query_locations file s
                  | _ -> ()
            ) before
    ) !current_files;

    List.iter (fun s ->
        s.server_next_udp <- last_time () + !!min_reask_delay) before;
    if !udp_servers_list = [] then
          udp_servers_list := Hashtbl2.to_list servers_by_key;
    
    if !xs_last_search >= 0 then  begin
        try
          make_xs (search_find !xs_last_search)
        with _ -> ()
      end;

  with e ->
      lprintf "force_check_locations: %s" (Printexc2.to_string e);
      lprint_newline ()

let add_user_friend s u = 
  let kind = 
    if Ip.valid u.user_ip && 
      ((not !!black_list) || Ip.reachable u.user_ip) then
      Known_location (u.user_ip, u.user_port)
    else begin
        begin
          match s.server_sock, server_state s with 
            Some sock, (Connected _ |Connected_downloading) ->
              query_id s sock u.user_ip None;
          | _ -> ()
        end;
        Indirect_location (u.user_name, u.user_md4)
      end
  in
  let c = new_client kind  in
  c.client_tags <- u.user_tags;
  set_client_name c u.user_name u.user_md4;
  friend_add c

  
let udp_from_server p =
  match p.UdpSocket.addr with
  | Unix.ADDR_INET(ip, port) ->
      let ip = Ip.of_inet_addr ip in
      if !!update_server_list then
        let s = check_add_server ip (port-4) in
(* set last_conn, but add a 2 minutes offset to prevent staying connected
to this server *)
        connection_set_last_conn s.server_connection_control (
          last_time () - 121);
        s.server_score <- s.server_score + 3;
        s
      else raise Not_found
  | _ -> raise Not_found

let udp_client_handler t p =
  let module M = DonkeyProtoServer in
  match t with
    Udp.QueryLocationReplyUdpReq t ->
(*      lprintf "Received location by UDP"; lprint_newline ();  *)
      query_locations_reply (udp_from_server p) t
      
  | Udp.QueryReplyUdpReq t ->
(*      lprintf "Received file by UDP"; lprint_newline ();  *)
      if !xs_last_search >= 0 then
        let ss = search_find !xs_last_search in
        Hashtbl.add udp_servers_replies t.f_md4 (udp_from_server p);
        search_handler ss [t]

  | Udp.PingServerReplyUdpReq _ ->
      ignore (udp_from_server p)
        
  | _ -> 
      lprintf "Unexpected UDP message: \n%s\n"
        (DonkeyProtoUdp.print t)
      

let verbose_upload = false
      
let msg_block_size_int = 10000
let msg_block_size = Int64.of_int msg_block_size_int
let upload_buffer = String.create msg_block_size_int
let max_msg_size = 15000

(* For upload, it is clearly useless to completely fill a
socket. Since we will try to upload to this client again when the
Fifo queue has been scanned, we can wait for it to download what we
have already given. 

max_hard_upload_rate * 1024 * nseconds

where nseconds = Fifo.length upload_clients
  
  *)
  
module NewUpload = struct
    
    
    let check_end_upload c sock = ()
(*
      if c.client_bucket = 0 then
	direct_client_send sock (
	  let module M = DonkeyProtoClient in
	  let module Q = M.CloseSlot in
	    M.CloseSlotReq Q.t)
*)
    
    let rec send_small_block c sock up begin_pos len_int = 
(*      lprintf "send_small_block\n"; *)
(*      let len_int = Int32.to_int len in *)
      CommonUploads.consume_bandwidth len_int;
      try
        if !verbose then begin
            lprintf "send_small_block(%s-%s) %Ld %d"
              c.client_name (brand_to_string c.client_brand)
            (begin_pos) (len_int);
            lprint_newline ();
          end;
        
        let msg =  
          (
            let module M = DonkeyProtoClient in
            let module B = M.Bloc in
            M.BlocReq {  
              B.md4 = up.up_md4;
              B.start_pos = begin_pos;
              B.end_pos = Int64.add begin_pos (Int64.of_int len_int);
              B.bloc_str = "";
              B.bloc_begin = 0;
              B.bloc_len = 0; 
            }
          ) in
        let s = client_msg_to_string msg in
        let slen = String.length s in
        let upload_buffer = String.create (slen + len_int) in
        String.blit s 0 upload_buffer 0 slen;
        DonkeyProtoCom.new_string msg upload_buffer;
        Unix32.read up.up_fd begin_pos upload_buffer slen len_int;
        let uploaded = Int64.of_int len_int in
        count_upload c up.up_shared uploaded;
        shared_add_uploaded up.up_shared uploaded;
        if c.client_connected then
          printf_string "U[OUT]"
        else
          printf_string "U[IN]";
        
        write_string sock upload_buffer;
        check_end_upload c sock
      with e -> 
          lprintf "Exception %s in send_small_block" (Printexc2.to_string e);
          lprint_newline () 
    
    let rec send_client_block c sock per_client =
(*      lprintf "send_client_block\n"; *)
      if per_client > 0 && CommonUploads.remaining_bandwidth () > 0 then
        match c.client_upload with
        | Some ({ up_chunks = _ :: chunks } as up)  ->
            let max_len = Int64.sub up.up_end_chunk up.up_pos in
            let max_len = Int64.to_int max_len in
            let msg_block_size_int = mini msg_block_size_int per_client in
            if max_len <= msg_block_size_int then
(* last block from chunk *)
              begin
                if verbose_upload then begin
                    lprintf "END OF CHUNK (%d) %Ld" max_len up.up_end_chunk; 
                    lprint_newline ();
                  end;
                send_small_block c sock up up.up_pos max_len;
                up.up_chunks <- chunks;
                let per_client = per_client - max_len in
                match chunks with
                  [] -> 
                    if verbose_upload then begin
                        lprintf "NO CHUNKS"; lprint_newline ();
                      end;
                    c.client_upload <- None;
                | (begin_pos, end_pos) :: _ ->
                    up.up_pos <- begin_pos;
                    up.up_end_chunk <- end_pos;
                    send_client_block c sock per_client
              end
            else
(* small block from chunk *)
              begin
                send_small_block c sock up up.up_pos 
                  msg_block_size_int;
                up.up_pos <- Int64.add up.up_pos 
                  (Int64.of_int msg_block_size_int);
                let per_client = per_client-msg_block_size_int in
                if can_write_len sock max_msg_size then
                  send_client_block c sock per_client
              end
        | _ -> ()
    
    let upload_to_client c size = 
      try
(*        lprintf "upload_to_client %d\n" size; *)
        match c.client_sock with
          None -> 
(*            lprintf "Not connected\n"; *) ()
        | Some sock ->
            if CommonUploads.can_write_len sock (maxi max_msg_size size) then
              send_client_block c sock size;
(*            lprintf "upload_to_client...2\n"; *)
            (match c.client_upload with
                None -> (* lprintf "no client_upload\n"; *) ()
              | Some up ->
                  if !CommonUploads.has_upload = 0 then begin
(*                      lprintf "ready_for_upload\n"; *)
                      CommonUploads.ready_for_upload (as_client c.client_client)
                    end
            )
      with e ->
          lprintf "Exception %s in upload_to_client\n"
            (Printexc2.to_string e)
    let _ =
      client_ops.op_client_can_upload <- upload_to_client
      
  end