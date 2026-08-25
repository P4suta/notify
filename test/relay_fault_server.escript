#!/usr/bin/env escript
%% SPDX-License-Identifier: Apache-2.0
%%! -noshell

-mode(compile).

-define(PORT, 9090).
-define(MAX_HEADER_BYTES, 65536).

main([]) ->
    ok = file:write_file("/tmp/relay-request-count", <<"0\n">>),
    {ok, Listener} = gen_tcp:listen(?PORT, [
        binary,
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {backlog, 16}
    ]),
    accept(Listener, 1).

accept(Listener, Number) ->
    {ok, Socket} = gen_tcp:accept(Listener),
    spawn(fun() -> handle(Socket, Number) end),
    accept(Listener, Number + 1).

handle(Socket, Number) ->
    case read_headers(Socket, <<>>) of
        {ok, Headers, Remainder} ->
            ok = file:write_file(
                "/tmp/relay-request-count",
                <<(integer_to_binary(Number))/binary, "\n">>
            ),
            case valid_content_blind_request(Headers, Remainder) of
                true -> respond(Socket, Number);
                false ->
                    ok = file:write_file(
                        "/tmp/relay-invalid-request",
                        <<Headers/binary, Remainder/binary>>
                    ),
                    send_status(Socket, 400, "Bad Request")
            end;
        {error, Reason} ->
            ok = file:write_file(
                "/tmp/relay-read-error",
                unicode:characters_to_binary(io_lib:format("~tp\n", [Reason]))
            )
    end,
    gen_tcp:close(Socket).

read_headers(_Socket, Accumulator) when byte_size(Accumulator) >= ?MAX_HEADER_BYTES ->
    {error, headers_too_large};
read_headers(Socket, Accumulator) ->
    case binary:match(Accumulator, <<"\r\n\r\n">>) of
        {Position, 4} ->
            HeaderBytes = Position + 4,
            <<Headers:HeaderBytes/binary, Remainder/binary>> = Accumulator,
            {ok, Headers, Remainder};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> read_headers(Socket, <<Accumulator/binary, Data/binary>>);
                Error -> Error
            end
    end.

valid_content_blind_request(Headers, Remainder) ->
    Lower = string:lowercase(Headers),
    Remainder =:= <<>>
        andalso binary:match(Lower, <<"content-length: 0\r\n">>) =/= nomatch
        andalso binary:match(Lower, <<"authorization: bearer cluster-relay-token\r\n">>) =/= nomatch
        andalso re:run(
            Lower,
            <<"\r\nx-poll-id: [a-z0-9]{12}\r\n">>,
            [{capture, none}]
        ) =:= match.

respond(Socket, 1) ->
    %% The first provider call remains in flight while its owning node is killed.
    timer:sleep(120000),
    send_status(Socket, 200, "OK");
respond(Socket, _) ->
    %% Keep a reclaimed lease observable before the second worker completes it.
    timer:sleep(3000),
    send_status(Socket, 200, "OK").

send_status(Socket, Status, Reason) ->
    gen_tcp:send(Socket, iolist_to_binary([
        "HTTP/1.1 ", integer_to_list(Status), " ", Reason, "\r\n",
        "Content-Length: 0\r\n",
        "Connection: close\r\n\r\n"
    ])).
