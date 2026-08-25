-module(notify_template_ffi).

-include_lib("kernel/include/file.hrl").

-export([render/2, load_file/2, render_builtin/2]).

-define(MAX_TEMPLATE_BYTES, 32768).
-define(MAX_OUTPUT_BYTES, 1048576).
-define(MAX_STEPS, 50000).
-define(MAX_DEPTH, 64).
-define(MAX_LOOP_SIZE, 10000).
-define(MAX_STRING_BYTES, 100000).
-define(MAX_INDENT, 100).
-define(TIMEOUT_MS, 100).
-define(MAX_TEMPLATE_FILE_BYTES, 98304).

load_file(Directory, Name) ->
    case valid_template_name(Name) of
        false -> {error, <<"not_found">>};
        true when Directory =:= <<>> -> {error, <<"not_found">>};
        true ->
            Path = filename:join(
                binary_to_list(Directory),
                binary_to_list(<<Name/binary, ".yml">>)
            ),
            read_template_file(Path)
    end.

read_template_file(Path) ->
    %% Do not follow symlinks out of the configured template directory.
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size}}
            when Size =< ?MAX_TEMPLATE_FILE_BYTES ->
            case file:open(Path, [read, raw, binary]) of
                {ok, Device} ->
                    Result = try file:pread(Device, 0, ?MAX_TEMPLATE_FILE_BYTES + 1)
                    after file:close(Device)
                    end,
                    case Result of
                        {ok, Content} when byte_size(Content) =< ?MAX_TEMPLATE_FILE_BYTES ->
                            parse_template_file(Content);
                        eof -> {error, <<"invalid">>};
                        _ -> {error, <<"invalid">>}
                    end;
                {error, _} -> {error, <<"invalid">>}
            end;
        {ok, #file_info{type = regular}} -> {error, <<"invalid">>};
        {ok, _} -> {error, <<"invalid">>};
        {error, enoent} -> {error, <<"not_found">>};
        {error, enotdir} -> {error, <<"not_found">>};
        {error, _} -> {error, <<"invalid">>}
    end.

valid_template_name(Name) when byte_size(Name) > 0, byte_size(Name) =< 128 ->
    case re:run(Name, <<"^[-_A-Za-z0-9]+$">>, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end;
valid_template_name(_) -> false.

render_builtin(Source, Name) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() ->
        Parent ! {Ref, render_builtin_sync(Source, Name)}
    end, [link, monitor]),
    receive
        {Ref, Result} ->
            unlink(Pid),
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            {error, <<"execution_failed">>}
    after ?TIMEOUT_MS ->
        unlink(Pid),
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush]),
        {error, <<"timeout">>}
    end.

render_builtin_sync(Source, Name) ->
    try
        Data = decode_source(Source),
        Fields = case Name of
            <<"grafana">> -> render_grafana(Data);
            <<"alertmanager">> -> render_alertmanager(Data);
            <<"github">> -> render_github(Data);
            _ -> throw({builtin_error, not_found})
        end,
        {ok, Fields}
    catch
        throw:{template_error, source_not_json} -> {error, <<"source_not_json">>};
        throw:{builtin_error, not_found} -> {error, <<"not_found">>};
        _:_ -> {error, <<"execution_failed">>}
    end.

render_grafana(Data) when is_map(Data) ->
    Status = builtin_field(Data, <<"status">>),
    SuppliedTitle = builtin_field(Data, <<"title">>),
    Title = case Status of
        <<"firing">> -> <<16#1F6A8/utf8, " ", (builtin_default(SuppliedTitle, <<"Alert firing">>))/binary>>;
        <<"resolved">> -> <<16#2705/utf8, " ", (builtin_default(SuppliedTitle, <<"Alert resolved">>))/binary>>;
        _ -> <<16#26A0/utf8, 16#FE0F/utf8, " Unknown alert: ", (builtin_default(SuppliedTitle, <<"Alert">>))/binary>>
    end,
    Message = truncate(2000, builtin_string(builtin_field(Data, <<"message">>))),
    [{<<"message">>, Message}, {<<"title">>, Title}];
render_grafana(_) -> throw({builtin_error, invalid}).

render_alertmanager(Data) when is_map(Data) ->
    Status = builtin_field(Data, <<"status">>),
    Alerts = builtin_list(builtin_field(Data, <<"alerts">>)),
    First = case Alerts of [Value | _] when is_map(Value) -> Value; _ -> #{} end,
    AlertName = builtin_nested(First, [<<"labels">>, <<"alertname">>]),
    Title = case Status of
        <<"firing">> -> <<16#1F6A8/utf8, " Alert: ", (builtin_string(AlertName))/binary>>;
        <<"resolved">> -> <<16#2705/utf8, " Resolved: ", (builtin_string(AlertName))/binary>>;
        _ -> throw({builtin_error, unsupported})
    end,
    Header = [
        <<"Status: ", (string_title(builtin_string(Status)))/binary>>,
        <<"Receiver: ", (builtin_string(builtin_field(Data, <<"receiver">>)))/binary>>,
        <<>>
    ],
    AlertLines = lists:append([alertmanager_lines(Alert) || Alert <- Alerts]),
    Message = trim(join_binaries(Header ++ AlertLines, <<"\n">>)),
    [{<<"message">>, Message}, {<<"title">>, Title}];
render_alertmanager(_) -> throw({builtin_error, invalid}).

alertmanager_lines(Alert) when is_map(Alert) ->
    Required = [
        <<"Alert: ", (builtin_string(builtin_nested(Alert, [<<"labels">>, <<"alertname">>])))/binary>>,
        <<"Instance: ", (builtin_string(builtin_nested(Alert, [<<"labels">>, <<"instance">>])))/binary>>,
        <<"Severity: ", (builtin_string(builtin_nested(Alert, [<<"labels">>, <<"severity">>])))/binary>>,
        <<"Starts at: ", (builtin_string(builtin_field(Alert, <<"startsAt">>)))/binary>>
    ],
    Ends = optional_builtin_line(
        <<"Ends at: ">>,
        builtin_field(Alert, <<"endsAt">>)
    ),
    Summary = optional_builtin_line(
        <<"Summary: ">>,
        builtin_nested(Alert, [<<"annotations">>, <<"summary">>])
    ),
    Description = optional_builtin_line(
        <<"Description: ">>,
        builtin_nested(Alert, [<<"annotations">>, <<"description">>])
    ),
    Required ++ Ends ++ Summary ++ Description ++ [
        <<"Source: ", (builtin_string(builtin_field(Alert, <<"generatorURL">>)))/binary>>,
        <<>>
    ];
alertmanager_lines(_) -> throw({builtin_error, invalid}).

render_github(Data) when is_map(Data) ->
    Action = builtin_field(Data, <<"action">>),
    Starred = builtin_field(Data, <<"starred_at">>),
    Repository = builtin_field(Data, <<"repository">>),
    Comment = builtin_field(Data, <<"comment">>),
    PullRequest = builtin_field(Data, <<"pull_request">>),
    Issue = builtin_field(Data, <<"issue">>),
    Kind = case {
        truthy(Starred) andalso Action =:= <<"created">>,
        truthy(Repository) andalso Action =:= <<"started">>,
        truthy(Comment) andalso Action =:= <<"created">>,
        truthy(PullRequest),
        truthy(Issue)
    } of
        {true, _, _, _, _} -> star;
        {_, true, _, _, _} -> watch;
        {_, _, true, _, _} -> comment;
        {_, _, _, true, _} -> pull_request;
        {_, _, _, _, true} -> issue;
        _ -> throw({builtin_error, unsupported})
    end,
    {Title, Message} = github_output(Kind, Data),
    [{<<"message">>, trim(Message)}, {<<"title">>, trim(Title)}];
render_github(_) -> throw({builtin_error, invalid}).

github_output(star, Data) ->
    Login = builtin_nested(Data, [<<"sender">>, <<"login">>]),
    Repository = builtin_nested(Data, [<<"repository">>, <<"name">>]),
    Title = <<16#2B50/utf8, " ", (builtin_string(Login))/binary, " starred ", (builtin_string(Repository))/binary>>,
    Message = join_binaries([
        <<"Stargazer: ", (builtin_string(builtin_nested(Data, [<<"sender">>, <<"html_url">>])))/binary>>,
        <<"Repository: ", (builtin_string(builtin_nested(Data, [<<"repository">>, <<"html_url">>])))/binary>>
    ], <<"\n">>),
    {Title, Message};
github_output(watch, Data) ->
    Login = builtin_nested(Data, [<<"sender">>, <<"login">>]),
    Repository = builtin_nested(Data, [<<"repository">>, <<"name">>]),
    Title = <<16#1F440/utf8, " ", (builtin_string(Login))/binary, " started watching ", (builtin_string(Repository))/binary>>,
    Message = join_binaries([
        <<"Watcher: ", (builtin_string(builtin_nested(Data, [<<"sender">>, <<"html_url">>])))/binary>>,
        <<"Repository: ", (builtin_string(builtin_nested(Data, [<<"repository">>, <<"html_url">>])))/binary>>
    ], <<"\n">>),
    {Title, Message};
github_output(comment, Data) ->
    Number = builtin_nested(Data, [<<"issue">>, <<"number">>]),
    IssueTitle = builtin_nested(Data, [<<"issue">>, <<"title">>]),
    Title = <<16#1F4AC/utf8, " New comment on issue #", (builtin_string(Number))/binary, " ", (builtin_string(IssueTitle))/binary>>,
    Base = [
        <<"Commenter: ", (builtin_string(builtin_nested(Data, [<<"comment">>, <<"user">>, <<"html_url">>])))/binary>>,
        <<"Repository: ", (builtin_string(builtin_nested(Data, [<<"repository">>, <<"html_url">>])))/binary>>,
        <<"Comment link: ", (builtin_string(builtin_nested(Data, [<<"comment">>, <<"html_url">>])))/binary>>
    ],
    Body = builtin_nested(Data, [<<"comment">>, <<"body">>]),
    Lines = case truthy(Body) of
        true -> Base ++ [<<"Comment:">>, truncate(2000, builtin_string(Body))];
        false -> Base
    end,
    {Title, join_binaries(Lines, <<"\n">>)};
github_output(pull_request, Data) ->
    Action = builtin_string(builtin_field(Data, <<"action">>)),
    Number = builtin_nested(Data, [<<"pull_request">>, <<"number">>]),
    Subject = builtin_nested(Data, [<<"pull_request">>, <<"title">>]),
    Title = <<16#1F500/utf8, " Pull request ", Action/binary, ": #", (builtin_string(Number))/binary, " ", (builtin_string(Subject))/binary>>,
    Base = [
        <<"Branch: ", (builtin_string(builtin_nested(Data, [<<"pull_request">>, <<"head">>, <<"ref">>])))/binary,
          " ", 16#2192/utf8, " ", (builtin_string(builtin_nested(Data, [<<"pull_request">>, <<"base">>, <<"ref">>])))/binary>>,
        <<(string_title(Action))/binary, " by: ", (builtin_string(builtin_nested(Data, [<<"pull_request">>, <<"user">>, <<"html_url">>])))/binary>>,
        <<"Repository: ", (builtin_string(builtin_nested(Data, [<<"repository">>, <<"html_url">>])))/binary>>,
        <<"Pull request: ", (builtin_string(builtin_nested(Data, [<<"pull_request">>, <<"html_url">>])))/binary>>
    ],
    Body = builtin_nested(Data, [<<"pull_request">>, <<"body">>]),
    Lines = case truthy(Body) of
        true -> Base ++ [<<"Description:">>, truncate(2000, builtin_string(Body))];
        false -> Base
    end,
    {Title, join_binaries(Lines, <<"\n">>)};
