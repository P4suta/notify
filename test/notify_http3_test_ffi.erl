%% SPDX-License-Identifier: Apache-2.0
-module(notify_http3_test_ffi).

-export([available_port/0, pem_certificate/1, https_get/2, https_post/3]).

-spec available_port() -> {ok, inet:port_number()} | {error, binary()}.
available_port() ->
    case gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]) of
        {ok, Socket} ->
            Result = case inet:sockname(Socket) of
                {ok, {_Address, Port}} -> {ok, Port};
                {error, Reason} -> {error, reason(Reason)}
            end,
            ok = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, reason(Reason)}
    end.

-spec pem_certificate(binary()) -> {ok, binary()} | {error, binary()}.
pem_certificate(Path) when is_binary(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Pem} -> find_certificate(public_key:pem_decode(Pem));
        {error, Reason} -> {error, reason(Reason)}
    end;
pem_certificate(_) ->
    {error, <<"invalid_path">>}.

-spec find_certificate(list()) ->
    {ok, binary()} | {error, binary()}.
find_certificate([{'Certificate', Der, not_encrypted} | _]) -> {ok, Der};
find_certificate([_ | Rest]) -> find_certificate(Rest);
find_certificate([]) -> {error, <<"certificate_not_found">>}.

-spec https_get(binary(), binary()) ->
    {ok, {integer(), [{binary(), binary()}], binary()}} | {error, binary()}.
https_get(Url, CaPath) when is_binary(Url), is_binary(CaPath) ->
    request(get, {binary_to_list(Url), []}, CaPath);
https_get(_, _) ->
    {error, <<"invalid_request">>}.

-spec https_post(binary(), binary(), binary()) ->
    {ok, {integer(), [{binary(), binary()}], binary()}} | {error, binary()}.
https_post(Url, CaPath, Body)
        when is_binary(Url), is_binary(CaPath), is_binary(Body) ->
    request(
        post,
        {binary_to_list(Url), [], "text/plain; charset=utf-8", Body},
        CaPath);
https_post(_, _, _) ->
    {error, <<"invalid_request">>}.

-spec request(atom(), tuple(), binary()) ->
    {ok, {integer(), [{binary(), binary()}], binary()}} | {error, binary()}.
request(Method, Request, CaPath) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    SslOptions = [
        {verify, verify_peer},
        {cacertfile, binary_to_list(CaPath)},
        {server_name_indication, "localhost"}
    ],
    case httpc:request(
            Method,
            Request,
            [{ssl, SslOptions}, {timeout, 5000}],
            [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, Headers, ResponseBody}} ->
            EncodedHeaders = [
                {string:lowercase(unicode:characters_to_binary(Name)),
                 unicode:characters_to_binary(Value)}
             || {Name, Value} <- Headers
            ],
            {ok, {Status, EncodedHeaders, ResponseBody}};
        {error, RequestReason} ->
            {error, reason(RequestReason)}
    end.

-spec reason(term()) -> binary().
reason(Value) when is_atom(Value) -> atom_to_binary(Value);
reason(_) -> <<"unavailable">>.
