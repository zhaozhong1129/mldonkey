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


open Options
open CommonOptions

let donkey_ini = create_options_file "donkey.ini"

let donkey_section = file_section donkey_ini ["Donkey"] "Donkey options"
  
let initial_score = define_expert_option donkey_section ["initial_score"] "" int_option 5
  
let max_xs_packets = define_expert_option donkey_section ["max_xs_packets"] 
  "Max number of UDP packets per round for eXtended Search" int_option 30

let max_dialog_history = define_expert_option donkey_section ["max_dialog_history"]
    "Max number of messages of Chat remembered" int_option 30
    
let donkey_port = define_option donkey_section ["port"] "The port used for connection by other donkey clients." int_option 4662

let check_client_connections_delay = 
  define_expert_option donkey_section ["check_client_connections_delay"] 
  "Delay used to request file sources" float_option 180.0
    
let check_connections_delay = 
  define_expert_option donkey_section ["check_connections_delay"] 
  "The delay between server connection rounds" float_option 5.0
  
let max_connected_servers = define_option donkey_section
  ["max_connected_servers"] 
    "The number of servers you want to stay connected to" int_option 3

let max_udp_sends = define_expert_option donkey_section ["max_udp_sends"] 
    "The number of UDP packets you send every check_client_connections_delay" 
  int_option 10

let max_server_age = define_expert_option donkey_section ["max_server_age"] "max number of days after which an unconnected server is removed" int_option 2

let reliable_sources = define_option donkey_section ["reliable_sources"] 
    "Should mldonkey try to detect sources responsible for corruption and ban them" bool_option true

let emule_compression = define_option donkey_section ["emule_compression"] 
  "Should mldonkey accept compressed packets from emule" bool_option true
  
let ban_identity_thieves = define_option donkey_section ["ban_identity_thieves"] 
  "Should mldonkey try to detect sources masquerading as others and ban them" bool_option true

let max_allowed_connected_servers () = 
  BasicSocket.mini 5 !!max_connected_servers

(*  
let local_index_find_cmd = define_expert_option donkey_section 
    ["local_index_find_cmd"] "A command used locally to find more results
    during a search"
    string_option "" (* (cmd_basedir ^ "local_index_find")  *)

let local_index_add_cmd = define_expert_option donkey_section 
    ["local_index_add_cmd"] "A command used locally to add new results
    to a local index after a search"
    string_option "" (* (cmd_basedir ^ "local_index_add") *)
*)  

  

let compute_md4_delay = define_expert_option donkey_section ["compute_md4_delay"]
    "The delay between computations of the md4 of chunks"
  float_option 1.

let _ =
  option_hook compute_md4_delay (fun _ ->
      if !!compute_md4_delay < 0.1 then compute_md4_delay =:= 0.1)
  
let server_black_list = define_option donkey_section 
    ["server_black_list"] "A list of server IP to remove from server list.
    Servers on this list can't be added, and will eventually be removed"
    (list_option Ip.option) []
  
let force_high_id = define_option donkey_section ["force_high_id"] 
    "immediately close connection to servers that don't grant a High ID"
    bool_option false

let force_client_high_id = define_option donkey_section ["force_client_high_id"]
    "send all clients your IP regardless of what ID was assigned by the server"
    bool_option false

let update_server_list = define_option donkey_section
    ["update_server_list"] "Set this option to false if you don't want auto
    update of servers list" bool_option true

let keep_best_server = define_expert_option donkey_section
    ["keep_best_server"] "Set this option to false if you don't want mldonkey
    to change the master servers it is connected to" bool_option true

let max_walker_servers = define_expert_option donkey_section
    ["max_walker_servers"] "Number of servers that can be used to walk
between servers" int_option 1

let walker_server_lifetime = define_expert_option donkey_section
    ["walker_server_lifetime"] 
  "The maximal delay a connection with a server should last when walking
through the list (should be greater than become_master_delay)" int_option 300
    
(* let max_sources_age = define_expert_option donkey_section
    ["max_source_age"] "Sources that have not been connected for this number of days are removed"
    int_option 3 *)
  
let max_indirect_connections = define_option donkey_section
    ["max_indirect_connections"] 
  "Maximal number of indirect connections at any moment"
  int_option (!!max_opened_connections/2)
  
let log_clients_on_console = define_expert_option donkey_section
  ["log_clients_on_console"] 
  ""
    bool_option false

let propagate_sources = define_expert_option donkey_section ["propagate_sources"]
    "Allow mldonkey to propagate your sources to other donkey clients"
    bool_option true
  
let max_sources_per_file = define_option donkey_section ["max_sources_per_file"]
    "Maximal number of sources for each file"
    int_option 20000

open Md4  
    
let mldonkey_md4 md4 =
  let md4 = Md4.direct_to_string md4 in
  md4.[5] <- Char.chr 14;
  md4.[14] <- Char.chr 111;
  Md4.direct_of_string md4

(* let server_client_md4 = define_option donkey_section ["server_client_md4"]
    "The MD4 of this client" Md4.option ( (Md4.random ())) *)

let client_md4 = define_option donkey_section ["client_md4"]
    "The MD4 of this client" Md4.option (mldonkey_md4 (Md4.random ()))
  
let _ =
  option_hook client_md4 (fun _ -> 
      let m = mldonkey_md4 !!client_md4 in
      if m <> !!client_md4 then
        client_md4 =:= m)

let black_list = define_expert_option donkey_section ["black_list"]
  ""    bool_option true
  
let port_black_list = define_expert_option donkey_section 
    ["port_black_list"] "A list of ports that specify servers to remove
    from server list. Servers with ports on this list can't be added, and
    will eventually be removed"
    (list_option int_option) []
   
