%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2009-2011 Max Lapshin
%%% @doc        HTTP linked-in driver
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to
%%% deal in the Software without restriction, including without limitation the
%%% rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
%%% sell copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%% 
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%% 
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
%%% IN THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------
-module(gen_http).
-author('Max Lapshin <max@maxidoors.ru>').
-include("log.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("eunit/include/eunit.hrl").

% Common API
-export([send/2, close/1, recv/2, recv/3, setopts/2]).

% Server API
-export([listen/2, listen/1, controlling_process/2, active_once/1, peername/1]).
-export([receive_body/1, skip_body/1, flush_body/1]).
-export([accept_once/1, accept/2]).

% Client API
-export([connect/3, connect/2, lookup_ip/1]).

% Cache API
-export([cache_set/3, cache_delete/2, cache_list/1, cache_get/2, cache_clear/1]).

% Cowboy transport API
-export([name/0, messages/0]).

-export([open_socket/0]).

-define(CMD_LISTEN, 1).
-define(CMD_ACTIVE_ONCE, 2).
-define(CMD_RECEIVE_BODY, 3).
-define(CMD_STATS, 4).
-define(CMD_ACCEPT_ONCE, 5).
-define(CMD_CONNECT, 6).
-define(CMD_SKIP_BODY, 7).
-define(CMD_SET_CHUNK_SIZE, 8).
-define(CMD_SET_CACHE, 9).
-define(CMD_DELETE_CACHE, 10).
-define(CMD_LIST_CACHE, 11).
-define(CMD_GET_CACHE, 12).
-define(INET_REQ_GETFD, 14).

name() -> gen_http.

messages() -> {http_connection, http, http_closed, http_error}.


open_socket() ->
  Path = case code:lib_dir(gen_http,priv) of
    P when is_list(P) -> P;
    _ -> filename:dirname(code:which(?MODULE))++"/../priv/"
  end,
  case erl_ddll:load_driver(Path, gen_http_drv) of
  	ok -> ok;
  	{error, already_loaded} -> ok;
  	{error, Error} -> exit({error, {could_not_load_driver,erl_ddll:format_error(Error)}})
  end,
  Socket = erlang:open_port({spawn, gen_http_drv}, [binary]),
  erlang:port_set_data(Socket, inet_tcp),
  {ok, Socket}.

listen(Port) when is_integer(Port) ->
  listen(Port, []);

listen(Options) when is_list(Options) ->
  Port = proplists:get_value(port, Options),
  listen(Port, Options).

listen(Port, Options) ->
  {ok, Socket} = open_socket(),
  Reuseaddr = case proplists:get_value(reuseaddr, Options, true) of
    true -> 1;
    _ -> 0
  end,
  Keepalive = case proplists:get_value(keepalive, Options) of
    true -> 1;
    _ -> 0
  end,
  Timeout = proplists:get_value(timeout, Options, 60000),
  Backlog = proplists:get_value(backlog, Options, 30),
  
  Reply = port_control(Socket, ?CMD_LISTEN, <<Port:16, Backlog:16/little, Reuseaddr, Keepalive, Timeout:16/little>>),
  case parse_reply(Reply) of
    ok -> {ok, Socket};
    ListenError -> ListenError
  end.


parse_reply("ok") -> ok;
parse_reply([0|Error]) -> {error, list_to_atom(Error)}.


controlling_process(Socket, NewOwner) when is_port(Socket), is_pid(NewOwner) ->
  case erlang:port_info(Socket, connected) of
	  {connected, Pid} when Pid =/= self() ->
	    {error, not_owner};
	  undefined ->
	    {error, einval};
	_ ->
		try erlang:port_connect(Socket, NewOwner) of
		  true ->
			  unlink(Socket), %% unlink from port
				ok
		catch
			error:Reason -> 
				{error, Reason}
		end
  end.

receive_body(Socket) ->
  "ok" = port_control(Socket, ?CMD_RECEIVE_BODY, <<>>),
  ok.

skip_body(Socket) ->
  "ok" = port_control(Socket, ?CMD_SKIP_BODY, <<>>),
  ok.
  
flush_body(Socket) ->
  skip_body(Socket),
  loop_flush_body(Socket).
  
loop_flush_body(Socket) ->  
  active_once(Socket),
  receive
    {http, Socket, eof} -> ok;
    {http, Socket, _Bin} -> loop_flush_body(Socket);
    {http_closed, Socket} -> {error, closed};
    {http_timeout, Socket} -> close(Socket), {error, timeout}
  end.

peername(Socket) when is_port(Socket) ->
  {ok, {{0,0,0,0}, 4000}}.

close(Socket) when is_port(Socket) ->
  unlink(Socket),
  (catch erlang:port_close(Socket)),
  flush(Socket).

flush(Socket) ->
  receive
    {http_closed, Socket} -> flush(Socket);
    {http_error, Socket, _} -> flush(Socket);
    {http, Socket, _} -> flush(Socket);
    {http_connection, Socket, S} -> close(S), flush(Socket)
  after
    0 -> ok
  end.  

active_once(Socket) ->
  (catch port_control(Socket, ?CMD_ACTIVE_ONCE, <<>>)).

accept_once(Socket) ->
  port_control(Socket, ?CMD_ACCEPT_ONCE, <<>>).

accept(Listen, Timeout) ->
  accept_once(Listen),
  receive
    {http_connection, Listen, Socket} -> 
      erlang:port_set_data(Socket, inet_tcp),
      {ok, Socket};
    {http_closed, Listen} -> {error, closed};
    {http_error, Listen, Error} -> {error, Error}
  after
    Timeout -> {error, timeout}
  end.  

recv(Socket, Length) ->
  recv(Socket, Length, infinity).

recv(Socket, Length, Timeout) ->
  recv(Socket, Length, Timeout, []).

recv(Socket, Length, Timeout, Acc) ->
  gen_http:active_once(Socket),
  receive
    {http, Socket, eof} -> {ok, iolist_to_binary(lists:reverse(Acc))};
    {http_error, Socket, Error} -> {error, Error};
    {http, Socket, Bin} ->
      Acc1 = [Bin|Acc],
      case iolist_size(Acc1) of
        S when S > Length -> {ok, iolist_to_binary(lists:reverse(Acc1))};
        _ -> recv(Socket, Length, Timeout, Acc1)
      end
    after
      Timeout -> {error, timeout}
  end.
  
  
setopts(Socket, Options) ->
  [setopt(Socket, K, V) || {K,V} <- Options],
  ok.

setopt(Socket, chunk_size, Size) when is_integer(Size) andalso Size > 0 ->
  "ok" = port_control(Socket, ?CMD_SET_CHUNK_SIZE, <<Size:32/little>>).



send(Socket, Bin) when is_port(Socket) ->
  try port_command(Socket, Bin) of
    true ->
      receive
        {http, Socket, empty} -> ok;
        {http_error, Socket, Error} -> {error, Error};
        {http_closed, Socket} -> {error, closed}
      end
  catch
    error:Error -> {error, Error}
  end.    


connect(Host, Port) ->
  connect(Host, Port, []).
  
connect(Host, Port, Options) ->
  connect(Host, Port, Options, proplists:get_value(timeout, Options, 10000)).
  
connect(Host, Port, _Options, Timeout) ->
  case lookup_ip(Host) of
    {ok, IP} ->
      connect_to_ip(IP, Port, Timeout);
    Else ->
      Else
  end.
  
connect_to_ip({I1,I2,I3,I4}, Port, Timeout) ->
  {ok, Socket} = open_socket(),
  Reply = port_control(Socket, ?CMD_CONNECT, <<I1,I2,I3,I4, Port:16>>),
  case parse_reply(Reply) of
    ok ->
      receive
        {http, Socket, connected} -> {ok, Socket};
        {http_error, Socket, Error} -> close(Socket), {error, Error};
        {http_closed, Socket} -> {error, closed};
        Else -> ?D(Else)
      after
        Timeout -> close(Socket), {error, timeout}
      end;
    Error -> 
      Error
  end.
      


lookup_ip(Host) ->
  case inet_parse:address(Host) of
    {ok, IP} -> {ok, IP};
    {error, _} ->
      case inet:gethostbyname(Host, inet) of
        {ok, #hostent{h_addr_list = IPS}} when length(IPS) > 0 ->
          IP = lists:nth(random:uniform(length(IPS)), IPS),
          {ok, IP};
        {error, Error} ->
          {error, Error}
      end
  end.  


cache_set(Socket, URL, Reply) when is_binary(URL) andalso is_binary(Reply) ->
  case erlang:port_info(Socket, name) of
    {name, "gen_http_drv"} -> "ok" == port_control(Socket, ?CMD_SET_CACHE, <<URL/binary, 0, Reply/binary>>);
    _ -> false
  end;  

cache_set(Socket, URL, Reply) when is_list(URL) ->
  cache_set(Socket, list_to_binary(URL), Reply);

cache_set(Socket, URL, Reply) when is_list(Reply) ->
  cache_set(Socket, URL, iolist_to_binary(Reply)).



cache_delete(Socket, URL) when is_list(URL) ->
  cache_delete(Socket, list_to_binary(URL));

cache_delete(Socket, URL) when is_binary(URL) ->
  case erlang:port_info(Socket, name) of
    {name, "gen_http_drv"} -> "ok" = port_control(Socket, ?CMD_DELETE_CACHE, <<URL/binary, 0>>);
    _ -> true
  end.

cache_list(Socket) ->
  case erlang:port_info(Socket, name) of
    {name, "gen_http_drv"} ->
      "ok" = port_control(Socket, ?CMD_LIST_CACHE, <<>>),
      receive
        {http_cache_list, Socket, URLS} -> {ok, URLS}
      after
        5000 -> {error, timeout}
      end;
    _ ->
      {ok, []}
  end.


cache_get(Socket, Key) when is_list(Key) ->
  cache_get(Socket, list_to_binary(Key));
  
cache_get(Socket, Key) when is_binary(Key) ->
  case erlang:port_info(Socket, name) of
    {name, "gen_http_drv"} -> 
      "ok" = port_control(Socket, ?CMD_GET_CACHE, <<Key/binary, 0>>),
      receive
        {http_cache, Socket, Reply} -> Reply
      after
        5000 -> erlang:exit(timeout)
      end;
    _ -> 
      undefined
  end.

cache_clear(Socket) ->
  {ok, Keys} = cache_list(Socket),
  [cache_delete(Socket, Key) || Key <- Keys],
  ok.


