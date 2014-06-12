(* Ocsigen
 * http://www.ocsigen.org
 * Module revproxy.ml
 * Copyright (C) 2007 Vincent Balat
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

(** Reverse proxy for Ocsigen *)

(*
   The reverse proxy is still experimental because it relies on the
   experimental Ocsigen_http_client module.

   TODO
   - Change the policy for � trusted servers � for pipelining?
   (see ocsigen_http_client.ml)
   - enhance pipelining
   - HTTP/1.0
   - ...


   - Make possible to return for example (Ext_next 404) to allow
   other extensions to take the request?
   There is a problem if the body contains data (POST request) ...
   this data has been sent and is lost ...
*)

open Ocsigen_lib

open Lwt
open Ocsigen_extensions
open Simplexmlparser
open Cohttp
open Cohttp_lwt_unix

module RI = Ocsigen_request_info

exception Bad_answer_from_http_server


(*****************************************************************************)
(* The table of redirections for each virtual server                         *)
type redir =
  { regexp: Netstring_pcre.regexp;
    full_url: yesnomaybe;
    dest: string;
    pipeline: bool;
    keephost: bool}


(*****************************************************************************)
(* Finding redirections *)


(** The function that will generate the pages from the request. *)

let gen dir = function
  | Ocsigen_extensions.Req_found _ ->
    Lwt.return Ocsigen_extensions.Ext_do_nothing
  | Ocsigen_extensions.Req_not_found (err, ri) ->
    catch
      (* Is it a redirection? *)
      (fun () ->
         Ocsigen_messages.debug2 "--Revproxy: Is it a redirection?";
         let dest =
           let ri = ri.request_info in
           let fi full =
             Ocsigen_extensions.find_redirection
               dir.regexp
               full
               dir.dest
               (Ocsigen_request_info.ssl ri)
               (Ocsigen_request_info.host ri)
               (Ocsigen_request_info.server_port ri)
               (Ocsigen_request_info.get_params_string ri)
               (Ocsigen_request_info.sub_path_string ri)
               (Ocsigen_request_info.full_path_string ri)
           in
           match dir.full_url with
           | Yes -> fi true
           | No -> fi false
           | Maybe ->
             try fi false
             with Ocsigen_extensions.Not_concerned -> fi true
         in
         let (https, host, port, uri) =
           try
             match Url.parse dest with
             | (Some https, Some host, port, uri, _, _, _) ->
               let port = match port with
                 | None -> if https then 443 else 80
                 | Some p -> p
               in
               (https, host, port, uri)
             | _ -> raise (Ocsigen_extensions.Error_in_config_file
                             ("Revproxy : error in destination URL "^dest))
           (*VVV catch only Neturl exceptions! *)
           with e -> raise (Ocsigen_extensions.Error_in_config_file
                              ("Revproxy : error in destination URL "^dest^" - "^
                               Printexc.to_string e))
         in
         let uri = "/"^uri in
         Ocsigen_messages.debug
           (fun () ->
              "--Revproxy: YES! Redirection to "^
              (if https then "https://" else "http://")^host^":"^
              (string_of_int port)^uri);

         Ip_address.get_inet_addr host >>= fun inet_addr ->

         (* It is now safe to start processing next request.
            We are sure that the request won't be taken in disorder.
            => We return.
         *)

         let host =
           match
             if dir.keephost
             then match RI.host ri.request_info with
               | Some h -> Some h
               | None -> None
             else None
           with
           | Some h -> h
           | None -> host
         in

         let frame_of_cohttp (response, body) =
           let open Ocsigen_http_frame in
           {
             frame_header = Of_cohttp.of_response response;
             frame_content = Some
                 (Ocsigen_stream.of_lwt_stream
                    (fun x -> x)
                    (Cohttp_lwt_body.to_stream body));
             frame_abort = (fun () -> Lwt.return ());
           }
         in

         let do_request () =
           let ri = ri.request_info in
           (* let address = Unix.string_of_inet_addr (fst (get_server_address
            * ri)) in *)
           let address = Unix.string_of_inet_addr
             @@ RI.remote_inet_addr ri in
           let forward =
             String.concat ", " (RI.remote_ip ri :: (RI.forward_ip ri @ [address]))
           in
           let proto =
             if RI.ssl ri
             then "https"
             else "http"
           in
           let (meth, version, headers, uri', body) =
             Ocsigen_generate.to_cohttp_request ri in
           let headers =
             Cohttp.Header.add headers
               "X-Forwarded-Proto"
               (Cohttp.Code.string_of_version version) in
           let headers =
             Cohttp.Header.add headers
               "X-Forwarded-For"
               forward in
           let headers = Cohttp.Header.remove headers "host" in
           let uri = Printf.sprintf "%s://%s%s"
               proto host uri in
           Client.call ~headers ~body meth (Uri.of_string uri)
         in
         Lwt.return
           (Ext_found
              (fun () ->
                 do_request ()

                 >|= frame_of_cohttp
                 >>= fun http_frame ->

                 let headers =
                   http_frame.Ocsigen_http_frame.frame_header.Ocsigen_http_frame.Http_header.headers
                 in
                 let code =
                   match
                     http_frame.Ocsigen_http_frame.frame_header.Ocsigen_http_frame.Http_header.mode
                   with
                   | Ocsigen_http_frame.Http_header.Answer code -> code
                   | _ -> raise Bad_answer_from_http_server
                 in
                 match http_frame.Ocsigen_http_frame.frame_content with
                 | None ->
                   let empty_result = Ocsigen_http_frame.Result.empty () in
                   let length =
                     Ocsigen_headers.get_content_length http_frame
                   in
                   Ocsigen_stream.add_finalizer
                     (fst (Ocsigen_http_frame.Result.stream empty_result))
                     (fun outcome ->
                        match outcome with
                          `Failure ->
                          http_frame.Ocsigen_http_frame.frame_abort ()
                        | `Success ->
                          Lwt.return ());


                   Lwt.return
                     (Ocsigen_http_frame.Result.update empty_result
                        ~content_length:length
                        ~headers
                        ~code ())
                 | Some stream ->
                   let default_result =
                     Ocsigen_http_frame.Result.default ()
                   in
                   let length =
                     Ocsigen_headers.get_content_length http_frame
                   in
                   Ocsigen_stream.add_finalizer stream
                     (fun outcome ->
                        match outcome with
                          `Failure ->
                          http_frame.Ocsigen_http_frame.frame_abort ()
                        | `Success ->
                          Lwt.return ());

                   Lwt.return
                     (Ocsigen_http_frame.Result.update default_result
                        ~content_length:length
                        ~stream:(stream, None)
                        ~headers
                        ~code ())
              )
           )
      )
      (function
        | Not_concerned -> return (Ext_next err)
        | e -> fail e)




(*****************************************************************************)


let parse_config = function
  | Element ("revproxy", atts, []) ->
    let rec parse_attrs ((r, f, d, pipeline, h) as res) = function
      | [] -> res
      | ("regexp", regexp)::l when r = None -> (* deprecated *)
        parse_attrs
          (Some (Netstring_pcre.regexp ("^"^regexp^"$")), Maybe,
           d, pipeline, h)
          l
      | ("fullurl", regexp)::l when r = None ->
        parse_attrs
          (Some (Netstring_pcre.regexp ("^"^regexp^"$")), Yes,
           d, pipeline, h)
          l
      | ("suburl", regexp)::l when r = None ->
        parse_attrs
          (Some (Netstring_pcre.regexp ("^"^regexp^"$")), No,
           d, pipeline, h)
          l
      | ("dest", dest)::l when d = None ->
        parse_attrs
          (r, f, Some dest, pipeline, h)
          l
      | ("keephost", "keephost")::l ->
        parse_attrs
          (r, f, d, pipeline, true)
          l
      | ("nopipeline", "nopipeline")::l ->
        parse_attrs
          (r, f, d, false, h)
          l
      | (a, _) :: _ ->
        badconfig "Wrong or duplicate attribute '%s' for <revproxy>" a
    in
    let dir =
      match parse_attrs (None, Yes, None, true, false) atts with
      | (None, _, _, _, _) ->
        badconfig "Missing attribute 'regexp' for <revproxy>"
      | (_, _, None, _, _) ->
        badconfig "Missing attribute 'dest' for <revproxy>"
      | (Some r, full, Some d, pipeline, h) ->
        {
          regexp=r;
          full_url=full;
          dest=d;
          pipeline=pipeline;
          keephost=h;
        }
    in
    gen dir
  | Element (t, _, _) -> raise (Bad_config_tag_for_extension t)
  | _ -> raise (Error_in_config_file "(revproxy extension) Bad data")





(*****************************************************************************)
(** Registration of the extension *)
let () = register_extension
    ~name:"revproxy"
    ~fun_site:(fun _ _ _ _ _ -> parse_config)
    ~user_fun_site:(fun _ _ _ _ _ _ -> parse_config)
    ~respect_pipeline:true (* We ask ocsigen to respect pipeline order
                              when sending to extensions! *)
    ()
