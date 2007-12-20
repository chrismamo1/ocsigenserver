(* Ocsigen
 * http://www.ocsigen.org
 * Module extensiontemplate.ml
 * Copyright (C) 2007 Vincent Balat
 * CNRS - Université Paris Diderot Paris 7
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception; 
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)
(*****************************************************************************)
(*****************************************************************************)
(* This is an example of extension for Ocsigen                               *)
(* Take this as a template for writing your own extensions to the Web server *)
(*****************************************************************************)
(*****************************************************************************)

(* If you want to create an extension to filter the output of the server
   (for ex: compression), have a look at deflatemod.ml as an example.
   It is very similar to this example, but using 
   Extensions.register_output_filter
   instead of Extensions.register_extension.
 *)

(* To compile it:
ocamlfind ocamlc  -thread -package netstring,ocsigen -c extensiontemplate.ml

Then load it dynamically from Ocsigen's config file:
   <extension module=".../extensiontemplate.cmo"/>

*)

open Lwt
open Extensions
open Simplexmlparser



(*****************************************************************************)
(** Extensions may take some options from the config file. 
    These options are written in xml inside the <extension> tag.
   For example:
   <extension module=".../extensiontemplate.cmo">
     <myoption myattr="hello">
        ...
     </myoption>
   </extension>
 *)

let rec parse_global_config = function
  | [] -> ()
  | (Element ("myoption", [("myattr", s)], []))::ll -> ()
  | _ -> raise (Error_in_config_file 
                  ("Unexpected content inside extensiontemplate config"))

let _ = parse_global_config (Extensions.get_config ())




(*****************************************************************************)
(** The function that will generate the pages from the request, or modify
    a result generated by another extension. 

    - the [string option] is the encoding for characters possibly specified 
   in the configuration file,
    - [Extensions.req_state] is the request, possibly modified by previous
    extensions, or already found

 *)
let gen charset = function
  | Extensions.Req_found (_, r) -> 
      (* If previous extension already found the page, you can
         modify the result (if you write a filter) or return it 
         without modification like this: *)
      Lwt.return (Extensions.Ext_found r)
  | Extensions.Req_not_found (err, ri) ->
      (* If previous extensions did not find the result, 
         I decide here to answer with a default page
         (for the example):
      *)
      return (Ext_found 
                (fun () ->
                   let content = "Extensiontemplate page" in
                   Predefined_senders.Text_content.result_of_content
                     (content, "text/plain")))



(*****************************************************************************)
(** Extensions may define new tags for configuring each site.
    These tags are inside <site ...>...</site> in the config file.
        
   For example:
   <site dir="">
     <extensiontemplate module=".../mymodule.cmo" />
   </site>

   Each extension will set its own configuration options, for example:
   <site dir="">
     <extensiontemplate module=".../mymodule.cmo" />
     <eliom module=".../myeliommodule.cmo" />
     <static dir="/var/www/plop" />
   </extension>

    Here parse_site is the function used to parse the config file inside this
    site. Use this if you want to put extensions config options inside
    your own option. For example:

{[
  | Element ("iffound", [], sub) ->
      let ext = parse_fun sub in
(* DANGER: parse_fun MUST be called BEFORE the function! *)
      (fun charset -> function
        | Extensions.Req_found (_, _) ->
            Lwt.return (Ext_sub_result ext)
        | Extensions.Req_not_found (err, ri) -> 
            Lwt.return (Extensions.Ext_not_found err))
]}
 *)

let parse_config path charset parse_site = function
  | Element ("extensiontemplate", atts, []) ->  gen
  | Element (t, _, _) -> raise (Bad_config_tag_for_extension t)
  | _ -> 
      raise (Error_in_config_file "Unexpected data in config file")




(*****************************************************************************)
(** Function to be called at the beginning of the initialisation phase 
    of the server (actually each time the config file is reloaded) *)
let start_init () =
  ()

(** Function to be called at the end of the initialisation phase *)
let end_init () =
  ()



(*****************************************************************************)
(** A function that will create an error message from the exceptions
    that may be raised during the initialisation phase, and raise again 
    all other exceptions. That function has type exn -> string. Use the 
   raise function if you don't need any. *)
let exn_handler = raise




(*****************************************************************************)
(* a function taking 
   {ul
     {- the name of the virtual <host>}}
     that will be called for each <host>, 
     and that will generate a function taking:
   {ul
     {- the path attribute of a <site> tag
     that will be called for each <site>, 
     and that will generate a function taking:}}
   {ul
     {- an item of the config file
     that will be called on each tag inside <site> and:}
   {ul
     {- raise [Bad_config_tag_for_extension] if it does not recognize that tag}
     {- return something of type [extension] (filter or page generator)}}
*)
let site_creator hostpattern = parse_config
   (* hostpattern has type Extensions.virtual_hosts
      and represents the name of the virtual host.
      The path and the charset are declared in <site path... charset=.../>
    *)
   

(*****************************************************************************)
(** Registration of the extension *)
let _ = register_extension
  site_creator
  start_init
  end_init
  exn_handler

