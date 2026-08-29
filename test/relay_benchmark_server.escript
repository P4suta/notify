#!/usr/bin/env escript
%% SPDX-License-Identifier: Apache-2.0
%%! -noshell

-mode(compile).

main([]) ->
    Delay = environment_integer("NOTIFY_RELAY_DELAY_MS", 0),
    {ok, Listener} = gen_tcp:listen(9090, [
        binary,
        {active, false},
        {packet, http_bin},
        {reuseaddr, true},
        {backlog, 1024}
    ]),
    accept(Listener, Delay).

accept(Listener, Delay) ->
    {ok, Socket} = gen_tcp:accept(Listener),
    spawn(fun() -> handle(Socket, Delay) end),
    accept(Listener, Delay).

handle(Socket, Delay) ->
    case read_request(Socket) of
        ok ->
            timer:sleep(Delay),
            respond(Socket, 200, "OK");
        _ -> respond(Socket, 400, "Bad Request")
    end,
    gen_tcp:close(Socket).

read_request(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_request, 'POST', _, _}} ->
            read_request(Socket);
        {ok, {http_header, _, _, _, _}} ->
            read_request(Socket);
        {ok, http_eoh} -> ok;
        Other -> Other
    end.

respond(Socket, Status, Reason) ->
    gen_tcp:send(Socket, iolist_to_binary([
        "HTTP/1.1 ", integer_to_list(Status), " ", Reason, "\r\n",
        "Content-Length: 0\r\nConnection: close\r\n\r\n"
    ])).

environment_integer(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> list_to_integer(Value)
    end.