github_output(issue, Data) ->
    Action = builtin_string(builtin_field(Data, <<"action">>)),
    Number = builtin_nested(Data, [<<"issue">>, <<"number">>]),
    Subject = builtin_nested(Data, [<<"issue">>, <<"title">>]),
    Title = <<16#1F41B/utf8, " Issue ", Action/binary, ": #", (builtin_string(Number))/binary, " ", (builtin_string(Subject))/binary>>,
    Base = [
        <<(string_title(Action))/binary, " by: ", (builtin_string(builtin_nested(Data, [<<"issue">>, <<"user">>, <<"html_url">>])))/binary>>,
        <<"Repository: ", (builtin_string(builtin_nested(Data, [<<"repository">>, <<"html_url">>])))/binary>>,
        <<"Issue link: ", (builtin_string(builtin_nested(Data, [<<"issue">>, <<"html_url">>])))/binary>>
    ],
    Labels = builtin_list(builtin_nested(Data, [<<"issue">>, <<"labels">>])),
    LabelLine = case Labels of
        [] -> [];
        _ -> [<<"Labels: ", (join_binaries([
            builtin_string(builtin_field(Label, <<"name">>)) || Label <- Labels, is_map(Label)
        ], <<" ">>))/binary, " ">>]
    end,
    Body = builtin_nested(Data, [<<"issue">>, <<"body">>]),
    BodyLines = case truthy(Body) of
        true -> [<<"Description:">>, truncate(2000, builtin_string(Body))];
        false -> []
    end,
    {Title, join_binaries(Base ++ LabelLine ++ BodyLines, <<"\n">>)}.

builtin_field(Map, Key) when is_map(Map) -> maps:get(Key, Map, missing);
builtin_field(_, _) -> missing.

builtin_nested(Value, []) -> Value;
builtin_nested(Map, [Key | Rest]) when is_map(Map) ->
    builtin_nested(maps:get(Key, Map, missing), Rest);
builtin_nested(_, _) -> missing.

builtin_string(missing) -> <<"<no value>">>;
builtin_string(null) -> <<"<no value>">>;
builtin_string(Value) -> display(Value).

builtin_default(Value, Default) ->
    case truthy(Value) of true -> builtin_string(Value); false -> Default end.

builtin_list(Value) when is_list(Value), length(Value) =< ?MAX_LOOP_SIZE -> Value;
builtin_list(Value) when is_list(Value) -> throw({builtin_error, too_many_items});
builtin_list(_) -> [].

optional_builtin_line(Prefix, Value) ->
    case truthy(Value) of
        true -> [<<Prefix/binary, (builtin_string(Value))/binary>>];
        false -> []
    end.

