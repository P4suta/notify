%% SPDX-License-Identifier: Apache-2.0
-module(notify_attachment_stream_ffi).

-export([open_binary/1, open_reader/4, read/2, close/1]).

-define(READ_TIMEOUT_MILLISECONDS, 5000).

-spec open_binary(binary()) -> pid().
open_binary(Data) when is_binary(Data) ->
    Owner = self(),
    spawn(fun() ->
        Monitor = erlang:monitor(process, Owner),
        binary_loop(Data, 0, Monitor)
    end).

-spec open_reader(fun((integer(), pos_integer()) -> term()), fun(() -> term()),
                  integer(), integer()) -> pid().
open_reader(ReadAt, Cleanup, Start, End)
  when is_function(ReadAt, 2), is_function(Cleanup, 0),
       is_integer(Start), is_integer(End) ->
    Owner = self(),
    spawn(fun() ->
        Monitor = erlang:monitor(process, Owner),
        reader_loop(ReadAt, Cleanup, Start, End, Monitor)
    end).

-spec read(pid(), integer()) ->
    {ok, {1 | 2, binary()}} | {error, binary()}.
read(Source, Maximum)
  when is_pid(Source), is_integer(Maximum), Maximum > 0,
       Maximum =< 1024 * 1024 ->
    Reference = make_ref(),
    Monitor = erlang:monitor(process, Source),
    Source ! {read, self(), Reference, Maximum},
    receive
        {Reference, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Source, _Reason} ->
            {error, <<"closed">>}
    after ?READ_TIMEOUT_MILLISECONDS ->
        erlang:demonitor(Monitor, [flush]),
        {error, <<"timeout">>}
    end;
read(_, _) ->
    {error, <<"invalid_chunk">>}.

-spec close(term()) -> nil.
close(Source) when is_pid(Source) ->
    Source ! close,
    nil;
close(_) ->
    nil.

-spec binary_loop(binary(), non_neg_integer(), reference()) -> no_return().
binary_loop(Data, Offset, Monitor) ->
    receive
        {read, Caller, Reference, Maximum}
          when is_pid(Caller), is_reference(Reference),
               is_integer(Maximum), Maximum > 0,
               Maximum =< 1024 * 1024 ->
            Size = byte_size(Data),
            case Offset >= Size of
                true ->
                    Caller ! {Reference, {ok, {2, <<>>}}},
                    binary_loop(Data, Offset, Monitor);
                false ->
                    Length = erlang:min(Maximum, Size - Offset),
                    Chunk = binary:part(Data, Offset, Length),
                    Caller ! {Reference, {ok, {1, Chunk}}},
                    binary_loop(Data, Offset + Length, Monitor)
            end;
        close ->
            exit(normal);
        {'DOWN', Monitor, process, _Owner, _Reason} ->
            exit(normal);
        _Other ->
            binary_loop(Data, Offset, Monitor)
    end.

-spec reader_loop(fun((integer(), pos_integer()) -> term()), fun(() -> term()),
                  integer(), integer(), reference()) -> no_return().
reader_loop(ReadAt, Cleanup, Offset, End, Monitor) ->
    receive
        {read, Caller, Reference, Maximum}
          when is_pid(Caller), is_reference(Reference),
               is_integer(Maximum), Maximum > 0,
               Maximum =< 1024 * 1024 ->
            case Offset > End of
                true ->
                    Caller ! {Reference, {ok, {2, <<>>}}},
                    reader_loop(ReadAt, Cleanup, Offset, End, Monitor);
                false ->
                    Length = erlang:min(Maximum, End - Offset + 1),
                    case ReadAt(Offset, Length) of
                        {ok, Data} when is_binary(Data), byte_size(Data) =:= Length ->
                            Caller ! {Reference, {ok, {1, Data}}},
                            reader_loop(ReadAt, Cleanup, Offset + Length, End, Monitor);
                        {ok, _Data} ->
                            Caller ! {Reference, {error, <<"short_read">>}},
                            reader_loop(ReadAt, Cleanup, Offset, End, Monitor);
                        {error, _Reason} ->
                            Caller ! {Reference, {error, <<"reader_error">>}},
                            reader_loop(ReadAt, Cleanup, Offset, End, Monitor);
                        _Invalid ->
                            Caller ! {Reference, {error, <<"invalid_reader_result">>}},
                            reader_loop(ReadAt, Cleanup, Offset, End, Monitor)
                    end
            end;
        close ->
            run_cleanup(Cleanup),
            exit(normal);
        {'DOWN', Monitor, process, _Owner, _Reason} ->
            run_cleanup(Cleanup),
            exit(normal);
        _Other ->
            reader_loop(ReadAt, Cleanup, Offset, End, Monitor)
    end.

-spec run_cleanup(fun(() -> term())) -> ok.
run_cleanup(Cleanup) ->
    try Cleanup() of
        _ -> ok
    catch
        _:_ -> ok
    end.