let queued_timeout = 
  define_expert_option donkey_section ["queued_timeout"] 
    "How long should we wait in the queue of another client"
    float_option 1800. 
      
let upload_timeout = 
  define_expert_option donkey_section ["upload_timeout"] 
    "How long can a silent client stay in the upload queue"
    float_option 1800. 
      
let upload_lifetime = 
  define_expert_option donkey_section ["upload_lifetime"] 
    "How long a downloading client can stay in my upload queue (in minutes >5)"
    int_option 90 
      
let dynamic_upload_lifetime = 
  define_expert_option donkey_section ["dynamic_upload_lifetime"] 
    "Each client upload lifetime depends on download-upload ratio"
    bool_option false 
      
let dynamic_upload_threshold = 
  define_expert_option donkey_section ["dynamic_upload_threshold"] 
    "Uploaded zones (1 zone = 180 kBytes) needed to enable the dynamic upload lifetime"
    int_option 10

let random_order_download = 
  define_option donkey_section ["random_order_download"] 
  "Should we try to download chunks in random order (false = linearly) ?"
    bool_option true
      
let connected_server_timeout = 
  define_expert_option donkey_section ["connected_server_timeout"]
    "How long can a silent server stay connected"
    float_option 1800.
  
let upload_power = define_expert_option donkey_section ["upload_power"]
  "The weight of upload on a donkey connection compared to upload on other
  peer-to-peer networks. Setting it to 5 for example means that a donkey 
  connection will be allowed to send 5 times more information per second than
  an Open Napster connection. This is done to favorise donkey connections
  over other networks, where upload is less efficient, without preventing
  upload from these networks." int_option 5

let remove_old_servers_delay = define_expert_option donkey_section ["remove_old_servers_delay"]
  "How often should remove old donkey be called (in seconds, 0 to disable)"
    float_option 900.

let min_left_servers = define_expert_option donkey_section ["min_left_servers"]
  "Minimal number of servers remaining after remove_old_servers"
    int_option 20
  
let servers_walking_period = define_expert_option donkey_section ["servers_walking_period"]
  "How often should we check all servers (minimum 4 hours, 0 to disable)"
    int_option 6
  
let _ =
  option_hook servers_walking_period (fun _ ->
    if !!servers_walking_period > 0 &&
      !!servers_walking_period < 4 then
	servers_walking_period =:= 4)
  
let keep_cancelled_in_old_files = define_expert_option donkey_section
    ["keep_cancelled_in_old_files"] 
    "Are the cancelled files added to the old files list to prevent re-download ?"
    bool_option false
  
let send_warning_messages = define_expert_option donkey_section
    ["send_warning_messages"] "true if you want your mldonkey to lose some
upload bandwidth sending messages to clients which are banned :)"
    bool_option false
  
let ban_queue_jumpers = define_expert_option donkey_section
    ["ban_queue_jumpers"] "true if you want your client to ban
    clients that try queue jumping (3 reconnections faster than 9 minutes)"
    bool_option true
  
let use_server_ip = define_expert_option donkey_section
    ["use_server_ip"] "true if you want your client IP to be set from servers ID"    bool_option true
  
let ban_period = define_expert_option donkey_section
    ["ban_period"] "Set the number of hours you want client to remain banned"
    int_option 1

let good_client_rank = define_expert_option donkey_section
    ["good_client_rank"]
  "Set the maximal rank of a client to be kept as a client"
    int_option 500
  
let min_users_on_server = define_option donkey_section ["min_users_on_server"]
     "min connected users for each server" int_option 0

let login = define_option donkey_section ["login"] 
    "login of client on eDonkey network (nothing default to global one)" string_option ""

let overnet_options_section_name = "Overnet"

let overnet_section = file_section donkey_ini [ overnet_options_section_name ]
    "Overnet options"  

let overnet_port =  
  define_option overnet_section [overnet_options_section_name; "port"] 
  "port for overnet" 
    int_option (2000 + Random.int 20000)
  
  
  
(* let source_management = define_expert_option donkey_section
    ["source_management"] "Which source management to use:
    1: based on separate time queues, shared by files (2.02-1...2.02-5)
    2: based on unified queues with scores, shared by files (2.02-6...2.02-9)
    3: based on separate file queues (2.02-10)
    " int_option 3 *)
  
let sources_per_chunk = 
  define_expert_option donkey_section ["sources_per_chunk"]
    "How many sources to use to download each chunk"
    int_option 3

  
(* This option is used to avoid the delay when connecting to a server before
sending the list of shared files, which is only sent to master servers. *)
let immediate_master = 
  define_expert_option donkey_section ["immediate_master"] 
    "(only for development tests)" bool_option false

let become_master_delay = 
  define_expert_option donkey_section ["become_master_delay"] 
    "(only for development tests)" int_option 120

let gui_donkey_options_panel = 
  [
(*    "Maximal Source Age", shortname max_sources_age, "T"; *)
    "Maximal Server Age", shortname max_server_age, "T";
    "Min Left Servers After Clean", shortname min_left_servers, "T";
    "Update Server List", shortname update_server_list, "B";
    "Servers Walking Period", shortname servers_walking_period, "T";
    "Force High ID", shortname force_high_id, "B";
    "Max Number of Connected Servers", shortname max_connected_servers, "T";
    "Max Upload Slots", shortname max_upload_slots, "T";
    "Max Sources Per Download", shortname max_sources_per_file, "T";
    "Port", shortname donkey_port, "T";
    "Login", shortname login, "T";
    "Download Chunks in Random order", shortname random_order_download, "B";    
    "Sources Per Chunk", shortname sources_per_chunk, "T";
    "Prevent Re-download of Cancelled Files", shortname keep_cancelled_in_old_files, "B";
    "Dynamic Slot Allocation", shortname dynamic_slots, "B";
  ]