parse_template_file(Content) ->
    try
        Normalized = binary:replace(Content, <<"\r\n">>, <<"\n">>, [global]),
        Lines = binary:split(Normalized, <<"\n">>, [global]),
        Fields = parse_yaml_lines(Lines, #{}),
        case map_size(Fields) > 0 of
            true -> {ok, lists:sort(maps:to_list(Fields))};
            false -> {error, <<"invalid">>}
        end
    catch
        throw:{template_file_error, _} -> {error, <<"invalid">>};
        _:_ -> {error, <<"invalid">>}
    end.

parse_yaml_lines([], Fields) -> Fields;
parse_yaml_lines([Line0 | Rest], Fields) ->
    Line = strip_yaml_cr(Line0),
    Trimmed = trim(Line),
    case Trimmed of
        <<>> -> parse_yaml_lines(Rest, Fields);
        <<$#, _/binary>> -> parse_yaml_lines(Rest, Fields);
        _ ->
            case top_level_yaml_line(Line) of
                {ok, Key, Indicator} ->
                    case maps:is_key(Key, Fields) of
                        true -> throw({template_file_error, duplicate_key});
                        false ->
                            {Value, Remaining} = yaml_value(Indicator, Rest),
                            parse_yaml_lines(Remaining, Fields#{Key => Value})
                    end;
                error -> throw({template_file_error, invalid_line})
            end
    end.

strip_yaml_cr(Binary) ->
    case byte_size(Binary) of
        0 -> Binary;
        Size ->
            case binary:at(Binary, Size - 1) of
                $\r -> binary:part(Binary, 0, Size - 1);
                _ -> Binary
            end
    end.

top_level_yaml_line(Line) ->
    case leading_spaces(Line) of
        0 ->
            case binary:split(Line, <<":">>) of
                [Key0, Value0] ->
                    Key = trim(Key0),
                    case lists:member(Key, [<<"title">>, <<"message">>, <<"priority">>]) of
                        true -> {ok, Key, trim(Value0)};
                        false -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.

yaml_value(Indicator, Rest)
        when Indicator =:= <<"|">>; Indicator =:= <<"|-">>;
             Indicator =:= <<"|+">>; Indicator =:= <<">">>;
             Indicator =:= <<">-">>; Indicator =:= <<">+">> ->
    {BlockLines, Remaining} = take_yaml_block(Rest, []),
    case BlockLines of
        [] -> {<<>>, Remaining};
        _ -> {render_yaml_block(Indicator, BlockLines), Remaining}
    end;
yaml_value(<<>>, _Rest) -> throw({template_file_error, null_value});
yaml_value(<<$\", _/binary>> = Quoted, Rest) ->
    try {json:decode(Quoted), Rest}
    catch _:_ -> throw({template_file_error, invalid_quote})
    end;
yaml_value(<<$', Value/binary>>, Rest) ->
    case byte_size(Value) > 0 andalso binary:at(Value, byte_size(Value) - 1) =:= $' of
        true ->
            Inner = binary:part(Value, 0, byte_size(Value) - 1),
            {binary:replace(Inner, <<"''">>, <<"'">>, [global]), Rest};
        false -> throw({template_file_error, invalid_quote})
    end;
yaml_value(Value, Rest) ->
    case binary:match(Value, <<" #">>) of
        {At, _} -> {trim(binary:part(Value, 0, At)), Rest};
        nomatch -> {Value, Rest}
    end.

take_yaml_block([], Acc) -> {lists:reverse(Acc), []};
take_yaml_block([Line | Rest] = All, Acc) ->
    case {trim(Line), leading_spaces(Line)} of
        {<<>>, _} -> take_yaml_block(Rest, [<<>> | Acc]);
        {_, Spaces} when Spaces > 0 -> take_yaml_block(Rest, [Line | Acc]);
        _ -> {lists:reverse(Acc), All}
    end.

render_yaml_block(Indicator, Lines) ->
    NonEmptyIndents = [leading_spaces(Line) || Line <- Lines, trim(Line) =/= <<>>],
    Indent = case NonEmptyIndents of [] -> 0; _ -> lists:min(NonEmptyIndents) end,
    Stripped = [strip_indent(Line, Indent) || Line <- Lines],
    Folded = case binary:at(Indicator, 0) of
        $| -> join_binaries(Stripped, <<"\n">>);
        $> -> fold_yaml_lines(Stripped, [])
    end,
    Chomp = case binary:last(Indicator) of
        $- -> strip_all_newlines(Folded);
        $+ -> <<Folded/binary, "\n">>;
        _ -> <<(strip_all_newlines(Folded))/binary, "\n">>
    end,
    Chomp.

leading_spaces(Binary) -> leading_spaces(Binary, 0).

leading_spaces(<<$\s, Rest/binary>>, Count) -> leading_spaces(Rest, Count + 1);
leading_spaces(<<$\t, _/binary>>, _Count) -> throw({template_file_error, tab_indent});
leading_spaces(_, Count) -> Count.

strip_indent(Line, Count) when byte_size(Line) >= Count ->
    binary:part(Line, Count, byte_size(Line) - Count);
strip_indent(_, _) -> <<>>.

fold_yaml_lines([], Acc) -> join_binaries(lists:reverse(Acc), <<>>);
fold_yaml_lines([Line | Rest], []) -> fold_yaml_lines(Rest, [Line]);
fold_yaml_lines([Line | Rest], [Previous | _] = Acc) ->
    Separator = case {Previous, Line} of
        {<<>>, _} -> <<"\n">>;
        {_, <<>>} -> <<"\n">>;
        _ -> <<" ">>
    end,
    fold_yaml_lines(Rest, [Line, Separator | Acc]).

strip_all_newlines(Binary) ->
    case byte_size(Binary) of
        0 -> Binary;
        Size ->
            case binary:at(Binary, Size - 1) of
                $\n -> strip_all_newlines(binary:part(Binary, 0, Size - 1));
                _ -> Binary
            end
    end.

%% This is an independent, deliberately small interpreter for the documented
%% ntfy template surface. It does not execute Erlang code and has no functions
%% that read the environment, filesystem, process table, or network.
render(_Source, Template) when byte_size(Template) > ?MAX_TEMPLATE_BYTES ->
    {error, <<"template_too_large">>};
render(Source, Template) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() ->
        Parent ! {Ref, render_sync(Source, Template)}
    end, [link, monitor]),
    receive
        {Ref, Result} ->
            unlink(Pid),
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            {error, <<"execution_failed">>}
    after ?TIMEOUT_MS ->
        unlink(Pid),
        exit(Pid, kill),
        receive
            {'DOWN', Monitor, process, Pid, _} -> ok
        after 0 ->
            erlang:demonitor(Monitor, [flush])
        end,
        receive
            {Ref, _LateResult} -> ok
        after 0 -> ok
        end,
        {error, <<"timeout">>}
    end.

render_sync(Source, Template) ->
    try
        Root = decode_source(Source),
        Tokens = scan_template(Template),
        Ast = parse_template(Tokens),
        State = #{
            root => Root,
            dot => Root,
            vars => #{},
            steps => 0,
            depth => 0
        },
        case eval_nodes(Ast, State, [], 0) of
            {ok, _FinalState, Output, _Size} ->
                Raw = iolist_to_binary(lists:reverse(Output)),
                Expanded = binary:replace(Raw, <<"\\n">>, <<"\n">>, [global]),
                Trimmed = unicode:characters_to_binary(string:trim(Expanded)),
                {ok, Trimmed};
            {control, _, _, _, _} ->
                template_error(execution_failed)
        end
    catch
        throw:{template_error, source_not_json} ->
            {error, <<"source_not_json">>};
        throw:{template_error, template_too_large} ->
            {error, <<"template_too_large">>};
        throw:{template_error, invalid_template} ->
            {error, <<"invalid_template">>};
        throw:{template_error, disallowed} ->
            {error, <<"disallowed">>};
        throw:{template_error, timeout} ->
            {error, <<"timeout">>};
        throw:{template_error, _} ->
            {error, <<"execution_failed">>};
        _:_ ->
            {error, <<"execution_failed">>}
    end.

decode_source(Source) ->
    try normalise_json_value(json:decode(Source))
    catch
        _:_ -> template_error(source_not_json)
    end.

%% encoding/json decodes every JSON number into float64 when the destination is
%% interface{}, which is the data model exposed by ntfy's templates.
normalise_json_value(Value) when is_integer(Value) -> Value * 1.0;
normalise_json_value(Value) when is_list(Value) ->
    [normalise_json_value(Item) || Item <- Value];
normalise_json_value(Value) when is_map(Value) ->
    maps:map(fun(_Key, Item) -> normalise_json_value(Item) end, Value);
normalise_json_value(Value) -> Value.

template_error(Reason) ->
    throw({template_error, Reason}).

%% --------------------------------------------------------------------------
%% Template scanner and structural parser
%% --------------------------------------------------------------------------

scan_template(Template) ->
    lists:reverse(scan_template(Template, false, [])).

scan_template(<<>>, _TrimNext, Acc) ->
    Acc;
scan_template(Binary, TrimNext, Acc) ->
    case binary:match(Binary, <<"{{">>) of
        nomatch ->
            add_text(maybe_trim_left(Binary, TrimNext), Acc);
        {OpenAt, 2} ->
            Prefix0 = binary:part(Binary, 0, OpenAt),
            AfterOpen0 = binary:part(
                Binary,
                OpenAt + 2,
                byte_size(Binary) - OpenAt - 2
            ),
            {OpenTrim, AfterOpen} = opening_trim(AfterOpen0),
            Prefix1 = maybe_trim_left(Prefix0, TrimNext),
            Prefix = case OpenTrim of
                true -> trim_right(Prefix1);
                false -> Prefix1
            end,
            Acc1 = case {OpenTrim, byte_size(Prefix)} of
                {true, 0} -> trim_previous_text(Acc);
                _ -> add_text(Prefix, Acc)
            end,
            case binary:match(AfterOpen, <<"}}">>) of
                nomatch -> template_error(invalid_template);
                {CloseAt, 2} ->
                    Action0 = binary:part(AfterOpen, 0, CloseAt),
                    Rest = binary:part(
                        AfterOpen,
                        CloseAt + 2,
                        byte_size(AfterOpen) - CloseAt - 2
                    ),
                    {CloseTrim, Action1} = closing_trim(Action0),
                    Action = trim(Action1),
                    Acc2 = case is_comment(Action) of
                        true -> Acc1;
                        false -> [{action, Action} | Acc1]
                    end,
                    scan_template(Rest, CloseTrim, Acc2)
            end
    end.

opening_trim(<<$-, Rest/binary>>) -> {true, Rest};
opening_trim(Binary) -> {false, Binary}.

closing_trim(Binary) ->
    case byte_size(Binary) of
        0 -> {false, Binary};
        Size ->
            case binary:at(Binary, Size - 1) of
                $- -> {true, binary:part(Binary, 0, Size - 1)};
                _ -> {false, Binary}
            end
    end.

is_comment(<<"/*", Rest/binary>>) ->
    Size = byte_size(Rest),
    Size >= 2 andalso binary:part(Rest, Size - 2, 2) =:= <<"*/">>;
is_comment(_) -> false.

add_text(<<>>, Acc) -> Acc;
add_text(Text, [{text, Previous} | Rest]) ->
    [{text, <<Previous/binary, Text/binary>>} | Rest];
add_text(Text, Acc) -> [{text, Text} | Acc].

trim_previous_text([{text, Text} | Rest]) ->
    case trim_right(Text) of
        <<>> -> Rest;
        Trimmed -> [{text, Trimmed} | Rest]
    end;
trim_previous_text(Acc) -> Acc.

maybe_trim_left(Binary, true) -> trim_left(Binary);
maybe_trim_left(Binary, false) -> Binary.

trim(Binary) ->
    unicode:characters_to_binary(string:trim(Binary)).

trim_left(Binary) ->
    trim_left(Binary, 0).

trim_left(Binary, Offset) when Offset >= byte_size(Binary) -> <<>>;
trim_left(Binary, Offset) ->
    case whitespace(binary:at(Binary, Offset)) of
        true -> trim_left(Binary, Offset + 1);
        false -> binary:part(Binary, Offset, byte_size(Binary) - Offset)
    end.

trim_right(<<>>) -> <<>>;
trim_right(Binary) ->
    trim_right(Binary, byte_size(Binary) - 1).

trim_right(_Binary, Offset) when Offset < 0 -> <<>>;
trim_right(Binary, Offset) ->
    case whitespace(binary:at(Binary, Offset)) of
        true -> trim_right(Binary, Offset - 1);
        false -> binary:part(Binary, 0, Offset + 1)
    end.

whitespace($\s) -> true;
whitespace($\t) -> true;
whitespace($\n) -> true;
whitespace($\r) -> true;
whitespace(_) -> false.

parse_template(Tokens) ->
    {Nodes, Rest, Terminator} = parse_nodes(Tokens, false, 0),
    case {Rest, Terminator} of
        {[], none} -> Nodes;
        _ -> template_error(invalid_template)
    end.

parse_nodes(_Tokens, _Nested, Depth) when Depth > ?MAX_DEPTH ->
    template_error(invalid_template);
parse_nodes([], false, _Depth) -> {[], [], none};
parse_nodes([], true, _Depth) -> template_error(invalid_template);
parse_nodes([{text, Text} | Rest], Nested, Depth) ->
    {Nodes, Remaining, Terminator} = parse_nodes(Rest, Nested, Depth),
    {[{text, Text} | Nodes], Remaining, Terminator};
parse_nodes([{action, Action} | Rest], Nested, Depth) ->
    ensure_not_disallowed(Action),
    case action_terminator(Action) of
        end_action when Nested -> {[], Rest, end_action};
        {else_action, Expression} when Nested ->
            {[], Rest, {else_action, Expression}};
        end_action -> template_error(invalid_template);
        {else_action, _} -> template_error(invalid_template);
        none ->
            {Node, AfterNode} = parse_action(Action, Rest, Depth),
            {Nodes, Remaining, Terminator} =
                parse_nodes(AfterNode, Nested, Depth),
            {[Node | Nodes], Remaining, Terminator}
    end.

action_terminator(<<"end">>) -> end_action;
action_terminator(<<"else">>) -> {else_action, <<>>};
action_terminator(<<"else ", Expression/binary>>) ->
    {else_action, trim(Expression)};
action_terminator(_) -> none.

parse_action(Action, Rest, Depth) ->
    case keyword_rest(Action, <<"if">>) of
        {true, Expression} -> parse_if(Expression, Rest, Depth + 1);
        false ->
            case keyword_rest(Action, <<"range">>) of
                {true, Expression} -> parse_range(Expression, Rest, Depth + 1);
                false ->
                    case keyword_rest(Action, <<"with">>) of
                        {true, Expression} ->
                            parse_with(Expression, Rest, Depth + 1);
                        false -> parse_simple_action(Action, Rest)
                    end
            end
    end.

parse_if(<<>>, _Rest, _Depth) -> template_error(invalid_template);
parse_if(Expression, Rest, Depth) ->
    Pipeline = compile_pipeline(Expression),
    {Then, AfterThen, Terminator} = parse_nodes(Rest, true, Depth),
    case Terminator of
        end_action -> {{if_node, Pipeline, Then, []}, AfterThen};
        {else_action, <<>>} ->
            {Else, AfterElse, End} = parse_nodes(AfterThen, true, Depth),
            case End of
                end_action -> {{if_node, Pipeline, Then, Else}, AfterElse};
                _ -> template_error(invalid_template)
            end;
        {else_action, ElseAction} ->
            case keyword_rest(ElseAction, <<"if">>) of
                {true, ElseExpression} ->
                    {ElseIf, AfterElseIf} =
                        parse_if(ElseExpression, AfterThen, Depth),
                    {{if_node, Pipeline, Then, [ElseIf]}, AfterElseIf};
                false -> template_error(invalid_template)
            end;
        _ -> template_error(invalid_template)
    end.

parse_range(<<>>, _Rest, _Depth) -> template_error(invalid_template);
parse_range(Expression, Rest, Depth) ->
    {Variables, Pipeline} = compile_range(Expression),
    {Body, AfterBody, Terminator} = parse_nodes(Rest, true, Depth),
    case Terminator of
        end_action -> {{range_node, Variables, Pipeline, Body, []}, AfterBody};
        {else_action, <<>>} ->
            {Else, AfterElse, End} = parse_nodes(AfterBody, true, Depth),
            case End of
                end_action ->
                    {{range_node, Variables, Pipeline, Body, Else}, AfterElse};
                _ -> template_error(invalid_template)
            end;
        _ -> template_error(invalid_template)
    end.

parse_with(<<>>, _Rest, _Depth) -> template_error(invalid_template);
parse_with(Expression, Rest, Depth) ->
    Pipeline = compile_pipeline(Expression),
    {Body, AfterBody, Terminator} = parse_nodes(Rest, true, Depth),
    case Terminator of
        end_action -> {{with_node, Pipeline, Body, []}, AfterBody};
        {else_action, <<>>} ->
            {Else, AfterElse, End} = parse_nodes(AfterBody, true, Depth),
            case End of
                end_action -> {{with_node, Pipeline, Body, Else}, AfterElse};
                _ -> template_error(invalid_template)
            end;
        _ -> template_error(invalid_template)
    end.

parse_simple_action(<<>>, _Rest) -> template_error(invalid_template);
parse_simple_action(<<"break">>, Rest) -> {break_node, Rest};
parse_simple_action(<<"continue">>, Rest) -> {continue_node, Rest};
parse_simple_action(Action, Rest) ->
    Tokens = lex(Action),
    case assignment_tokens(Tokens) of
        {assignment, Mode, Variable, ExpressionTokens} ->
            Pipeline = compile_pipeline_tokens(ExpressionTokens),
            {{assign_node, Mode, Variable, Pipeline}, Rest};
        none -> {{eval_node, compile_pipeline_tokens(Tokens)}, Rest}
    end.

keyword_rest(Action, Keyword) ->
    KeywordSize = byte_size(Keyword),
    case Action of
        Keyword -> {true, <<>>};
        <<Keyword:KeywordSize/binary, $\s, Rest/binary>> -> {true, trim(Rest)};
        <<Keyword:KeywordSize/binary, $\t, Rest/binary>> -> {true, trim(Rest)};
        <<Keyword:KeywordSize/binary, $\n, Rest/binary>> -> {true, trim(Rest)};
        _ -> false
    end.

ensure_not_disallowed(Action) ->
    case starts_disallowed(Action) orelse contains_call_identifier(Action) of
        true -> template_error(disallowed);
        false -> ok
    end.

starts_disallowed(Action) ->
    lists:any(
        fun(Keyword) ->
            case keyword_rest(Action, Keyword) of
                {true, _} -> true;
                false -> false
            end
        end,
        [<<"define">>, <<"template">>, <<"block">>]
    ).

contains_call_identifier(Action) ->
    case re:run(
        Action,
        <<"(^|[[:space:]|(])call([[:space:]|).]|$)">>,
        [{capture, none}, unicode]
    ) of
        match -> true;
        nomatch -> false
    end.

%% --------------------------------------------------------------------------
%% Expression lexer/compiler
%% --------------------------------------------------------------------------

lex(Binary) ->
    lists:reverse(lex(Binary, [])).

lex(<<>>, Acc) -> Acc;
lex(<<Character, Rest/binary>>, Acc)
        when Character =:= $\s; Character =:= $\t;
             Character =:= $\n; Character =:= $\r ->
    lex(Rest, Acc);
lex(<<$(, Rest/binary>>, Acc) -> lex(Rest, [left_parenthesis | Acc]);
lex(<<$), $., Rest/binary>>, Acc) ->
    {WordRest, After} = take_word(Rest, []),
    Word = <<$., WordRest/binary>>,
    lex(After, [{suffix, Word}, right_parenthesis | Acc]);
lex(<<$), Rest/binary>>, Acc) -> lex(Rest, [right_parenthesis | Acc]);
lex(<<$|, Rest/binary>>, Acc) -> lex(Rest, [pipe | Acc]);
lex(<<$,, Rest/binary>>, Acc) -> lex(Rest, [comma | Acc]);
lex(<<$:, $=, Rest/binary>>, Acc) -> lex(Rest, [declare | Acc]);
lex(<<$=, Rest/binary>>, Acc) -> lex(Rest, [assign | Acc]);
lex(<<$\", Rest/binary>>, Acc) ->
    {String, After} = take_quoted(Rest, $\", [], false),
    lex(After, [{string, decode_quoted(String)} | Acc]);
lex(<<$`, Rest/binary>>, Acc) ->
    {String, After} = take_raw(Rest, []),
    lex(After, [{string, String} | Acc]);
lex(<<$', Rest/binary>>, Acc) ->
    {String, After} = take_quoted(Rest, $', [], false),
    lex(After, [{string, decode_single_quoted(String)} | Acc]);
lex(Binary, Acc) ->
    {Word, Rest} = take_word(Binary, []),
    case Word of
        <<>> -> template_error(invalid_template);
        _ -> lex(Rest, [{word, Word} | Acc])
    end.

take_word(<<>>, Acc) -> {list_to_binary(lists:reverse(Acc)), <<>>};
take_word(<<Character, _/binary>> = Binary, Acc)
        when Character =:= $\s; Character =:= $\t;
             Character =:= $\n; Character =:= $\r;
             Character =:= $(; Character =:= $);
             Character =:= $|; Character =:= $,;
             Character =:= $= ->
    {list_to_binary(lists:reverse(Acc)), Binary};
take_word(<<$:, $=, _/binary>> = Binary, Acc) ->
    {list_to_binary(lists:reverse(Acc)), Binary};
take_word(<<Character, Rest/binary>>, Acc) ->
    take_word(Rest, [Character | Acc]).

take_quoted(<<>>, _Quote, _Acc, _Escaped) ->
    template_error(invalid_template);
take_quoted(<<Character, Rest/binary>>, Quote, Acc, false)
        when Character =:= Quote ->
    {list_to_binary(lists:reverse(Acc)), Rest};
take_quoted(<<$\\, Rest/binary>>, Quote, Acc, false) ->
    take_quoted(Rest, Quote, [$\\ | Acc], true);
take_quoted(<<Character, Rest/binary>>, Quote, Acc, true) ->
    take_quoted(Rest, Quote, [Character | Acc], false);
take_quoted(<<Character, Rest/binary>>, Quote, Acc, false) ->
    take_quoted(Rest, Quote, [Character | Acc], false).

take_raw(<<>>, _Acc) -> template_error(invalid_template);
take_raw(<<$`, Rest/binary>>, Acc) ->
    {list_to_binary(lists:reverse(Acc)), Rest};
take_raw(<<Character, Rest/binary>>, Acc) ->
    take_raw(Rest, [Character | Acc]).

decode_quoted(Content) ->
    try json:decode(<<$\", Content/binary, $\">>)
    catch _:_ -> template_error(invalid_template)
    end.

decode_single_quoted(Content) ->
    case unicode:characters_to_list(Content) of
        [Character] -> Character;
        [$\\, $n] -> $\n;
        [$\\, $t] -> $\t;
        _ -> template_error(invalid_template)
    end.

assignment_tokens([{word, Variable}, declare | Expression]) ->
    validate_variable(Variable),
    {assignment, declare, Variable, Expression};
assignment_tokens([{word, Variable}, assign | Expression]) ->
    validate_variable(Variable),
    {assignment, assign, Variable, Expression};
assignment_tokens(_) -> none.

compile_range(Expression) ->
    Tokens = lex(Expression),
    case Tokens of
        [{word, First}, comma, {word, Second}, declare | Rest] ->
            validate_variable(First),
            validate_variable(Second),
            {[First, Second], compile_pipeline_tokens(Rest)};
        [{word, Variable}, declare | Rest] ->
            validate_variable(Variable),
            {[Variable], compile_pipeline_tokens(Rest)};
        _ -> {[], compile_pipeline_tokens(Tokens)}
    end.

validate_variable(<<$$, Name/binary>>) when byte_size(Name) > 0 -> ok;
validate_variable(_) -> template_error(invalid_template).

compile_pipeline(Binary) -> compile_pipeline_tokens(lex(Binary)).

compile_pipeline_tokens([]) -> template_error(invalid_template);
compile_pipeline_tokens(Tokens) ->
    CommandTokens = split_pipeline(Tokens, 0, [], []),
    [compile_command(Command) || Command <- CommandTokens].

split_pipeline([], 0, Current, Commands) ->
    lists:reverse([lists:reverse(Current) | Commands]);
split_pipeline([], _Depth, _Current, _Commands) ->
    template_error(invalid_template);
split_pipeline([pipe | _Rest], 0, [], _Commands) ->
    template_error(invalid_template);
split_pipeline([pipe | Rest], 0, Current, Commands) ->
    split_pipeline(Rest, 0, [], [lists:reverse(Current) | Commands]);
split_pipeline([left_parenthesis = Token | Rest], Depth, Current, Commands) ->
    split_pipeline(Rest, Depth + 1, [Token | Current], Commands);
split_pipeline([right_parenthesis = Token | Rest], Depth, Current, Commands)
        when Depth > 0 ->
    split_pipeline(Rest, Depth - 1, [Token | Current], Commands);
split_pipeline([right_parenthesis | _], 0, _Current, _Commands) ->
    template_error(invalid_template);
split_pipeline([Token | Rest], Depth, Current, Commands) ->
    split_pipeline(Rest, Depth, [Token | Current], Commands).

compile_command([]) -> template_error(invalid_template);
compile_command(Tokens) ->
    {Terms, Rest} = compile_terms(Tokens, []),
    case {Terms, Rest} of
        {[], _} -> template_error(invalid_template);
        {_, []} -> command_from_terms(Terms);
        _ -> template_error(invalid_template)
    end.

compile_terms([], Acc) -> {lists:reverse(Acc), []};
compile_terms([comma | Rest], Acc) -> compile_terms(Rest, Acc);
compile_terms([left_parenthesis | Rest], Acc) ->
    {Inside, AfterGroup} = take_group(Rest, 1, []),
    Group = {group, compile_pipeline_tokens(Inside)},
    case AfterGroup of
        [{suffix, Path} | AfterSuffix] ->
            compile_terms(AfterSuffix, [{chain, Group, path_parts(Path)} | Acc]);
        _ -> compile_terms(AfterGroup, [Group | Acc])
    end;
compile_terms([right_parenthesis | _] = Rest, Acc) ->
    {lists:reverse(Acc), Rest};
compile_terms([{suffix, _} | _], _Acc) -> template_error(invalid_template);
compile_terms([{string, Value} | Rest], Acc) ->
    compile_terms(Rest, [{literal, Value} | Acc]);
compile_terms([{word, Word} | Rest], Acc) ->
    compile_terms(Rest, [compile_word(Word) | Acc]);
compile_terms(_, _) -> template_error(invalid_template).

take_group([], _Depth, _Acc) -> template_error(invalid_template);
take_group([right_parenthesis | Rest], 1, Acc) ->
    {lists:reverse(Acc), Rest};
take_group([left_parenthesis = Token | Rest], Depth, Acc) ->
    take_group(Rest, Depth + 1, [Token | Acc]);
take_group([right_parenthesis = Token | Rest], Depth, Acc) ->
    take_group(Rest, Depth - 1, [Token | Acc]);
take_group([Token | Rest], Depth, Acc) ->
    take_group(Rest, Depth, [Token | Acc]).

command_from_terms([{bare, Function} | Arguments]) ->
    case allowed_function(Function) of
        true -> {call, Function, Arguments};
        false -> template_error(invalid_template)
    end;
command_from_terms([Value]) -> {value, Value};
command_from_terms(_) -> template_error(invalid_template).

compile_word(<<$., _/binary>> = Path) -> {path, dot, path_parts(Path)};
compile_word(<<$$>>) -> {path, root, []};
compile_word(<<$$, $., Rest/binary>>) ->
    {path, root, path_parts(<<".", Rest/binary>>)};
compile_word(<<$$, _/binary>> = Variable) -> compile_variable_path(Variable);
compile_word(<<"true">>) -> {literal, true};
compile_word(<<"false">>) -> {literal, false};
compile_word(<<"nil">>) -> {literal, null};
compile_word(Word) ->
    case parse_number(Word) of
        {ok, Number} -> {literal, Number};
        error -> {bare, Word}
    end.

compile_variable_path(Variable) ->
    case binary:split(Variable, <<".">>) of
        [Name] -> {variable, Name, []};
        [Name, Rest] -> {variable, Name, path_parts(<<".", Rest/binary>>)}
    end.

path_parts(<<".">>) -> [];
path_parts(<<$., Rest/binary>>) ->
    case binary:split(Rest, <<".">>, [global]) of
        Parts when is_list(Parts) ->
            case lists:any(fun(Part) -> Part =:= <<>> end, Parts) of
                true -> template_error(invalid_template);
                false -> Parts
            end
    end;
path_parts(_) -> template_error(invalid_template).

parse_number(Binary) ->
    try {ok, binary_to_integer(Binary)}
    catch
        _:_ ->
            try {ok, binary_to_float(Binary)}
            catch _:_ -> error
            end
    end.

allowed_function(Name) ->
    lists:member(Name, [
        <<"and">>, <<"or">>, <<"not">>, <<"len">>, <<"index">>,
        <<"slice">>, <<"print">>, <<"printf">>, <<"println">>,
        <<"eq">>, <<"ne">>, <<"lt">>, <<"le">>, <<"gt">>, <<"ge">>,
        <<"trim">>, <<"trimAll">>, <<"trimSuffix">>, <<"trimPrefix">>,
        <<"upper">>, <<"lower">>, <<"title">>, <<"repeat">>,
        <<"substr">>, <<"trunc">>, <<"contains">>, <<"hasPrefix">>,
        <<"hasSuffix">>, <<"quote">>, <<"squote">>, <<"cat">>,
        <<"indent">>, <<"nindent">>, <<"replace">>, <<"plural">>,
        <<"toString">>, <<"atoi">>, <<"until">>, <<"untilStep">>,
        <<"add1">>, <<"add">>, <<"sub">>, <<"div">>, <<"mod">>,
        <<"mul">>, <<"max">>, <<"min">>, <<"maxf">>, <<"minf">>,
        <<"ceil">>, <<"floor">>, <<"round">>, <<"join">>,
        <<"sortAlpha">>, <<"default">>, <<"empty">>, <<"coalesce">>,
        <<"all">>, <<"any">>, <<"compact">>, <<"fromJSON">>,
        <<"toJSON">>, <<"toPrettyJSON">>, <<"toRawJSON">>,
        <<"ternary">>, <<"list">>, <<"tuple">>, <<"dict">>,
        <<"get">>, <<"hasKey">>, <<"keys">>, <<"values">>,
        <<"append">>, <<"push">>, <<"prepend">>, <<"first">>,
        <<"rest">>, <<"last">>, <<"initial">>, <<"reverse">>,
        <<"uniq">>, <<"without">>, <<"has">>, <<"concat">>,
        <<"dig">>, <<"chunk">>, <<"fail">>, <<"typeOf">>,
        <<"typeIs">>, <<"typeIsLike">>, <<"kindOf">>, <<"kindIs">>,
        <<"deepEqual">>, <<"sha1sum">>, <<"sha256sum">>,
        <<"sha512sum">>, <<"adler32sum">>, <<"b64enc">>, <<"b64dec">>,
        <<"b32enc">>, <<"b32dec">>, <<"base">>, <<"dir">>,
        <<"clean">>, <<"ext">>, <<"isAbs">>
    ]).

%% --------------------------------------------------------------------------
%% Evaluator
%% --------------------------------------------------------------------------

eval_nodes([], State, Output, Size) -> {ok, State, Output, Size};
eval_nodes([Node | Rest], State0, Output0, Size0) ->
    State = tick(State0),
    case eval_node(Node, State, Output0, Size0) of
        {ok, NextState, NextOutput, NextSize} ->
            eval_nodes(Rest, NextState, NextOutput, NextSize);
        {control, _, _, _, _} = Control -> Control
    end.

eval_node({text, Text}, State, Output, Size) ->
    append_output(Text, State, Output, Size);
eval_node({eval_node, Pipeline}, State0, Output, Size) ->
    {Value, State} = eval_pipeline(Pipeline, State0),
    append_output(display(Value), State, Output, Size);
eval_node({assign_node, Mode, Variable, Pipeline}, State0, Output, Size) ->
    {Value, State1} = eval_pipeline(Pipeline, State0),
    Vars = maps:get(vars, State1),
    case Mode =:= assign andalso not maps:is_key(Variable, Vars) of
        true -> template_error(execution_failed);
        false ->
            {ok, State1#{vars := Vars#{Variable => Value}}, Output, Size}
    end;
eval_node({if_node, Pipeline, Then, Else}, State0, Output, Size) ->
    {Value, State} = eval_pipeline(Pipeline, State0),
    Branch = case truthy(Value) of true -> Then; false -> Else end,
    eval_scoped(Branch, State, Output, Size, maps:get(dot, State));
eval_node({with_node, Pipeline, Body, Else}, State0, Output, Size) ->
    {Value, State1} = eval_pipeline(Pipeline, State0),
    OldDot = maps:get(dot, State1),
    case truthy(Value) of
        true -> eval_scoped(Body, State1#{dot := Value}, Output, Size, OldDot);
        false -> eval_scoped(Else, State1, Output, Size, OldDot)
    end;
eval_node({range_node, Variables, Pipeline, Body, Else}, State0, Output, Size) ->
    {Value, State1} = eval_pipeline(Pipeline, State0),
    Pairs = range_pairs(Value),
    case Pairs of
        [] -> eval_scoped(Else, State1, Output, Size, maps:get(dot, State1));
        _ -> eval_range(Pairs, Variables, Body, State1, Output, Size)
    end;
eval_node(break_node, State, Output, Size) ->
    {control, break, State, Output, Size};
eval_node(continue_node, State, Output, Size) ->
    {control, continue, State, Output, Size}.

eval_scoped(Nodes, State, Output, Size, OldDot) ->
    OldVars = maps:get(vars, State),
    case eval_nodes(Nodes, State, Output, Size) of
        {ok, Next, NextOutput, NextSize} ->
            Restored = restore_outer_vars(OldVars, maps:get(vars, Next), []),
            {ok, Next#{dot := OldDot, vars := Restored}, NextOutput, NextSize};
        {control, Kind, Next, NextOutput, NextSize} ->
            Restored = restore_outer_vars(OldVars, maps:get(vars, Next), []),
            {control, Kind, Next#{dot := OldDot, vars := Restored}, NextOutput, NextSize}
    end.

eval_range(Pairs, Variables, Body, State, Output, Size) ->
    OldDot = maps:get(dot, State),
    OldVars = maps:get(vars, State),
    eval_range(Pairs, Variables, Body, State, Output, Size, OldDot, OldVars).

eval_range([], Variables, _Body, State, Output, Size, OldDot, OldVars) ->
    Restored = restore_outer_vars(OldVars, maps:get(vars, State), Variables),
    {ok, State#{dot := OldDot, vars := Restored}, Output, Size};
eval_range([{Key, Value} | Rest], Variables, Body, State0, Output, Size,
        OldDot, OldVars) ->
    State1 = tick(State0),
    Vars = bind_range_variables(Variables, Key, Value, maps:get(vars, State1)),
    IterationState = State1#{dot := Value, vars := Vars},
    case eval_nodes(Body, IterationState, Output, Size) of
        {ok, Next, NextOutput, NextSize} ->
            eval_range(
                Rest,
                Variables,
                Body,
                Next,
                NextOutput,
                NextSize,
                OldDot,
                OldVars
            );
        {control, continue, Next, NextOutput, NextSize} ->
            eval_range(
                Rest,
                Variables,
                Body,
                Next,
                NextOutput,
                NextSize,
                OldDot,
                OldVars
            );
        {control, break, Next, NextOutput, NextSize} ->
            Restored = restore_outer_vars(
                OldVars,
                maps:get(vars, Next),
                Variables
            ),
            {ok, Next#{dot := OldDot, vars := Restored}, NextOutput, NextSize}
    end.

restore_outer_vars(OldVars, NewVars, Shadowed) ->
    maps:fold(
        fun(Key, OldValue, Restored) ->
            Value = case lists:member(Key, Shadowed) of
                true -> OldValue;
                false -> maps:get(Key, NewVars, OldValue)
            end,
            Restored#{Key => Value}
        end,
        #{},
        OldVars
    ).

bind_range_variables([], _Key, _Value, Vars) -> Vars;
bind_range_variables([Variable], _Key, Value, Vars) -> Vars#{Variable => Value};
bind_range_variables([KeyVariable, ValueVariable], Key, Value, Vars) ->
    Vars#{KeyVariable => Key, ValueVariable => Value}.

range_pairs(List) when is_list(List) ->
    case length(List) > ?MAX_LOOP_SIZE of
        true -> template_error(execution_failed);
        false -> lists:zip(lists:seq(0, length(List) - 1), List)
    end;
range_pairs(Map) when is_map(Map) ->
    case map_size(Map) > ?MAX_LOOP_SIZE of
        true -> template_error(execution_failed);
        false ->
            Keys = lists:sort(maps:keys(Map)),
            [{Key, maps:get(Key, Map)} || Key <- Keys]
    end;
range_pairs(_) -> [].

tick(State) ->
    Steps = maps:get(steps, State) + 1,
    case Steps > ?MAX_STEPS of
        true -> template_error(timeout);
        false -> State#{steps := Steps}
    end.

append_output(<<>>, State, Output, Size) -> {ok, State, Output, Size};
append_output(Binary, State, Output, Size) when is_binary(Binary) ->
    NewSize = Size + byte_size(Binary),
    case NewSize > ?MAX_OUTPUT_BYTES of
        true -> template_error(execution_failed);
        false -> {ok, State, [Binary | Output], NewSize}
    end.

eval_pipeline(Commands, State) -> eval_pipeline(Commands, State, none).

eval_pipeline([], _State, none) -> template_error(execution_failed);
eval_pipeline([], State, {some, Value}) -> {Value, State};
eval_pipeline([Command | Rest], State0, Previous) ->
    {Value, State} = eval_command(Command, Previous, State0),
    eval_pipeline(Rest, State, {some, Value}).

eval_command({value, Term}, none, State) -> eval_term(Term, State);
eval_command({value, _}, {some, _}, _State) -> template_error(execution_failed);
eval_command({call, <<"and">>, Terms}, Previous, State) ->
    eval_and(append_previous_terms(Terms, Previous), State, true);
eval_command({call, <<"or">>, Terms}, Previous, State) ->
    eval_or(append_previous_terms(Terms, Previous), State, false);
eval_command({call, Function, Terms}, Previous, State0) ->
    {Arguments0, State} = eval_terms(Terms, State0, []),
    Arguments = append_previous_value(Arguments0, Previous),
    {apply_function(Function, Arguments), State}.

append_previous_terms(Terms, none) -> Terms;
append_previous_terms(Terms, {some, Value}) -> Terms ++ [{literal, Value}].

append_previous_value(Values, none) -> Values;
append_previous_value(Values, {some, Value}) -> Values ++ [Value].

eval_terms([], State, Acc) -> {lists:reverse(Acc), State};
eval_terms([Term | Rest], State0, Acc) ->
    {Value, State} = eval_term(Term, State0),
    eval_terms(Rest, State, [Value | Acc]).

eval_and([], State, Last) -> {Last, State};
eval_and([Term | Rest], State0, _Last) ->
    {Value, State} = eval_term(Term, State0),
    case truthy(Value) of
        false -> {Value, State};
        true -> eval_and(Rest, State, Value)
    end.

eval_or([], State, Last) -> {Last, State};
eval_or([Term | Rest], State0, _Last) ->
    {Value, State} = eval_term(Term, State0),
    case truthy(Value) of
        true -> {Value, State};
        false -> eval_or(Rest, State, Value)
    end.

eval_term({literal, Value}, State) -> {Value, State};
eval_term({path, dot, Parts}, State) ->
    {lookup_path(maps:get(dot, State), Parts), State};
eval_term({path, root, Parts}, State) ->
    {lookup_path(maps:get(root, State), Parts), State};
eval_term({variable, Name, Parts}, State) ->
    Value = maps:get(Name, maps:get(vars, State), missing),
    {lookup_path(Value, Parts), State};
eval_term({group, Pipeline}, State) -> eval_pipeline(Pipeline, State);
eval_term({chain, Group, Parts}, State0) ->
    {Value, State} = eval_term(Group, State0),
    {lookup_path(Value, Parts), State};
eval_term({bare, _}, _State) -> template_error(execution_failed).

lookup_path(Value, []) -> Value;
lookup_path(missing, _Parts) -> missing;
lookup_path(Map, [Part | Rest]) when is_map(Map) ->
    lookup_path(maps:get(Part, Map, missing), Rest);
lookup_path(_, _Parts) -> missing.

truthy(false) -> false;
truthy(null) -> false;
truthy(missing) -> false;
truthy(0) -> false;
truthy(Value) when is_float(Value), Value == 0 -> false;
truthy(<<>>) -> false;
truthy([]) -> false;
truthy(Map) when is_map(Map) -> map_size(Map) > 0;
truthy(_) -> true.

display(missing) -> <<"<no value>">>;
display(null) -> <<"<no value>">>;
display(true) -> <<"true">>;
display(false) -> <<"false">>;
display(Value) when is_binary(Value) -> Value;
display(Value) when is_integer(Value) -> integer_to_binary(Value);
display(Value) when is_float(Value) -> display_float(Value);
display(Value) when is_list(Value) ->
    <<"[", (join_binaries([display(Item) || Item <- Value], <<" ">>))/binary, "]">>;
display(Value) when is_map(Value) ->
    Pairs = [
        <<(display(Key))/binary, ":", (display(maps:get(Key, Value)))/binary>>
        || Key <- lists:sort(maps:keys(Value))
    ],
    <<"map[", (join_binaries(Pairs, <<" ">>))/binary, "]">>;
display(_) -> <<"<no value>">>.

display_float(Value) ->
    Encoded = float_to_binary(Value, [short]),
    case Encoded of
        <<Whole:(byte_size(Encoded) - 2)/binary, ".0">> -> Whole;
        _ ->
            case binary:split(Encoded, <<"e">>) of
                [Mantissa, <<Sign, _/binary>> = Exponent]
                    when Sign =:= $+; Sign =:= $- ->
                    <<Mantissa/binary, "e", Exponent/binary>>;
                [Mantissa, Exponent] ->
                    <<Mantissa/binary, "e+", Exponent/binary>>;
                [_] -> Encoded
            end
    end.

%% --------------------------------------------------------------------------
%% Safe function set
%% --------------------------------------------------------------------------

apply_function(<<"not">>, [Value]) -> not truthy(Value);
apply_function(<<"len">>, [Value]) when is_binary(Value) ->
    length(unicode:characters_to_list(Value));
apply_function(<<"len">>, [Value]) when is_list(Value) -> length(Value);
apply_function(<<"len">>, [Value]) when is_map(Value) -> map_size(Value);
apply_function(<<"len">>, _) -> template_error(execution_failed);
apply_function(<<"eq">>, [First | Rest]) when Rest =/= [] ->
    lists:any(fun(Value) -> equal(First, Value) end, Rest);
apply_function(<<"ne">>, [Left, Right]) -> not equal(Left, Right);
apply_function(<<"lt">>, [Left, Right]) -> compare(Left, Right) < 0;
apply_function(<<"le">>, [Left, Right]) -> compare(Left, Right) =< 0;
apply_function(<<"gt">>, [Left, Right]) -> compare(Left, Right) > 0;
apply_function(<<"ge">>, [Left, Right]) -> compare(Left, Right) >= 0;
apply_function(<<"print">>, Values) -> print_values(Values, false);
apply_function(<<"println">>, Values) ->
    <<(print_values(Values, true))/binary, "\n">>;
apply_function(<<"printf">>, [Format | Values]) when is_binary(Format) ->
    template_printf(Format, Values);
apply_function(<<"index">>, [Collection | Indices]) when Indices =/= [] ->
    lists:foldl(fun index_value/2, Collection, Indices);
apply_function(<<"slice">>, [Collection, Start]) -> slice_value(Collection, Start, none);
apply_function(<<"slice">>, [Collection, Start, End]) ->
    slice_value(Collection, Start, {some, End});

apply_function(<<"trim">>, [Value]) -> trim(require_binary(Value));
apply_function(<<"trimAll">>, [Cutset, Value]) ->
    trim_chars(require_binary(Value), require_binary(Cutset));
apply_function(<<"trimPrefix">>, [Prefix, Value]) ->
    remove_prefix(require_binary(Value), require_binary(Prefix));
apply_function(<<"trimSuffix">>, [Suffix, Value]) ->
    remove_suffix(require_binary(Value), require_binary(Suffix));
apply_function(<<"upper">>, [Value]) -> string_upper(require_binary(Value));
apply_function(<<"lower">>, [Value]) -> string_lower(require_binary(Value));
apply_function(<<"title">>, [Value]) -> string_title(require_binary(Value));
apply_function(<<"repeat">>, [Count, Value]) ->
    bounded_repeat(require_integer(Count), require_binary(Value));
apply_function(<<"trunc">>, [Count, Value]) ->
    truncate(require_integer(Count), require_binary(Value));
apply_function(<<"substr">>, [Start, End, Value]) ->
    substring(require_integer(Start), require_integer(End), require_binary(Value));
apply_function(<<"contains">>, [Part, Value]) ->
    binary:match(require_binary(Value), require_binary(Part)) =/= nomatch;
apply_function(<<"hasPrefix">>, [Prefix, Value]) ->
    has_prefix(require_binary(Value), require_binary(Prefix));
apply_function(<<"hasSuffix">>, [Suffix, Value]) ->
    has_suffix(require_binary(Value), require_binary(Suffix));
apply_function(<<"quote">>, Values) ->
    join_binaries([iolist_to_binary(json:encode(display(Value))) || Value <- Values], <<" ">>);
apply_function(<<"squote">>, Values) ->
    join_binaries([<<"'", (display(Value))/binary, "'">> || Value <- Values], <<" ">>);
apply_function(<<"cat">>, Values) ->
    join_binaries([display(Value) || Value <- Values, Value =/= null, Value =/= missing], <<" ">>);
apply_function(<<"indent">>, [Spaces, Value]) ->
    indent(require_integer(Spaces), require_binary(Value), false);
apply_function(<<"nindent">>, [Spaces, Value]) ->
    indent(require_integer(Spaces), require_binary(Value), true);
apply_function(<<"replace">>, [Old, New, Value]) ->
    bounded_binary_replace(
        require_binary(Value),
        require_binary(Old),
        require_binary(New)
    );
apply_function(<<"plural">>, [One, Many, Count]) ->
    case require_integer(Count) of
        1 -> require_binary(One);
        _ -> require_binary(Many)
    end;
apply_function(<<"toString">>, [Value]) -> display(Value);
apply_function(<<"atoi">>, [Value]) -> to_integer(Value);

apply_function(<<"until">>, [Count]) -> until(0, require_integer(Count), auto);
apply_function(<<"untilStep">>, [Start, Stop, Step]) ->
    until(require_integer(Start), require_integer(Stop), require_integer(Step));
apply_function(<<"add1">>, [Value]) -> to_integer(Value) + 1;
apply_function(<<"add">>, Values) -> lists:sum([to_integer(Value) || Value <- Values]);
apply_function(<<"sub">>, [Left, Right]) -> to_integer(Left) - to_integer(Right);
apply_function(<<"div">>, [Left, Right]) ->
    Divisor = to_integer(Right),
    case Divisor of 0 -> template_error(execution_failed); _ -> to_integer(Left) div Divisor end;
apply_function(<<"mod">>, [Left, Right]) ->
    Divisor = to_integer(Right),
    case Divisor of 0 -> template_error(execution_failed); _ -> to_integer(Left) rem Divisor end;
apply_function(<<"mul">>, Values) ->
    lists:foldl(fun(Value, Product) -> to_integer(Value) * Product end, 1, Values);
apply_function(<<"max">>, Values) when Values =/= [] ->
    lists:max([to_integer(Value) || Value <- Values]);
apply_function(<<"min">>, Values) when Values =/= [] ->
    lists:min([to_integer(Value) || Value <- Values]);
apply_function(<<"maxf">>, Values) when Values =/= [] ->
    lists:max([to_float(Value) || Value <- Values]);
apply_function(<<"minf">>, Values) when Values =/= [] ->
    lists:min([to_float(Value) || Value <- Values]);
apply_function(<<"ceil">>, [Value]) -> ceil_number(to_float(Value)) * 1.0;
apply_function(<<"floor">>, [Value]) -> floor_number(to_float(Value)) * 1.0;
apply_function(<<"round">>, [Value, Precision]) ->
    round_decimal(to_float(Value), require_integer(Precision));
apply_function(<<"round">>, [Value, Precision, RoundOn]) ->
    round_decimal(
        to_float(Value),
        require_integer(Precision),
        to_float(RoundOn)
    );

apply_function(<<"join">>, [Separator, Values]) ->
    join_binaries(to_string_list(Values), require_binary(Separator));
apply_function(<<"sortAlpha">>, [Values]) -> lists:sort(to_string_list(Values));
apply_function(<<"default">>, [Default, Value]) ->
    case truthy(Value) of true -> Value; false -> Default end;
apply_function(<<"empty">>, [Value]) -> not truthy(Value);
apply_function(<<"coalesce">>, Values) -> first_truthy(Values);
apply_function(<<"all">>, Values) -> lists:all(fun truthy/1, Values);
apply_function(<<"any">>, Values) -> lists:any(fun truthy/1, Values);
apply_function(<<"compact">>, [Values]) when is_list(Values) ->
    bounded_list([Value || Value <- require_list(Values), truthy(Value)]);
apply_function(<<"fromJSON">>, [Value]) -> decode_json_or_empty(require_binary(Value));
apply_function(<<"toJSON">>, [Value]) -> encode_json(Value);
apply_function(<<"toPrettyJSON">>, [Value]) -> encode_pretty_json(Value);
apply_function(<<"toRawJSON">>, [Value]) -> encode_raw_json(Value);
apply_function(<<"ternary">>, [TrueValue, FalseValue, Test]) ->
    case truthy(Test) of true -> TrueValue; false -> FalseValue end;

apply_function(<<"list">>, Values) -> bounded_list(Values);
apply_function(<<"tuple">>, Values) -> bounded_list(Values);
apply_function(<<"dict">>, Values) -> make_dict(Values, #{});
apply_function(<<"get">>, [Map, Key]) when is_map(Map) ->
    maps:get(display(Key), Map, <<>>);
apply_function(<<"hasKey">>, [Map, Key]) when is_map(Map) ->
    maps:is_key(display(Key), Map);
apply_function(<<"keys">>, Maps) ->
    bounded_list(lists:usort(lists:append([
        maps:keys(Map) || Map <- Maps, is_map(Map)
    ])));
apply_function(<<"values">>, [Map]) when is_map(Map) ->
    bounded_list([maps:get(Key, Map) || Key <- lists:sort(maps:keys(Map))]);
apply_function(Name, [Values, Value])
        when Name =:= <<"append">>; Name =:= <<"push">> ->
    bounded_list(require_list(Values) ++ [Value]);
apply_function(<<"prepend">>, [Values, Value]) ->
    bounded_list([Value | require_list(Values)]);
apply_function(<<"first">>, [Values]) ->
    case require_list(Values) of [] -> null; [First | _] -> First end;
apply_function(<<"rest">>, [Values]) ->
    case require_list(Values) of [] -> []; [_ | Rest] -> Rest end;
apply_function(<<"last">>, [Values]) ->
    case require_list(Values) of [] -> null; List -> lists:last(List) end;
apply_function(<<"initial">>, [Values]) ->
    case require_list(Values) of [] -> []; List -> lists:droplast(List) end;
apply_function(<<"reverse">>, [Values]) -> lists:reverse(require_list(Values));
apply_function(<<"uniq">>, [Values]) -> unique(require_list(Values), []);
apply_function(<<"without">>, [Values | Excluded]) ->
    [Value || Value <- require_list(Values), not member_equal(Value, Excluded)];
apply_function(<<"has">>, [Needle, Values]) -> member_equal(Needle, require_list(Values));
apply_function(<<"concat">>, Values) ->
    bounded_list(lists:append([require_list(Value) || Value <- Values]));
apply_function(<<"dig">>, Arguments) -> dig(Arguments);
apply_function(<<"chunk">>, [Size, Values]) ->
    chunk(require_integer(Size), require_list(Values));
apply_function(<<"fail">>, [_Message]) -> template_error(execution_failed);

apply_function(<<"typeOf">>, [Value]) -> type_name(Value);
apply_function(<<"kindOf">>, [Value]) -> kind_name(Value);
apply_function(<<"typeIs">>, [Name, Value]) -> require_binary(Name) =:= type_name(Value);
apply_function(<<"typeIsLike">>, [Name, Value]) -> require_binary(Name) =:= type_name(Value);
apply_function(<<"kindIs">>, [Name, Value]) -> require_binary(Name) =:= kind_name(Value);
apply_function(<<"deepEqual">>, [Left, Right]) -> equal(Left, Right);
apply_function(<<"sha1sum">>, [Value]) -> hash(sha, Value);
apply_function(<<"sha256sum">>, [Value]) -> hash(sha256, Value);
apply_function(<<"sha512sum">>, [Value]) -> hash(sha512, Value);
apply_function(<<"adler32sum">>, [Value]) -> integer_to_binary(erlang:adler32(display(Value)));
apply_function(<<"b64enc">>, [Value]) -> base64:encode(display(Value));
apply_function(<<"b64dec">>, [Value]) -> decode_base64(display(Value));
apply_function(<<"b32enc">>, [Value]) -> base32_encode(display(Value));
apply_function(<<"b32dec">>, [Value]) -> base32_decode(display(Value));
apply_function(<<"base">>, [Value]) -> path_base(require_binary(Value));
apply_function(<<"dir">>, [Value]) -> path_dir(require_binary(Value));
apply_function(<<"clean">>, [Value]) -> path_clean(require_binary(Value));
apply_function(<<"ext">>, [Value]) -> path_ext(require_binary(Value));
apply_function(<<"isAbs">>, [Value]) -> has_prefix(require_binary(Value), <<"/">>);
apply_function(_, _) -> template_error(execution_failed).

require_binary(Value) when is_binary(Value) -> Value;
require_binary(_) -> template_error(execution_failed).

require_integer(Value) when is_integer(Value) -> Value;
require_integer(_) -> template_error(execution_failed).

require_list(Value) when is_list(Value), length(Value) =< ?MAX_LOOP_SIZE -> Value;
require_list(_) -> template_error(execution_failed).

equal(Left, Right) when is_number(Left), is_number(Right) -> Left == Right;
equal(Left, Right) -> Left =:= Right.

compare(Left, Right) when is_number(Left), is_number(Right) ->
    if Left < Right -> -1; Left > Right -> 1; true -> 0 end;
compare(Left, Right) when is_binary(Left), is_binary(Right) ->
    if Left < Right -> -1; Left > Right -> 1; true -> 0 end;
compare(_, _) -> template_error(execution_failed).

print_values([], _SpacesBetweenAll) -> <<>>;
print_values([First | Rest], SpacesBetweenAll) ->
    iolist_to_binary(print_values(Rest, First, SpacesBetweenAll, [display(First)])).

print_values([], _Previous, _SpacesBetweenAll, Acc) -> lists:reverse(Acc);
print_values([Value | Rest], Previous, SpacesBetweenAll, Acc) ->
    Separator = case SpacesBetweenAll orelse
        (not is_binary(Previous) andalso not is_binary(Value)) of
        true -> <<" ">>;
        false -> <<>>
    end,
    print_values(
        Rest,
        Value,
        SpacesBetweenAll,
        [display(Value), Separator | Acc]
    ).

index_value(Index, Map) when is_map(Map) -> maps:get(display(Index), Map, missing);
index_value(Index, List) when is_list(List), is_integer(Index), Index >= 0 ->
    case length(List) > Index of true -> lists:nth(Index + 1, List); false -> template_error(execution_failed) end;
index_value(_, _) -> template_error(execution_failed).

slice_value(Value, Start0, End0) ->
    Start = require_integer(Start0),
    Length = case Value of
        Binary when is_binary(Binary) -> byte_size(Binary);
        List when is_list(List) -> length(List);
        _ -> template_error(execution_failed)
    end,
    End = case End0 of none -> Length; {some, RawEnd} -> require_integer(RawEnd) end,
    case Start >= 0 andalso End >= Start andalso End =< Length of
        false -> template_error(execution_failed);
        true when is_binary(Value) -> binary:part(Value, Start, End - Start);
        true -> lists:sublist(lists:nthtail(Start, Value), End - Start)
    end.

string_upper(Value) -> unicode:characters_to_binary(string:uppercase(Value)).
string_lower(Value) -> unicode:characters_to_binary(string:lowercase(Value)).
string_title(Value) -> unicode:characters_to_binary(string:titlecase(Value)).

bounded_repeat(Count, Value) when Count >= 0, Count =< ?MAX_LOOP_SIZE ->
    Bytes = Count * byte_size(Value),
    case Bytes >= ?MAX_STRING_BYTES of
        true -> template_error(execution_failed);
        false -> binary:copy(Value, Count)
    end;
bounded_repeat(_, _) -> template_error(execution_failed).

truncate(Count, Value) ->
    Size = byte_size(Value),
    case Count of
        _ when Count >= 0, Count < Size -> binary:part(Value, 0, Count);
        _ when Count < 0, Size + Count > 0 -> binary:part(Value, Size + Count, -Count);
        _ -> Value
    end.

substring(Start, End, Value) ->
    Size = byte_size(Value),
    ActualStart = case Start < 0 of true -> 0; false -> Start end,
    ActualEnd = case End < 0 orelse End > Size of true -> Size; false -> End end,
    case ActualStart =< ActualEnd andalso ActualEnd =< Size of
        true -> binary:part(Value, ActualStart, ActualEnd - ActualStart);
        false -> template_error(execution_failed)
    end.

has_prefix(Value, Prefix) when byte_size(Prefix) =< byte_size(Value) ->
    binary:part(Value, 0, byte_size(Prefix)) =:= Prefix;
has_prefix(_, _) -> false.

has_suffix(Value, Suffix) when byte_size(Suffix) =< byte_size(Value) ->
    binary:part(Value, byte_size(Value) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix;
has_suffix(_, _) -> false.

remove_prefix(Value, Prefix) ->
    case has_prefix(Value, Prefix) of
        true -> binary:part(Value, byte_size(Prefix), byte_size(Value) - byte_size(Prefix));
        false -> Value
    end.

remove_suffix(Value, Suffix) ->
    case has_suffix(Value, Suffix) of
        true -> binary:part(Value, 0, byte_size(Value) - byte_size(Suffix));
        false -> Value
    end.

trim_chars(Value, Cutset) ->
    Chars = unicode:characters_to_list(Cutset),
    List = unicode:characters_to_list(Value),
    unicode:characters_to_binary(trim_chars_right(trim_chars_left(List, Chars), Chars)).

trim_chars_left([Character | Rest], Chars) ->
    case lists:member(Character, Chars) of true -> trim_chars_left(Rest, Chars); false -> [Character | Rest] end;
trim_chars_left([], _) -> [].

trim_chars_right(List, Chars) -> lists:reverse(trim_chars_left(lists:reverse(List), Chars)).

indent(Spaces, Value, Newline) when Spaces >= 0, Spaces =< ?MAX_INDENT ->
    Pad = binary:copy(<<" ">>, Spaces),
    Indented = <<Pad/binary, (binary:replace(Value, <<"\n">>, <<"\n", Pad/binary>>, [global]))/binary>>,
    case byte_size(Indented) > ?MAX_STRING_BYTES of
        true -> template_error(execution_failed);
        false when Newline -> <<"\n", Indented/binary>>;
        false -> Indented
    end;
indent(_, _, _) -> template_error(execution_failed).

bounded_binary_replace(Value, <<>>, New) ->
    Characters = unicode:characters_to_list(Value),
    Pieces = [unicode:characters_to_binary([Character]) || Character <- Characters],
    Estimated = byte_size(Value) + (length(Pieces) + 1) * byte_size(New),
    case Estimated > ?MAX_STRING_BYTES of
        true -> template_error(execution_failed);
        false -> <<New/binary, (join_binaries(Pieces, New))/binary, New/binary>>
    end;
bounded_binary_replace(Value, Old, New) ->
    Matches = binary:matches(Value, Old),
    Estimated = byte_size(Value) + length(Matches) * (byte_size(New) - byte_size(Old)),
    case Estimated > ?MAX_STRING_BYTES of
        true -> template_error(execution_failed);
        false -> binary:replace(Value, Old, New, [global])
    end.

until(Start, Stop, auto) ->
    Step = case Stop < Start of true -> -1; false -> 1 end,
    until(Start, Stop, Step);
until(_Start, _Stop, 0) -> [];
until(Start, Stop, Step) ->
    Count = case {Step > 0, Stop > Start, Step < 0, Stop < Start} of
        {true, true, _, _} -> (Stop - Start + Step - 1) div Step;
        {_, _, true, true} -> (Start - Stop + (-Step) - 1) div (-Step);
        _ -> 0
    end,
    case Count > ?MAX_LOOP_SIZE of
        true -> template_error(execution_failed);
        false -> until_values(Start, Stop, Step, [])
    end.

until_values(Current, Stop, Step, Acc)
        when (Step > 0 andalso Current >= Stop) orelse
             (Step < 0 andalso Current =< Stop) ->
    lists:reverse(Acc);
until_values(Current, Stop, Step, Acc) ->
    until_values(Current + Step, Stop, Step, [Current | Acc]).

to_integer(Value) when is_integer(Value) -> Value;
to_integer(Value) when is_float(Value) -> trunc(Value);
to_integer(Value) when is_binary(Value) ->
    try binary_to_integer(Value) catch _:_ -> 0 end;
to_integer(true) -> 1;
to_integer(_) -> 0.

to_float(Value) when is_float(Value) -> Value;
to_float(Value) when is_integer(Value) -> Value * 1.0;
to_float(Value) when is_binary(Value) ->
    try binary_to_float(Value)
    catch _:_ -> to_integer(Value) * 1.0
    end;
to_float(_) -> 0.0.

ceil_number(Value) ->
    Truncated = trunc(Value),
    case Value > Truncated of true -> Truncated + 1; false -> Truncated end.

floor_number(Value) ->
    Truncated = trunc(Value),
    case Value < Truncated of true -> Truncated - 1; false -> Truncated end.

round_decimal(Value, Precision) -> round_decimal(Value, Precision, 0.5).

round_decimal(Value, Precision, RoundOn)
        when Precision >= -18, Precision =< 18, is_number(RoundOn) ->
    Scale = math:pow(10, Precision),
    Digit = Value * Scale,
    Fraction = Digit - trunc(Digit),
    Rounded = case Fraction >= RoundOn of
        true -> ceil_number(Digit);
        false -> floor_number(Digit)
    end,
    Rounded / Scale;
round_decimal(_, _, _) -> template_error(execution_failed).

to_string_list(Value) when is_list(Value) -> [display(Item) || Item <- Value];
to_string_list(null) -> [];
to_string_list(missing) -> [];
to_string_list(Value) -> [display(Value)].

first_truthy([]) -> null;
first_truthy([Value | Rest]) -> case truthy(Value) of true -> Value; false -> first_truthy(Rest) end.

decode_json_or_empty(Value) ->
    try normalise_json_value(json:decode(Value)) catch _:_ -> <<>> end.

encode_json(missing) -> <<"null">>;
encode_json(Value) ->
    try escape_json_html(iolist_to_binary(json:encode(json_encode_value(Value))))
    catch _:_ -> <<>>
    end.

encode_raw_json(missing) -> <<"null">>;
encode_raw_json(Value) ->
    try iolist_to_binary(json:encode(json_encode_value(Value)))
    catch _:_ -> <<>>
    end.

encode_pretty_json(missing) -> <<"null">>;
encode_pretty_json(Value) ->
    try escape_json_html(pretty_json(json_encode_value(Value), 0))
    catch _:_ -> <<>>
    end.

json_encode_value(Value) when is_float(Value) ->
    case Value == trunc(Value) andalso abs(Value) < 1.0e21 of
        true -> trunc(Value);
        false -> Value
    end;
json_encode_value(Value) when is_list(Value) ->
    [json_encode_value(Item) || Item <- Value];
json_encode_value(Value) when is_map(Value) ->
    maps:map(fun(_Key, Item) -> json_encode_value(Item) end, Value);
json_encode_value(missing) -> null;
json_encode_value(Value) -> Value.

pretty_json(Map, _Depth) when is_map(Map), map_size(Map) =:= 0 -> <<"{}">>;
pretty_json(Map, Depth) when is_map(Map) ->
    Indent = pretty_indent(Depth + 1),
    ClosingIndent = pretty_indent(Depth),
    Entries = [
        <<Indent/binary, (encode_raw_json(Key))/binary, ": ",
          (pretty_json(maps:get(Key, Map), Depth + 1))/binary>>
        || Key <- lists:sort(maps:keys(Map))
    ],
    <<"{\n", (join_binaries(Entries, <<",\n">>))/binary,
      "\n", ClosingIndent/binary, "}">>;
pretty_json([], _Depth) -> <<"[]">>;
pretty_json(List, Depth) when is_list(List) ->
    Indent = pretty_indent(Depth + 1),
    ClosingIndent = pretty_indent(Depth),
    Entries = [
        <<Indent/binary, (pretty_json(Item, Depth + 1))/binary>>
        || Item <- List
    ],
    <<"[\n", (join_binaries(Entries, <<",\n">>))/binary,
      "\n", ClosingIndent/binary, "]">>;
pretty_json(Value, _Depth) -> encode_raw_json(Value).

pretty_indent(Depth) when Depth >= 0, Depth =< ?MAX_DEPTH ->
    binary:copy(<<" ">>, Depth * 2);
pretty_indent(_) -> template_error(execution_failed).

escape_json_html(Value) ->
    Replacements = [
        {<<"&">>, <<"\\u0026">>},
        {<<"<">>, <<"\\u003c">>},
        {<<">">>, <<"\\u003e">>},
        {<<16#2028/utf8>>, <<"\\u2028">>},
        {<<16#2029/utf8>>, <<"\\u2029">>}
    ],
    lists:foldl(
        fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
        Value,
        Replacements
    ).

bounded_list(Values) when length(Values) =< ?MAX_LOOP_SIZE -> Values;
bounded_list(_) -> template_error(execution_failed).

make_dict([], Map) -> Map;
make_dict([Key, Value | Rest], Map) ->
    make_dict(Rest, Map#{display(Key) => Value});
make_dict(_, _) -> template_error(execution_failed).

unique([], Acc) -> lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case member_equal(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.

member_equal(Needle, Values) -> lists:any(fun(Value) -> equal(Needle, Value) end, Values).

dig(Arguments) when length(Arguments) >= 3 ->
    Map = lists:last(Arguments),
    Default = lists:nth(length(Arguments) - 1, Arguments),
    Keys = lists:sublist(Arguments, length(Arguments) - 2),
    case dig_keys(Keys, Map) of missing -> Default; Value -> Value end;
dig(_) -> template_error(execution_failed).

dig_keys([], Value) -> Value;
dig_keys([Key | Rest], Map) when is_map(Map) ->
    dig_keys(Rest, maps:get(display(Key), Map, missing));
dig_keys(_, _) -> missing.

chunk(Size, Values) when Size > 0 ->
    Count = (length(Values) + Size - 1) div Size,
    case Count > ?MAX_LOOP_SIZE of
        true -> template_error(execution_failed);
        false -> chunk_values(Size, Values, [])
    end;
chunk(_, _) -> template_error(execution_failed).

chunk_values(_Size, [], Acc) -> lists:reverse(Acc);
chunk_values(Size, Values, Acc) ->
    {Head, Tail} = lists:split(min(Size, length(Values)), Values),
    chunk_values(Size, Tail, [Head | Acc]).

type_name(Value) when is_binary(Value) -> <<"string">>;
type_name(Value) when is_integer(Value) -> <<"int64">>;
type_name(Value) when is_float(Value) -> <<"float64">>;
type_name(Value) when is_list(Value) -> <<"[]interface {}">>;
type_name(Value) when is_map(Value) -> <<"map[string]interface {}">>;
type_name(Value) when is_boolean(Value) -> <<"bool">>;
type_name(_) -> <<"<nil>">>.

kind_name(Value) when is_binary(Value) -> <<"string">>;
kind_name(Value) when is_integer(Value) -> <<"int64">>;
kind_name(Value) when is_float(Value) -> <<"float64">>;
kind_name(Value) when is_list(Value) -> <<"slice">>;
kind_name(Value) when is_map(Value) -> <<"map">>;
kind_name(Value) when is_boolean(Value) -> <<"bool">>;
kind_name(_) -> <<"invalid">>.

hash(Algorithm, Value) ->
    binary:encode_hex(crypto:hash(Algorithm, display(Value)), lowercase).

decode_base64(Value) ->
    try base64:decode(Value) catch _:_ -> template_error(execution_failed) end.

base32_encode(Value) ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>,
    Bits = <<Value/binary, 0:((5 - (bit_size(Value) rem 5)) rem 5)>>,
    Encoded = << <<(binary:at(Alphabet, Index))>> || <<Index:5>> <= Bits >>,
    Padding = (8 - (byte_size(Encoded) rem 8)) rem 8,
    <<Encoded/binary, (binary:copy(<<"=">>, Padding))/binary>>.

base32_decode(Value) ->
    Clean = binary:replace(string_upper(Value), <<"=">>, <<>>, [global]),
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>,
    try
        Bits = << <<(base32_index(Character, Alphabet)):5>> || <<Character>> <= Clean >>,
        WholeBytes = bit_size(Bits) div 8,
        <<Decoded:WholeBytes/binary, _/bitstring>> = Bits,
        Decoded
    catch _:_ -> template_error(execution_failed)
    end.

base32_index(Character, Alphabet) ->
    case binary:match(Alphabet, <<Character>>) of
        {Index, 1} -> Index;
        nomatch -> template_error(execution_failed)
    end.

path_base(Value) ->
    Parts = [Part || Part <- binary:split(Value, <<"/">>, [global]), Part =/= <<>>],
    case Parts of [] -> <<".">>; _ -> lists:last(Parts) end.

path_dir(Value) ->
    case binary:matches(Value, <<"/">>) of
        [] -> <<".">>;
        Matches ->
            {Index, _} = lists:last(Matches),
            case Index of 0 -> <<"/">>; _ -> binary:part(Value, 0, Index) end
    end.

path_clean(Value) ->
    %% filename:join normalises dot segments without accessing the filesystem.
    unicode:characters_to_binary(filename:join(binary:split(Value, <<"/">>, [global]))).

path_ext(Value) ->
    Base = path_base(Value),
    case binary:matches(Base, <<".">>) of
        [] -> <<>>;
        Matches ->
            {Index, _} = lists:last(Matches),
            binary:part(Base, Index, byte_size(Base) - Index)
    end.

join_binaries([], _Separator) -> <<>>;
join_binaries([First | Rest], Separator) ->
    iolist_to_binary([First | [[Separator, Value] || Value <- Rest]]).

%% Minimal fmt-compatible formatter for the safe text/template verbs. Width and
%% precision are validated at execution time, including dynamically assembled
%% format strings, before any padding allocation occurs.
template_printf(Format, Arguments) ->
    validate_printf(Format),
    iolist_to_binary(format_percent(Format, Arguments, [])).

validate_printf(Format) ->
    WithoutEscaped = binary:replace(Format, <<"%%">>, <<>>, [global]),
    case re:run(
        WithoutEscaped,
        <<"%[-+# 0-9.*\\[\\]]*(\\*|[0-9]{4})">>,
        [{capture, none}]
    ) of
        match -> template_error(execution_failed);
        nomatch -> ok
    end.

format_percent(<<>>, [], Acc) -> lists:reverse(Acc);
format_percent(<<>>, _Arguments, _Acc) -> template_error(execution_failed);
format_percent(<<"%%", Rest/binary>>, Arguments, Acc) ->
    format_percent(Rest, Arguments, [<<"%">> | Acc]);
format_percent(<<$%, Rest/binary>>, [Argument | Arguments], Acc) ->
    {Directive, After} = take_directive(Rest, []),
    Formatted = format_directive(Directive, Argument),
    format_percent(After, Arguments, [Formatted | Acc]);
format_percent(<<$%, _/binary>>, [], _Acc) -> template_error(execution_failed);
format_percent(<<Character, Rest/binary>>, Arguments, Acc) ->
    format_percent(Rest, Arguments, [<<Character>> | Acc]).

take_directive(<<>>, _Acc) -> template_error(execution_failed);
take_directive(<<Character, Rest/binary>>, Acc)
        when (Character >= $a andalso Character =< $z) orelse
             (Character >= $A andalso Character =< $Z) ->
    {list_to_binary(lists:reverse([Character | Acc])), Rest};
take_directive(<<Character, Rest/binary>>, Acc) ->
    take_directive(Rest, [Character | Acc]).

format_directive(Directive, Argument) ->
    Size = byte_size(Directive),
    Verb = binary:at(Directive, Size - 1),
    Spec = binary:part(Directive, 0, Size - 1),
    {Left, Zero, Width, Precision} = parse_format_spec(Spec),
    Raw = case Verb of
        $d -> integer_to_binary(to_integer(Argument));
        $v -> display(Argument);
        $s -> display(Argument);
        $q -> iolist_to_binary(json:encode(display(Argument)));
        $f -> format_float(to_float(Argument), Precision);
        _ -> template_error(execution_failed)
    end,
    Truncated = case {Verb, Precision} of
        {$s, {some, Limit}} when byte_size(Raw) > Limit -> binary:part(Raw, 0, Limit);
        _ -> Raw
    end,
    pad_format(Truncated, Width, Left, Zero).

parse_format_spec(Spec) ->
    Left = binary:match(Spec, <<"-">>) =/= nomatch,
    Zero = binary:match(Spec, <<"0">>) =/= nomatch andalso not Left,
    case re:run(Spec, <<"([0-9]+)?(?:\\.([0-9]+))?">>, [{capture, [1, 2], binary}]) of
        {match, [WidthBinary, PrecisionBinary]} ->
            Width = optional_integer(WidthBinary, 0),
            Precision = case PrecisionBinary of
                <<>> -> none;
                _ -> {some, optional_integer(PrecisionBinary, 0)}
            end,
            {Left, Zero, Width, Precision};
        nomatch -> {Left, Zero, 0, none}
    end.

optional_integer(<<>>, Default) -> Default;
optional_integer(Value, _Default) -> binary_to_integer(Value).

format_float(Value, {some, Precision}) ->
    float_to_binary(Value, [{decimals, Precision}]);
format_float(Value, none) -> float_to_binary(Value, [{decimals, 6}]).

pad_format(Value, Width, _Left, _Zero) when byte_size(Value) >= Width -> Value;
pad_format(Value, Width, true, _Zero) ->
    <<Value/binary, (binary:copy(<<" ">>, Width - byte_size(Value)))/binary>>;
pad_format(<<"-", Rest/binary>>, Width, false, true) ->
    <<"-", (binary:copy(<<"0">>, Width - byte_size(Rest) - 1))/binary, Rest/binary>>;
pad_format(Value, Width, false, Zero) ->
    Character = case Zero of true -> <<"0">>; false -> <<" ">> end,
    <<(binary:copy(Character, Width - byte_size(Value)))/binary, Value/binary>>.
