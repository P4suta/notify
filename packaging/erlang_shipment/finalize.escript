#!/usr/bin/env escript
%%! -noshell
%% SPDX-License-Identifier: Apache-2.0

-mode(compile).

main([Root]) ->
    Applications = [
        {gleam_quic, [gleam_quic_test_ffi, qlog_test_ffi]},
        {http3, [
            gleam_quic_test_ffi,
            http3_benchmark_ffi,
            http3_diagnostic_ffi,
            http3_phase4_interop,
            http3_quicgo_interop,
            http3_test_ffi
        ]}
    ],
    lists:foreach(
        fun({Application, DevelopmentModules}) ->
            finalize_application(Root, Application, DevelopmentModules)
        end,
        Applications),
    io:format("HTTP/3 runtime shipment inventory finalized~n");
main(_) ->
    io:format(standard_error, "usage: finalize.escript SHIPMENT_DIRECTORY~n", []),
    halt(64).

finalize_application(Root, Application, DevelopmentModules) ->
    Name = atom_to_list(Application),
    Ebin = filename:join([Root, Name, "ebin"]),
    AppPath = filename:join(Ebin, Name ++ ".app"),
    {ok, [{application, Application, Properties}]} = file:consult(AppPath),
    Modules = proplists:get_value(modules, Properties),
    RuntimeModules = Modules -- DevelopmentModules,
    Updated = lists:keyreplace(modules, 1, Properties, {modules, RuntimeModules}),
    ok = file:write_file(
        AppPath,
        unicode:characters_to_binary(io_lib:format("~p.~n", [
            {application, Application, Updated}
        ]))),
    lists:foreach(
        fun(Module) ->
            Beam = filename:join(Ebin, atom_to_list(Module) ++ ".beam"),
            case file:delete(Beam) of
                ok -> ok;
                {error, enoent} -> ok
            end
        end,
        DevelopmentModules),
    lists:foreach(
        fun(Module) ->
            Beam = filename:join(Ebin, atom_to_list(Module) ++ ".beam"),
            true = filelib:is_regular(Beam)
        end,
        RuntimeModules),
    {ok, [{application, Application, Persisted}]} = file:consult(AppPath),
    PersistedModules = proplists:get_value(modules, Persisted),
    [] = [Module || Module <- DevelopmentModules,
                    lists:member(Module, PersistedModules)],
    ok.
