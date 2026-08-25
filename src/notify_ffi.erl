-module(notify_ffi).

-include_lib("kernel/include/file.hrl").

-compile({no_auto_import,[atom_to_binary/1]}).

-export([argv/0, getenv/1, read_file/1, ensure_parent/1, unix_seconds/0,
         configure_tcp_clients/0, tcp_nodelay_enabled/0,
         monotonic_milliseconds/0, random_id/0,
         random_token_entropy/0, sha256_hex/1, sha256_hex_bytes/1,
         sha256_init/0, sha256_update/2, sha256_final_hex/1,
         file_sha256/1, path_exists/1, read_binary_file/1, write_binary_file/2,
         attachment_ensure_directory/1, attachment_put/5, attachment_head/2,
         attachment_upload_begin/2, attachment_upload_write/3,
         attachment_upload_finish/6, attachment_upload_abort/2,
         attachment_read_range/4,
         attachment_delete/2, attachment_list/1, attachment_page/3,
         attachment_cleanup_expired/2,
         attachment_health/1, attachment_blob_path/2,
         make_temporary_directory/0, public_asset/1,
         read_password/1, http_request/4, generate_vapid_keys/0, exit_failure/0,
         webpush_encrypt_with_values/6, webpush_encrypt/3,
         webpush_vapid_header/5, webpush_verify_vapid_header/2,
         webpush_send/9, valid_vapid_keys/2, relay_send/3,
         s3_put/5, s3_head/2, s3_get/3, s3_delete/2, s3_list/1, s3_page/3,
         s3_cleanup/2,
         s3_multipart_begin/3, s3_multipart_write/5,
         s3_multipart_complete/4, s3_multipart_abort/3,
         s3_promote_staging/5,
         s3_health/1, valid_ip_address/1, same_ip_address/2,
         sqlite_backup/2, sqlite_verify/1, sqlite_restore/2,
         sqlite_process_lock/1, sqlite_process_unlock/1,
         sqlite_windows_tasklist_has_pid/2,
         wait_for_shutdown_signal/0, linked_processes/0,
         shutdown_process/2, shutdown_processes/2,
         set_trap_exits/1, flush_exit_messages/0,
         init/1, handle_event/2, handle_info/2, handle_call/2,
         code_change/3, terminate/2, nil_value/0]).

argv() ->
    Arguments = case application:get_env(notify, native_argv) of
        {ok, NativeArguments} -> NativeArguments;
        undefined -> init:get_plain_arguments()
    end,
    [unicode:characters_to_binary(Arg) || Arg <- Arguments].

configure_tcp_clients() ->
    Existing = case application:get_env(kernel, inet_default_connect_options) of
        {ok, Options} when is_list(Options) -> Options;
        _ -> []
    end,
    Updated = lists:keystore(nodelay, 1, Existing, {nodelay, true}),
    ok = application:set_env(kernel, inet_default_connect_options, Updated),
    nil.

tcp_nodelay_enabled() ->
    case application:get_env(kernel, inet_default_connect_options) of
        {ok, Options} when is_list(Options) ->
            proplists:get_value(nodelay, Options, false) =:= true;
        _ -> false
    end.

nil_value() -> nil.

wait_for_shutdown_signal() ->
    case os:type() of
        {win32, _} ->
            %% Windows ERTS rejects os:set_signal/2. Keep OTP's default
            %% console/service termination handling and hold the CLI owner
            %% open until the VM is stopped by the process manager.
            wait_for_shutdown_message();
        _ ->
            case install_shutdown_handler() of
                ok -> wait_for_shutdown_message();
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("~tp", [Reason]))}
            end
    end.

wait_for_shutdown_message() ->
    receive
        notify_shutdown -> {ok, nil}
    end.

install_shutdown_handler() ->
    case whereis(erl_signal_server) of
        undefined -> {error, signal_server_unavailable};
        _ ->
            Existing = gen_event:which_handlers(erl_signal_server),
            Removed = case lists:member(erl_signal_handler, Existing) of
                true ->
                    gen_event:delete_handler(
                        erl_signal_server, erl_signal_handler, swap);
                false -> ok
            end,
            case Removed of
                {error, _} = Error -> Error;
                _ ->
                    case gen_event:add_handler(
                           erl_signal_server,
                           {?MODULE, notify_shutdown_handler}, self()) of
                        ok -> os:set_signal(sigterm, handle);
                        {error, _} = Error -> Error
                    end
            end
    end.

init(Owner) when is_pid(Owner) -> {ok, Owner}.

handle_event(sigterm, Owner) ->
    Owner ! notify_shutdown,
    {ok, Owner};
handle_event(sigusr1, Owner) ->
    erlang:halt("Received SIGUSR1"),
    {ok, Owner};
handle_event(sigquit, Owner) ->
    erlang:halt(),
    {ok, Owner};
handle_event(_Signal, Owner) ->
    {ok, Owner}.

handle_info(_Info, Owner) -> {ok, Owner}.
handle_call(_Request, Owner) -> {ok, ok, Owner}.
code_change(_OldVersion, Owner, _Extra) -> {ok, Owner}.
terminate(_Reason, _Owner) -> ok.

shutdown_process(Pid, Timeout)
  when is_pid(Pid), is_integer(Timeout), Timeout >= 0 ->
    unlink(Pid),
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> true
    after Timeout ->
        exit(Pid, kill),
        receive
            {'DOWN', Monitor, process, Pid, _Reason} -> false
        after 5000 -> false
        end
    end.

linked_processes() ->
    case process_info(self(), links) of
        {links, Links} -> [Pid || Pid <- Links, is_pid(Pid)];
        undefined -> []
    end.

set_trap_exits(Enabled) when is_boolean(Enabled) ->
    process_flag(trap_exit, Enabled).

flush_exit_messages() ->
    receive
        {'EXIT', _Pid, _Reason} -> flush_exit_messages()
    after 0 ->
        nil
    end.

shutdown_processes(Pids, Timeout)
  when is_list(Pids), is_integer(Timeout), Timeout >= 0 ->
    Live = lists:usort([Pid || Pid <- Pids,
                               is_pid(Pid),
                               is_process_alive(Pid)]),
    Monitors = lists:map(fun(Pid) ->
        unlink(Pid),
        {erlang:monitor(process, Pid), Pid}
    end, Live),
    lists:foreach(fun({_Monitor, Pid}) -> exit(Pid, shutdown) end, Monitors),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case await_processes(Monitors, Deadline) of
        [] -> true;
        Remaining ->
            lists:foreach(fun({_Monitor, Pid}) -> exit(Pid, kill) end,
                          Remaining),
            _ = await_processes(
                Remaining, erlang:monotonic_time(millisecond) + 5000),
            false
    end.

await_processes([], _Deadline) -> [];
await_processes(Monitors, Deadline) ->
    RemainingTime = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} ->
            await_processes(
                lists:delete({Monitor, Pid}, Monitors), Deadline)
    after RemainingTime ->
        Monitors
    end.

monotonic_milliseconds() -> erlang:monotonic_time(millisecond).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

valid_ip_address(Address) ->
    case inet:parse_address(binary_to_list(Address)) of
        {ok, _} -> true;
        {error, _} -> false
    end.

same_ip_address(First, Second) ->
    case {inet:parse_address(binary_to_list(First)),
          inet:parse_address(binary_to_list(Second))} of
        {{ok, Address}, {ok, Address}} -> true;
        _ -> false
    end.

sqlite_process_lock(Path) ->
    Absolute = filename:absname(binary_to_list(Path)),
    LockDirectory = Absolute ++ ".notify.lock",
    sqlite_process_lock_once(LockDirectory, true).

sqlite_process_lock_once(LockDirectory, MayRecover) ->
    case file:make_dir(LockDirectory) of
        ok -> sqlite_write_lock_owner(LockDirectory);
        {error, eexist} when MayRecover ->
            case sqlite_stale_lock(LockDirectory) of
                true ->
                    _ = file:delete(filename:join(LockDirectory, "owner.term")),
                    case file:del_dir(LockDirectory) of
                        ok -> sqlite_process_lock_once(LockDirectory, false);
                        _ -> {error, <<"already_running">>}
                    end;
                false -> {error, <<"already_running">>}
            end;
        {error, eexist} -> {error, <<"already_running">>};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format(
                "cannot create SQLite process lock: ~tp", [Reason]))}
    end.

sqlite_write_lock_owner(LockDirectory) ->
    OwnerFile = filename:join(LockDirectory, "owner.term"),
    {ok, Hostname} = inet:gethostname(),
    Token = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    Owner = #{hostname => Hostname, pid => os:getpid(), token => Token},
    case file:write_file(OwnerFile, term_to_binary(Owner), [exclusive, sync]) of
        ok ->
            Parent = self(),
            Manager = spawn(fun() ->
                sqlite_lock_manager(Parent, OwnerFile, LockDirectory, Token)
            end),
            {ok, {sqlite_process_lock, Manager, Token}};
        {error, Reason} ->
            _ = file:del_dir(LockDirectory),
            {error, iolist_to_binary(io_lib:format(
                "cannot write SQLite process lock: ~tp", [Reason]))}
    end.

sqlite_lock_manager(Parent, OwnerFile, LockDirectory, Token) ->
    Monitor = erlang:monitor(process, Parent),
    receive
        {unlock, Token, Sender, Reference} ->
            erlang:demonitor(Monitor, [flush]),
            sqlite_release_lock(OwnerFile, LockDirectory, Token),
            Sender ! {Reference, ok};
        {'DOWN', Monitor, process, Parent, _} ->
            sqlite_release_lock(OwnerFile, LockDirectory, Token)
    end.

sqlite_process_unlock(nil) -> nil;
sqlite_process_unlock({sqlite_process_lock, Manager, Token}) ->
    Reference = make_ref(),
    Manager ! {unlock, Token, self(), Reference},
    receive
        {Reference, ok} -> nil
    after 5000 -> nil
    end;
sqlite_process_unlock(_) -> nil.

sqlite_release_lock(OwnerFile, LockDirectory, Token) ->
    case sqlite_read_lock_owner(OwnerFile) of
        {ok, #{token := Token}} ->
            _ = file:delete(OwnerFile),
            _ = file:del_dir(LockDirectory),
            ok;
        _ -> ok
    end.

sqlite_stale_lock(LockDirectory) ->
    OwnerFile = filename:join(LockDirectory, "owner.term"),
    case sqlite_read_lock_owner(OwnerFile) of
        {ok, #{hostname := Hostname, pid := Pid}}
          when is_list(Hostname), is_list(Pid) ->
            not sqlite_owner_alive(Hostname, Pid);
        _ -> false
    end.

sqlite_read_lock_owner(OwnerFile) ->
    case file:read_file(OwnerFile) of
        {ok, Bytes} ->
            try {ok, binary_to_term(Bytes, [safe])}
            catch _:_ -> error
            end;
        _ -> error
    end.

sqlite_owner_alive(Hostname, Pid) ->
    {ok, CurrentHostname} = inet:gethostname(),
    case Hostname =:= CurrentHostname of
        false -> true;
        true ->
            case Pid =:= os:getpid() of
                true -> true;
                false -> sqlite_local_pid_alive(Pid)
            end
    end.

sqlite_local_pid_alive(Pid) ->
    case Pid =/= [] andalso lists:all(fun(Character) ->
        Character >= $0 andalso Character =< $9
    end, Pid) of
        false -> true;
        true ->
            case os:type() of
                {unix, _} -> sqlite_unix_pid_alive(Pid);
                {win32, _} -> sqlite_windows_pid_alive(Pid);
                _ -> true
            end
    end.

sqlite_unix_pid_alive(Pid) ->
    case os:find_executable("kill") of
        false -> true;
        Kill ->
            Port = open_port(
                {spawn_executable, Kill},
                [binary, exit_status, use_stdio, stderr_to_stdout,
                 {args, ["-0", Pid]}]),
            sqlite_wait_for_pid_probe(Port)
    end.

sqlite_wait_for_pid_probe(Port) ->
    receive
        {Port, {data, _}} -> sqlite_wait_for_pid_probe(Port);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, _}} -> false
    after 2000 ->
        port_close(Port),
        true
    end.

sqlite_windows_pid_alive(Pid) ->
    case os:find_executable("tasklist") of
        false -> true;
        Tasklist ->
            try
                Port = open_port(
                    {spawn_executable, Tasklist},
                    [binary, exit_status, use_stdio, stderr_to_stdout,
                     {args, ["/FI", "PID eq " ++ Pid,
                             "/FO", "CSV", "/NH"]}]),
                sqlite_wait_for_windows_pid_probe(
                    Port, unicode:characters_to_binary(Pid), <<>>)
            catch
                _:_ -> true
            end
    end.

sqlite_wait_for_windows_pid_probe(Port, Pid, Output) ->
    receive
        {Port, {data, Data}}
          when byte_size(Output) + byte_size(Data) =< 65536 ->
            sqlite_wait_for_windows_pid_probe(
                Port, Pid, <<Output/binary, Data/binary>>);
        {Port, {data, _}} ->
            port_close(Port),
            true;
        {Port, {exit_status, 0}} when byte_size(Output) > 0 ->
            sqlite_windows_tasklist_has_pid(Output, Pid);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, _}} -> true;
        {Port, closed} -> true
    after 2000 ->
        port_close(Port),
        true
    end.

sqlite_windows_tasklist_has_pid(Output, Pid)
  when is_binary(Output), is_binary(Pid) ->
    Needle = iolist_to_binary([<<34, 44, 34>>, Pid, <<34, 44, 34>>]),
    binary:match(Output, Needle) =/= nomatch;
sqlite_windows_tasklist_has_pid(_, _) -> false.

sqlite_backup(Source, Destination) ->
    case sqlite_paths(Source, Destination) of
        {error, Reason} -> {error, Reason};
        {ok, SourcePath, DestinationPath} ->
            case filelib:is_regular(SourcePath) of
                false -> {error, <<"source_not_found">>};
                true -> sqlite_backup_to_new_path(SourcePath, DestinationPath)
            end
    end.

sqlite_verify(Path) ->
    sqlite_verify_file(binary_to_list(Path)).

sqlite_restore(Snapshot, Destination) ->
    case sqlite_paths(Snapshot, Destination) of
        {error, Reason} -> {error, Reason};
        {ok, SnapshotPath, DestinationPath} ->
            case sqlite_verify_file(SnapshotPath) of
                {error, Reason} -> {error, Reason};
                {ok, nil} -> sqlite_copy_to_new_path(SnapshotPath, DestinationPath)
            end
    end.

sqlite_paths(Source, Destination) ->
    SourcePath = filename:absname(binary_to_list(Source)),
    DestinationPath = filename:absname(binary_to_list(Destination)),
    case SourcePath =:= DestinationPath of
        true -> {error, <<"same_path">>};
        false -> {ok, SourcePath, DestinationPath}
    end.

sqlite_backup_to_new_path(Source, Destination) ->
    case filelib:is_file(Destination) of
        true -> {error, <<"destination_exists">>};
        false ->
            case filelib:ensure_dir(Destination) of
                {error, Reason} -> {error, sqlite_reason(Reason)};
                ok ->
                    Temporary = sqlite_temporary_path(Destination),
                    Result = case sqlite_online_backup(Source, Temporary) of
                        ok ->
                            case sqlite_verify_file(Temporary) of
                                {ok, nil} -> sqlite_promote(Temporary, Destination);
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} -> {error, Reason}
                    end,
                    case Result of
                        {ok, nil} -> Result;
                        {error, _} ->
                            _ = file:delete(Temporary),
                            Result
                    end
            end
    end.

sqlite_copy_to_new_path(Source, Destination) ->
    case filelib:is_file(Destination) of
        true -> {error, <<"destination_exists">>};
        false ->
            case filelib:ensure_dir(Destination) of
                {error, Reason} -> {error, sqlite_reason(Reason)};
                ok ->
                    Temporary = sqlite_temporary_path(Destination),
                    Result = case file:copy(Source, Temporary) of
                        {ok, _} ->
                            case sqlite_verify_file(Temporary) of
                                {ok, nil} -> sqlite_promote(Temporary, Destination);
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} -> {error, sqlite_reason(Reason)}
                    end,
                    case Result of
                        {ok, nil} -> Result;
                        {error, _} ->
                            _ = file:delete(Temporary),
                            Result
                    end
            end
    end.

sqlite_online_backup(SourcePath, DestinationPath) ->
    case esqlite3:open(SourcePath) of
        {error, Reason} -> {error, sqlite_reason(Reason)};
        {ok, Source} ->
            Result = case esqlite3:open(DestinationPath) of
                {error, Reason} -> {error, sqlite_reason(Reason)};
                {ok, Destination} ->
                    BackupResult = case esqlite3:backup_init(
                        Destination, "main", Source, "main") of
                        {error, Reason} -> {error, sqlite_reason(Reason)};
                        {ok, Backup} ->
                            StepResult = sqlite_backup_steps(Backup, 100),
                            FinishResult = esqlite3:backup_finish(Backup),
                            case {StepResult, FinishResult} of
                                {ok, ok} -> ok;
                                {{error, Reason}, _} -> {error, Reason};
                                {_, FinishError} ->
                                    {error, sqlite_reason(FinishError)}
                            end
                    end,
                    _ = esqlite3:close(Destination),
                    BackupResult
            end,
            _ = esqlite3:close(Source),
            Result
    end.

sqlite_backup_steps(Backup, Retries) ->
    case esqlite3:backup_step(Backup, 128) of
        '$done' -> ok;
        done -> ok;
        ok -> sqlite_backup_steps(Backup, Retries);
        {error, Code} when (Code =:= 5 orelse Code =:= 6), Retries > 0 ->
            timer:sleep(10),
            sqlite_backup_steps(Backup, Retries - 1);
        {error, Reason} -> {error, sqlite_reason(Reason)};
        Other -> {error, sqlite_reason(Other)}
    end.

sqlite_verify_file(Path) ->
    case filelib:is_regular(Path) of
        false -> {error, <<"source_not_found">>};
        true ->
            case esqlite3:open(Path) of
                {error, _} -> {error, <<"not_notify_database">>};
                {ok, Connection} ->
                    Result = case esqlite3:q(
                        Connection, <<"PRAGMA quick_check">>, []) of
                        [[<<"ok">>]] -> sqlite_verify_schema(Connection);
                        _ -> {error, <<"not_notify_database">>}
                    end,
                    _ = esqlite3:close(Connection),
                    Result
            end
    end.

sqlite_verify_schema(Connection) ->
    Sql = <<"SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('messages', 'schema_migrations')">>,
    case esqlite3:q(Connection, Sql, []) of
        [[2]] -> {ok, nil};
        _ -> {error, <<"not_notify_database">>}
    end.

sqlite_promote(Temporary, Destination) ->
    case file:rename(Temporary, Destination) of
        ok -> {ok, nil};
        {error, Reason} -> {error, sqlite_reason(Reason)}
    end.

sqlite_temporary_path(Destination) ->
    Suffix = binary_to_list(binary:encode_hex(
        crypto:strong_rand_bytes(8), lowercase)),
    Destination ++ ".tmp-" ++ Suffix.

sqlite_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
sqlite_reason(Reason) when is_integer(Reason) -> integer_to_binary(Reason);
sqlite_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Reason])).

exit_failure() ->
    erlang:halt(1).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, nil}
    end.

read_password(Prompt) ->
    case io:get_password(binary_to_list(Prompt)) of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Password when is_list(Password) ->
            {ok, unicode:characters_to_binary(string:trim(Password))}
    end.

http_request(Method, Url, Headers, Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    RequestHeaders = [{binary_to_list(Name), binary_to_list(Value)} || {Name, Value} <- Headers],
    Request = case Method of
        <<"GET">> -> {binary_to_list(Url), RequestHeaders};
        _ -> {binary_to_list(Url), RequestHeaders, "text/plain; charset=utf-8", Body}
    end,
    MethodAtom = case Method of <<"GET">> -> get; <<"PUT">> -> put; _ -> post end,
    case httpc:request(MethodAtom, Request, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, ResponseBody}} -> {ok, {Status, ResponseBody}};
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~tp", [Reason]))}
    end.

generate_vapid_keys() ->
    try crypto:generate_key(ecdh, prime256v1) of
        {Public, Private} -> {ok, {base64url(Public), base64url(Private)}}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~tp:~tp", [Class, Reason]))}
    end.

valid_vapid_keys(PublicEncoded, PrivateEncoded) ->
    try
        Public = base64url_decode(PublicEncoded),
        Private = base64url_decode(PrivateEncoded),
        {DerivedPublic, DerivedPrivate} =
            crypto:generate_key(ecdh, prime256v1, Private),
        byte_size(Public) =:= 65 andalso byte_size(Private) =:= 32
            andalso Public =:= DerivedPublic andalso Private =:= DerivedPrivate
    catch
        _:_ -> false
    end.

webpush_encrypt(Plaintext, AuthEncoded, ReceiverPublicEncoded) ->
    try crypto:generate_key(ecdh, prime256v1) of
        {SenderPublic, SenderPrivate} ->
            Salt = crypto:strong_rand_bytes(16),
            webpush_encrypt_values(
                Plaintext,
                base64url_decode(AuthEncoded),
                base64url_decode(ReceiverPublicEncoded),
                SenderPublic,
                SenderPrivate,
                Salt)
    catch
        Class:Reason -> webpush_crypto_error(Class, Reason)
    end.

webpush_encrypt_with_values(Plaintext, AuthEncoded, ReceiverPublicEncoded,
                            SenderPublicEncoded, SenderPrivateEncoded,
                            SaltEncoded) ->
    try
        webpush_encrypt_values(
            Plaintext,
            base64url_decode(AuthEncoded),
            base64url_decode(ReceiverPublicEncoded),
            base64url_decode(SenderPublicEncoded),
            base64url_decode(SenderPrivateEncoded),
            base64url_decode(SaltEncoded))
    catch
        Class:Reason -> webpush_crypto_error(Class, Reason)
    end.

webpush_encrypt_values(Plaintext, AuthSecret, ReceiverPublic, SenderPublic,
                       SenderPrivate, Salt)
  when is_binary(Plaintext), byte_size(AuthSecret) =:= 16,
       byte_size(ReceiverPublic) =:= 65, byte_size(SenderPublic) =:= 65,
       byte_size(SenderPrivate) =:= 32, byte_size(Salt) =:= 16 ->
    SharedSecret = crypto:compute_key(
        ecdh, ReceiverPublic, SenderPrivate, prime256v1),
    KeyInfo = <<"WebPush: info", 0, ReceiverPublic/binary, SenderPublic/binary>>,
    KeyPrk = crypto:mac(hmac, sha256, AuthSecret, SharedSecret),
    InputKeyMaterial = webpush_hkdf_expand(KeyPrk, KeyInfo, 32),
    Prk = crypto:mac(hmac, sha256, Salt, InputKeyMaterial),
    ContentKey = webpush_hkdf_expand(
        Prk, <<"Content-Encoding: aes128gcm", 0>>, 16),
    Nonce = webpush_hkdf_expand(
        Prk, <<"Content-Encoding: nonce", 0>>, 12),
    Record = <<Plaintext/binary, 2>>,
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_128_gcm, ContentKey, Nonce, Record, <<>>, 16, true),
    {ok, <<Salt/binary, 4096:32/big-unsigned-integer, 65:8,
           SenderPublic/binary, Ciphertext/binary, Tag/binary>>};
webpush_encrypt_values(_, _, _, _, _, _) ->
    {error, <<"invalid Web Push encryption key material">>}.

webpush_hkdf_expand(Prk, Info, Length) ->
    Block = crypto:mac(hmac, sha256, Prk, <<Info/binary, 1>>),
    binary:part(Block, 0, Length).

webpush_vapid_header(Endpoint, Subscriber, PublicEncoded, PrivateEncoded, Now) ->
    try
        Public = base64url_decode(PublicEncoded),
        Private = base64url_decode(PrivateEncoded),
        true = byte_size(Public) =:= 65,
        true = byte_size(Private) =:= 32,
        Audience = webpush_origin(Endpoint),
        Subject = webpush_subject(Subscriber),
        EncodedHeader = base64url(<<"{\"typ\":\"JWT\",\"alg\":\"ES256\"}">>),
        Payload = iolist_to_binary([
            <<"{\"aud\":\"">>, json_escape(Audience),
            <<"\",\"exp\":" >>, integer_to_binary(Now + 43200),
            <<",\"sub\":\"">>, json_escape(Subject), <<"\"}">>
        ]),
        EncodedPayload = base64url(Payload),
        SigningInput = <<EncodedHeader/binary, ".", EncodedPayload/binary>>,
        DerSignature = crypto:sign(
            ecdsa, sha256, SigningInput, [Private, prime256v1]),
        Signature = base64url(ecdsa_der_to_raw(DerSignature)),
        Token = <<SigningInput/binary, ".", Signature/binary>>,
        {ok, <<"vapid t=", Token/binary, ", k=", PublicEncoded/binary>>}
    catch
        Class:Reason -> webpush_crypto_error(Class, Reason)
    end.

webpush_verify_vapid_header(Header, PublicEncoded) ->
    try
        <<"vapid t=", Credentials/binary>> = Header,
        [Token, HeaderPublic] = binary:split(Credentials, <<", k=">>),
        true = HeaderPublic =:= PublicEncoded,
        [EncodedHeader, EncodedPayload, EncodedSignature] =
            binary:split(Token, <<".">>, [global]),
        SigningInput = <<EncodedHeader/binary, ".", EncodedPayload/binary>>,
        RawSignature = base64url_decode(EncodedSignature),
        Public = base64url_decode(PublicEncoded),
        crypto:verify(ecdsa, sha256, SigningInput,
            ecdsa_raw_to_der(RawSignature), [Public, prime256v1])
    catch
        _:_ -> false
    end.

webpush_send(Endpoint, AuthEncoded, ReceiverPublicEncoded, VapidPublic,
             VapidPrivate, Subscriber, Plaintext, TtlSeconds, Now) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    case webpush_encrypt(Plaintext, AuthEncoded, ReceiverPublicEncoded) of
        {error, Reason} -> {error, Reason};
        {ok, Encrypted} ->
            case webpush_vapid_header(
                    Endpoint, Subscriber, VapidPublic, VapidPrivate, Now) of
                {error, Reason} -> {error, Reason};
                {ok, Authorization} ->
                    Headers = [
                        {"Authorization", binary_to_list(Authorization)},
                        {"Content-Encoding", "aes128gcm"},
                        {"TTL", integer_to_list(erlang:max(0, TtlSeconds))},
                        {"Urgency", "high"}
                    ],
                    Request = {binary_to_list(Endpoint), Headers,
                               "application/octet-stream", Encrypted},
                    HttpOptions = webpush_http_options(Endpoint),
                    case httpc:request(post, Request, HttpOptions,
                                       [{body_format, binary}]) of
                        {ok, {{_, Status, _}, _, _}} -> {ok, Status};
                        {error, Reason} ->
                            {error, unicode:characters_to_binary(
                                io_lib:format("webpush transport error: ~tp", [Reason]))}
                    end
            end
    end.

relay_send(Endpoint, Token, PollId) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Authorization = case Token of
        <<>> -> [];
        _ -> [{"Authorization", binary_to_list(<<"Bearer ", Token/binary>>)}]
    end,
    Headers = [
        {"User-Agent", "notify/0.1.0"},
        {"X-Poll-ID", binary_to_list(PollId)}
        | Authorization
    ],
    Request = {binary_to_list(Endpoint), Headers, "text/plain", <<>>},
    case httpc:request(post, Request, webpush_http_options(Endpoint),
                       [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, _}} -> {ok, Status};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                io_lib:format("mobile relay transport error: ~tp", [Reason]))}
    end.

webpush_http_options(Endpoint) ->
    Parsed = uri_string:parse(binary_to_list(Endpoint)),
    case maps:get(scheme, Parsed, "") of
        "https" ->
            Host = maps:get(host, Parsed),
            MatchFun = public_key:pkix_verify_hostname_match_fun(https),
            [{timeout, 30000}, {connect_timeout, 10000},
             {ssl, [{verify, verify_peer},
                    {cacerts, public_key:cacerts_get()},
                    {server_name_indication, Host},
                    {customize_hostname_check, [{match_fun, MatchFun}]}]}];
        _ -> [{timeout, 30000}, {connect_timeout, 10000}]
    end.

webpush_origin(Endpoint) ->
    Parsed = uri_string:parse(binary_to_list(Endpoint)),
    Scheme = unicode:characters_to_binary(maps:get(scheme, Parsed)),
    Host = unicode:characters_to_binary(maps:get(host, Parsed)),
    Port = maps:get(port, Parsed, undefined),
    case {Scheme, Port} of
        {<<"https">>, undefined} -> <<"https://", Host/binary>>;
        {<<"https">>, 443} -> <<"https://", Host/binary>>;
        {<<"http">>, undefined} -> <<"http://", Host/binary>>;
        {<<"http">>, 80} -> <<"http://", Host/binary>>;
        _ -> <<Scheme/binary, "://", Host/binary, ":",
               (integer_to_binary(Port))/binary>>
    end.

webpush_subject(<<"mailto:", _/binary>> = Subscriber) -> Subscriber;
webpush_subject(<<"https:", _/binary>> = Subscriber) -> Subscriber;
webpush_subject(Subscriber) -> <<"mailto:", Subscriber/binary>>.

json_escape(Value) ->
    EscapedSlash = binary:replace(Value, <<"\\">>, <<"\\\\">>, [global]),
    EscapedQuote = binary:replace(EscapedSlash, <<"\"">>, <<"\\\"">>, [global]),
    EscapedNewline = binary:replace(EscapedQuote, <<"\n">>, <<"\\n">>, [global]),
    EscapedReturn = binary:replace(EscapedNewline, <<"\r">>, <<"\\r">>, [global]),
    binary:replace(EscapedReturn, <<"\t">>, <<"\\t">>, [global]).

ecdsa_der_to_raw(<<48, Length, Rest/binary>>) when Length =:= byte_size(Rest) ->
    {R, AfterR} = der_read_integer(Rest),
    {S, <<>>} = der_read_integer(AfterR),
    <<(ecdsa_integer_32(R))/binary, (ecdsa_integer_32(S))/binary>>.

der_read_integer(<<2, Length, Value:Length/binary, Rest/binary>>) ->
    {Value, Rest}.

ecdsa_integer_32(<<0, Rest/binary>>) when byte_size(Rest) >= 32 ->
    ecdsa_integer_32(Rest);
ecdsa_integer_32(Value) when byte_size(Value) =< 32 ->
    Padding = 32 - byte_size(Value),
    <<0:(Padding * 8), Value/binary>>.

ecdsa_raw_to_der(<<R:32/binary, S:32/binary>>) ->
    EncodedR = der_encode_integer(R),
    EncodedS = der_encode_integer(S),
    Body = <<EncodedR/binary, EncodedS/binary>>,
    <<48, (byte_size(Body)), Body/binary>>.

der_encode_integer(Value) ->
    Trimmed = der_trim_integer(Value),
    Positive = case Trimmed of
        <<First, _/binary>> when First >= 128 -> <<0, Trimmed/binary>>;
        _ -> Trimmed
    end,
    <<2, (byte_size(Positive)), Positive/binary>>.

der_trim_integer(<<0, Rest/binary>>) when byte_size(Rest) > 1 ->
    der_trim_integer(Rest);
der_trim_integer(Value) -> Value.

base64url_decode(Value) ->
    WithPlus = binary:replace(Value, <<"-">>, <<"+">>, [global]),
    WithSlash = binary:replace(WithPlus, <<"_">>, <<"/">>, [global]),
    Padding = case byte_size(WithSlash) rem 4 of
        0 -> <<>>;
        2 -> <<"==">>;
        3 -> <<"=">>;
        _ -> error(invalid_base64url)
    end,
    base64:decode(<<WithSlash/binary, Padding/binary>>).

webpush_crypto_error(Class, Reason) ->
    {error, unicode:characters_to_binary(
        io_lib:format("webpush crypto error: ~tp:~tp", [Class, Reason]))}.

base64url(Value) ->
    Encoded = base64:encode(Value),
    NoPadding = binary:replace(Encoded, <<"=">>, <<>>, [global]),
    WithDash = binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
    binary:replace(WithDash, <<"/">>, <<"_">>, [global]).

public_asset(Name) ->
    case binary:match(Name, [<<"/">>, <<"\\">>, <<"..">>]) of
        nomatch ->
            PrivCandidates = case code:priv_dir(notify) of
                {error, _} -> [];
                PrivDir -> [filename:join([PrivDir, "public", binary_to_list(Name)])]
            end,
            Candidates = PrivCandidates ++ [
                filename:join(["priv", "public", binary_to_list(Name)]),
                filename:join(["..", "..", "..", "..", "priv", "public", binary_to_list(Name)])
            ],
            read_first_asset(Candidates);
        _ -> {error, nil}
    end.

read_first_asset([]) -> {error, nil};
read_first_asset([Path | Rest]) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> read_first_asset(Rest)
    end.

ensure_parent(Path) ->
    case filelib:ensure_dir(binary_to_list(Path)) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

unix_seconds() ->
    erlang:system_time(second).

random_id() ->
    random_alphanumeric(12).

random_token_entropy() ->
    random_alphanumeric(29).

random_alphanumeric(Length) ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789">>,
    random_alphanumeric(Length, Alphabet, []).

random_alphanumeric(0, _Alphabet, Acc) ->
    list_to_binary(lists:reverse(Acc));
random_alphanumeric(Remaining, Alphabet, Acc) ->
    %% 248 is the largest multiple of 62 below 256. Rejecting bytes outside
    %% that range avoids the modulo bias that would otherwise make the first
    %% eight alphabet characters more likely.
    Bytes = crypto:strong_rand_bytes(Remaining + 8),
    {NextRemaining, NextAcc} = lists:foldl(
        fun(_Byte, {0, Current}) -> {0, Current};
           (Byte, {Needed, Current}) when Byte < 248 ->
                {Needed - 1, [binary:at(Alphabet, Byte rem 62) | Current]};
           (_Byte, State) -> State
        end,
        {Remaining, Acc},
        binary_to_list(Bytes)),
    random_alphanumeric(NextRemaining, Alphabet, NextAcc).

sha256_hex(Value) ->
    binary:encode_hex(crypto:hash(sha256, Value), lowercase).

sha256_hex_bytes(Value) ->
    binary:encode_hex(crypto:hash(sha256, Value), lowercase).

sha256_init() -> crypto:hash_init(sha256).

sha256_update(Context, Chunk) -> crypto:hash_update(Context, Chunk).

sha256_final_hex(Context) ->
    binary:encode_hex(crypto:hash_final(Context), lowercase).

file_sha256(Path) ->
    case file:open(binary_to_list(Path), [read, raw, binary]) of
        {ok, Device} ->
            Context = crypto:hash_init(sha256),
            Result = file_sha256_chunks(Device, Context),
            _ = file:close(Device),
            Result;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

file_sha256_chunks(Device, Context) ->
    case file:read(Device, 1024 * 1024) of
        {ok, Data} ->
            file_sha256_chunks(Device, crypto:hash_update(Context, Data));
        eof ->
            {ok, binary:encode_hex(crypto:hash_final(Context), lowercase)};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

path_exists(Path) -> filelib:is_file(binary_to_list(Path)).

read_binary_file(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Data} -> {ok, Data};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

write_binary_file(Path, Data) ->
    case file:write_file(binary_to_list(Path), Data, [binary, exclusive, sync]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_ensure_directory(Directory) ->
    Probe = filename:join(Directory, <<"probe">>),
    case filelib:ensure_dir(Probe) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_put(Directory, Key, Data, Expires, MaxTotal) ->
    Target = attachment_path(Directory, Key, <<".blob">>),
    Meta = attachment_path(Directory, Key, <<".expires">>),
    case filelib:is_regular(Target) of
        true ->
            update_attachment_expiry(Meta, Expires);
        false ->
            case attachment_total_size(Directory) + byte_size(Data) > MaxTotal of
                true -> {error, <<"quota">>};
                false -> atomic_attachment_write(Target, Meta, Data, Expires)
            end
    end.

attachment_upload_begin(Directory, Id) ->
    case attachment_upload_path(Directory, Id) of
        {error, Reason} -> {error, Reason};
        {ok, Path} ->
            case file:write_file(Path, <<>>, [binary, exclusive, sync]) of
                ok -> {ok, nil};
                {error, eexist} -> {error, <<"exists">>};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end
    end.

attachment_upload_write(Directory, Id, Chunk) ->
    case attachment_upload_path(Directory, Id) of
        {error, Reason} -> {error, Reason};
        {ok, Path} ->
            case file:write_file(Path, Chunk, [binary, append, sync]) of
                ok -> {ok, nil};
                {error, enoent} -> {error, <<"not_found">>};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end
    end.

attachment_upload_finish(Directory, Id, Key, Expires, MaxTotal, ExpectedSize) ->
    case attachment_upload_path(Directory, Id) of
        {error, Reason} -> {error, Reason};
        {ok, Staging} ->
            Target = attachment_path(Directory, Key, <<".blob">>),
            Meta = attachment_path(Directory, Key, <<".expires">>),
            case attachment_file_size(Staging) of
                {error, Reason} -> {error, Reason};
                {ok, ActualSize} when ActualSize =/= ExpectedSize ->
                    {error, <<"upload_size_mismatch">>};
                {ok, ActualSize} ->
                    attachment_promote_staging(
                        Directory, Staging, Target, Meta, ActualSize,
                        Expires, MaxTotal)
            end
    end.

attachment_promote_staging(Directory, Staging, Target, Meta, Size,
                           Expires, MaxTotal) ->
    case filelib:is_regular(Target) of
        true ->
            _ = file:delete(Staging),
            case update_attachment_expiry(Meta, Expires) of
                {ok, nil} -> attachment_head_from_paths(Target, Meta);
                Error -> Error
            end;
        false ->
            case attachment_total_size(Directory) + Size > MaxTotal of
                true -> {error, <<"quota">>};
                false ->
                    case file:rename(Staging, Target) of
                        ok ->
                            case update_attachment_expiry(Meta, Expires) of
                                {ok, nil} -> {ok, {Size, Expires}};
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} -> {error, atom_to_binary(Reason)}
                    end
            end
    end.

attachment_upload_abort(Directory, Id) ->
    case attachment_upload_path(Directory, Id) of
        {error, Reason} -> {error, Reason};
        {ok, Path} ->
            case file:delete(Path) of
                ok -> {ok, nil};
                {error, enoent} -> {error, <<"not_found">>};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end
    end.

attachment_upload_path(Directory, Id) when is_binary(Id), byte_size(Id) =:= 12 ->
    case re:run(Id, <<"^[A-Za-z0-9]{12}$">>, [{capture, none}]) of
        match -> {ok, filename:join(Directory, <<".upload-", Id/binary, ".tmp">>)};
        nomatch -> {error, <<"not_found">>}
    end;
attachment_upload_path(_Directory, _Id) -> {error, <<"not_found">>}.

attachment_file_size(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Io} ->
            Result = file:position(Io, eof),
            _ = file:close(Io),
            case Result of
                {ok, Size} -> {ok, Size};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end;
        {error, enoent} -> {error, <<"not_found">>};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_head_from_paths(Target, Meta) ->
    case {attachment_file_size(Target), file:read_file(Meta)} of
        {{ok, Size}, {ok, EncodedExpiry}} ->
            try {ok, {Size, binary_to_integer(EncodedExpiry)}}
            catch _:_ -> {error, <<"invalid_metadata">>} end;
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, enoent}} -> {error, <<"not_found">>};
        {_, {error, Reason}} -> {error, atom_to_binary(Reason)}
    end.

atomic_attachment_write(Target, Meta, Data, Expires) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Temp = <<Target/binary, ".", Suffix/binary, ".tmp">>,
    case file:write_file(Temp, Data, [binary, exclusive, sync]) of
        ok ->
            case file:rename(Temp, Target) of
                ok -> update_attachment_expiry(Meta, Expires);
                {error, Reason} ->
                    _ = file:delete(Temp),
                    {error, atom_to_binary(Reason)}
            end;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

update_attachment_expiry(Meta, Expires) ->
    Previous = case file:read_file(Meta) of
        {ok, Encoded} ->
            try binary_to_integer(Encoded) catch _:_ -> 0 end;
        _ -> 0
    end,
    Latest = erlang:max(Previous, Expires),
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Temp = <<Meta/binary, ".", Suffix/binary, ".tmp">>,
    case file:write_file(
            Temp, integer_to_binary(Latest), [binary, exclusive, sync]) of
        ok ->
            case file:rename(Temp, Meta) of
                ok -> {ok, nil};
                {error, Reason} ->
                    _ = file:delete(Temp),
                    {error, atom_to_binary(Reason)}
            end;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_head(Directory, Key) ->
    Target = attachment_path(Directory, Key, <<".blob">>),
    Meta = attachment_path(Directory, Key, <<".expires">>),
    case file:open(Target, [read, binary, raw]) of
        {ok, Io} ->
            SizeResult = file:position(Io, eof),
            _ = file:close(Io),
            case {SizeResult, file:read_file(Meta)} of
                {{ok, Size}, {ok, EncodedExpiry}} ->
                    try {ok, {Size, binary_to_integer(EncodedExpiry)}}
                    catch _:_ -> {error, <<"invalid_metadata">>} end;
                {_, {error, enoent}} -> {error, <<"not_found">>};
                {{error, Reason}, _} -> {error, atom_to_binary(Reason)};
                {_, {error, Reason}} -> {error, atom_to_binary(Reason)}
            end;
        {error, enoent} -> {error, <<"not_found">>};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_read_range(Directory, Key, Start, End)
  when is_integer(Start), is_integer(End), Start >= 0, End >= Start ->
    Path = attachment_path(Directory, Key, <<".blob">>),
    case file:open(Path, [read, binary, raw]) of
        {ok, Io} ->
            Result = file:pread(Io, Start, End - Start + 1),
            _ = file:close(Io),
            case Result of
                {ok, Data} when byte_size(Data) =:= End - Start + 1 ->
                    {ok, Data};
                {ok, _} -> {error, <<"invalid_range">>};
                eof -> {error, <<"invalid_range">>};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end;
        {error, enoent} -> {error, <<"not_found">>};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end;
attachment_read_range(_Directory, _Key, _Start, _End) ->
    {error, <<"invalid_range">>}.

attachment_list(Directory) ->
    case file:list_dir(Directory) of
        {ok, Names} -> attachment_list_names(Directory, lists:sort(Names), []);
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_list_names(_Directory, [], Acc) -> {ok, lists:reverse(Acc)};
attachment_list_names(Directory, [Name | Rest], Acc) ->
    NameBinary = unicode:characters_to_binary(Name),
    case filename:extension(NameBinary) of
        <<".blob">> ->
            Key = filename:rootname(NameBinary, <<".blob">>),
            case attachment_head(Directory, Key) of
                {ok, {Size, Expires}} ->
                    attachment_list_names(
                        Directory, Rest, [{Key, Size, Expires} | Acc]);
                {error, <<"not_found">>} ->
                    attachment_list_names(Directory, Rest, Acc);
                {error, Reason} -> {error, Reason}
            end;
        _ -> attachment_list_names(Directory, Rest, Acc)
    end.

attachment_page(Directory, After, Limit)
  when is_integer(Limit), Limit > 0 ->
    case file:list_dir(Directory) of
        {ok, Names} ->
            Keys = lists:sort([
                filename:rootname(NameBinary, <<".blob">>)
                || Name <- Names,
                   NameBinary <- [unicode:characters_to_binary(Name)],
                   filename:extension(NameBinary) =:= <<".blob">>
            ]),
            Remaining = case After of
                none -> Keys;
                {some, Cursor} -> lists:dropwhile(
                    fun(Key) -> Key =< Cursor end, Keys)
            end,
            attachment_page_keys(
                Directory, lists:sublist(Remaining, Limit), []);
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end;
attachment_page(_Directory, _After, _Limit) ->
    {error, <<"invalid_page">>}.

attachment_page_keys(_Directory, [], Acc) -> {ok, lists:reverse(Acc)};
attachment_page_keys(Directory, [Key | Rest], Acc) ->
    case attachment_head(Directory, Key) of
        {ok, {Size, Expires}} -> attachment_page_keys(
            Directory, Rest, [{Key, Size, Expires} | Acc]);
        {error, <<"not_found">>} -> {error, <<"attachment_page_changed">>};
        {error, Reason} -> {error, Reason}
    end.

attachment_delete(Directory, Key) ->
    delete_if_present(attachment_path(Directory, Key, <<".blob">>)),
    delete_if_present(attachment_path(Directory, Key, <<".expires">>)).

delete_if_present(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_cleanup_expired(Directory, Now) ->
    case file:list_dir(Directory) of
        {ok, Names} ->
            {Count, Error} = lists:foldl(fun(Name, {Acc, ExistingError}) ->
                cleanup_attachment_name(Directory, Name, Now, Acc, ExistingError)
            end, {0, none}, Names),
            case Error of
                none -> {ok, Count};
                Reason -> {error, Reason}
            end;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

cleanup_attachment_name(Directory, Name, Now, Count, ExistingError) ->
    NameBinary = unicode:characters_to_binary(Name),
    case filename:extension(NameBinary) of
        <<".expires">> ->
            Meta = filename:join(Directory, NameBinary),
            Key = filename:rootname(NameBinary, <<".expires">>),
            Blob = attachment_path(Directory, Key, <<".blob">>),
            case filelib:is_regular(Blob) of
                false ->
                    case file:delete(Meta) of
                        ok -> {Count + 1, ExistingError};
                        {error, enoent} -> {Count, ExistingError};
                        {error, Reason} -> {Count, atom_to_binary(Reason)}
                    end;
                true -> case file:read_file(Meta) of
                    {ok, Encoded} ->
                        try binary_to_integer(Encoded) of
                            Expiry when Expiry =< Now ->
                            case attachment_delete(Directory, Key) of
                                {ok, nil} -> {Count + 1, ExistingError};
                                {error, Reason} -> {Count, Reason}
                            end;
                            _ -> {Count, ExistingError}
                        catch _:_ -> {Count, <<"invalid_metadata">>} end;
                    {error, Reason} -> {Count, atom_to_binary(Reason)}
                end
            end;
        <<".blob">> ->
            Key = filename:rootname(NameBinary, <<".blob">>),
            Meta = attachment_path(Directory, Key, <<".expires">>),
            case filelib:is_regular(Meta) of
                true -> {Count, ExistingError};
                false ->
                    case file:delete(filename:join(Directory, NameBinary)) of
                        ok -> {Count + 1, ExistingError};
                        {error, enoent} -> {Count, ExistingError};
                        {error, Reason} -> {Count, atom_to_binary(Reason)}
                    end
            end;
        <<".tmp">> ->
            Path = filename:join(Directory, NameBinary),
            case attachment_temp_is_stale(Path, Now) of
                true ->
                    case file:delete(Path) of
                        ok -> {Count + 1, ExistingError};
                        {error, enoent} -> {Count, ExistingError};
                        {error, Reason} -> {Count, atom_to_binary(Reason)}
                    end;
                false -> {Count, ExistingError}
            end;
        _ -> {Count, ExistingError}
    end.

attachment_temp_is_stale(Path, Now) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = Modified}} when is_integer(Modified) ->
            Modified =< Now - 3600;
        _ -> false
    end.

attachment_health(Directory) ->
    Probe = filename:join(Directory, <<".notify-health.tmp">>),
    case file:write_file(Probe, <<>>, [binary, sync]) of
        ok ->
            _ = file:delete(Probe),
            {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

make_temporary_directory() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Random = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase)),
    Name = "notify-attachments-" ++ Random,
    Path = filename:join(Base, Name),
    case file:make_dir(Path) of
        ok -> {ok, unicode:characters_to_binary(Path)};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

attachment_path(Directory, Key, Extension) ->
    filename:join(Directory, <<Key/binary, Extension/binary>>).

attachment_blob_path(Directory, Key) ->
    attachment_path(Directory, Key, <<".blob">>).

attachment_total_size(Directory) ->
    filelib:fold_files(binary_to_list(Directory), ".*\\.blob$", false,
        fun(File, Total) -> filelib:file_size(File) + Total end, 0).

s3_multipart_begin(Config, StagingKey, Expires) ->
    Headers = [{<<"x-amz-meta-expires">>, integer_to_binary(Expires)}],
    case s3_request(Config, <<"POST">>, StagingKey, <<"uploads=">>, Headers, <<>>) of
        {ok, Status, _, Body} when Status >= 200, Status < 300 ->
            case re:run(Body, <<"<UploadId>([^<]+)</UploadId>">>,
                        [{capture, [1], binary}]) of
                {match, [UploadId]} -> {ok, s3_xml_unescape(UploadId)};
                _ -> {error, <<"invalid_s3_multipart_response">>}
            end;
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_multipart_write(Config, StagingKey, UploadId, PartNumber, Data) ->
    EncodedUploadId = s3_query_encode(UploadId),
    Query = iolist_to_binary([
        <<"partNumber=">>, integer_to_binary(PartNumber),
        <<"&uploadId=">>, EncodedUploadId
    ]),
    case s3_request(Config, <<"PUT">>, StagingKey, Query, [], Data) of
        {ok, Status, Headers, _} when Status >= 200, Status < 300 ->
            case s3_response_header("etag", Headers) of
                {ok, Etag} -> {ok, unicode:characters_to_binary(Etag)};
                error -> {error, <<"missing_s3_multipart_etag">>}
            end;
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_multipart_complete(Config, StagingKey, UploadId, Parts) ->
    EncodedUploadId = s3_query_encode(UploadId),
    Body = iolist_to_binary([
        <<"<CompleteMultipartUpload>">>,
        [[<<"<Part><PartNumber>">>, integer_to_binary(Number),
          <<"</PartNumber><ETag>">>, s3_xml_escape(Etag),
          <<"</ETag></Part>">>] || {Number, Etag} <- Parts],
        <<"</CompleteMultipartUpload>">>
    ]),
    Query = <<"uploadId=", EncodedUploadId/binary>>,
    case s3_request(Config, <<"POST">>, StagingKey, Query, [], Body) of
        {ok, Status, _, ResponseBody} when Status >= 200, Status < 300 ->
            case binary:match(ResponseBody, <<"<Error>">>) of
                nomatch -> {ok, nil};
                _ -> {error, <<"s3_multipart_completion_error">>}
            end;
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_multipart_abort(Config, StagingKey, UploadId) ->
    Query = <<"uploadId=", (s3_query_encode(UploadId))/binary>>,
    case s3_request(Config, <<"DELETE">>, StagingKey, Query, [], <<>>) of
        {ok, Status, _, _} when Status >= 200, Status < 300 -> {ok, nil};
        {ok, 404, _, _} -> {ok, nil};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_promote_staging(Config, StagingKey, Key, Expires, MaxTotal) ->
    case s3_head(Config, Key) of
        {ok, {_Size, ExistingExpiry}} ->
            Latest = erlang:max(Expires, ExistingExpiry),
            case s3_copy_object(Config, Key, Key, Latest) of
                {ok, nil} -> s3_delete(Config, StagingKey);
                Error -> Error
            end;
        {error, <<"not_found">>} ->
            case {s3_head(Config, StagingKey), s3_list_objects(Config)} of
                {{ok, {StagingSize, _}}, {ok, Objects}} ->
                    Total = lists:sum([
                        Size || {ObjectKey, Size} <- Objects,
                                not s3_is_staging(ObjectKey)
                    ]),
                    case Total + StagingSize > MaxTotal of
                        true -> {error, <<"quota">>};
                        false ->
                            case s3_copy_object(
                                    Config, StagingKey, Key, Expires) of
                                {ok, nil} -> s3_delete(Config, StagingKey);
                                Error -> Error
                            end
                    end;
                {{error, Reason}, _} -> {error, Reason};
                {_, {error, Reason}} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

s3_copy_object({config, _Endpoint, Bucket, _Region, _AccessKey,
                _SecretKey, _PathStyle} = Config,
               SourceKey, TargetKey, Expires) ->
    RawSource = <<"/", Bucket/binary, "/", SourceKey/binary>>,
    CopySource = unicode:characters_to_binary(
        uri_string:quote(binary_to_list(RawSource))),
    Headers = [
        {<<"x-amz-copy-source">>, CopySource},
        {<<"x-amz-metadata-directive">>, <<"REPLACE">>},
        {<<"x-amz-meta-expires">>, integer_to_binary(Expires)}
    ],
    case s3_request(Config, <<"PUT">>, TargetKey, <<>>, Headers, <<>>) of
        {ok, Status, _, _} when Status >= 200, Status < 300 -> {ok, nil};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_query_encode(Value) ->
    unicode:characters_to_binary(uri_string:quote(binary_to_list(Value))).

s3_is_staging(<<".staging/", _/binary>>) -> true;
s3_is_staging(_) -> false.

s3_put(Config, Key, Data, Expires, MaxTotal) ->
    case s3_head(Config, Key) of
        {ok, {_Size, ExistingExpiry}} ->
            s3_put_object(Config, Key, Data, erlang:max(Expires, ExistingExpiry));
        {error, <<"not_found">>} ->
            case s3_list_objects(Config) of
                {ok, Objects} ->
                    Total = lists:sum([
                        Size || {ObjectKey, Size} <- Objects,
                                not s3_is_staging(ObjectKey)
                    ]),
                    case Total + byte_size(Data) > MaxTotal of
                        true -> {error, <<"quota">>};
                        false -> s3_put_object(Config, Key, Data, Expires)
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

s3_put_object(Config, Key, Data, Expires) ->
    Headers = [{<<"x-amz-meta-expires">>, integer_to_binary(Expires)}],
    case s3_request(Config, <<"PUT">>, Key, <<>>, Headers, Data) of
        {ok, Status, _ResponseHeaders, _Body} when Status >= 200, Status < 300 ->
            {ok, nil};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_head(Config, Key) ->
    case s3_request(Config, <<"HEAD">>, Key, <<>>, [], <<>>) of
        {ok, Status, Headers, _} when Status >= 200, Status < 300 ->
            case {s3_response_header("content-length", Headers),
                  s3_response_header("x-amz-meta-expires", Headers)} of
                {{ok, SizeRaw}, {ok, ExpiresRaw}} ->
                    try {ok, {list_to_integer(SizeRaw), list_to_integer(ExpiresRaw)}}
                    catch _:_ -> {error, <<"invalid_s3_metadata">>} end;
                _ -> {error, <<"invalid_s3_metadata">>}
            end;
        {ok, 404, _, _} -> {error, <<"not_found">>};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_get(Config, Key, none) ->
    case s3_request(Config, <<"GET">>, Key, <<>>, [], <<>>) of
        {ok, Status, _, Body} when Status >= 200, Status < 300 ->
            Size = byte_size(Body),
            End = case Size of 0 -> -1; _ -> Size - 1 end,
            {ok, {Body, Size, 0, End}};
        {ok, 404, _, _} -> {error, <<"not_found">>};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end;
s3_get(Config, Key, {some, {byte_range, Start, End}})
  when Start >= 0, End >= Start ->
    Range = iolist_to_binary([
        <<"bytes=">>, integer_to_binary(Start), <<"-">>, integer_to_binary(End)
    ]),
    case s3_request(Config, <<"GET">>, Key, <<>>, [{<<"range">>, Range}], <<>>) of
        {ok, 206, Headers, Body} ->
            case s3_content_range(Headers) of
                {ok, {ActualStart, ActualEnd, Total}}
                  when ActualStart =:= Start, ActualEnd =:= End,
                       byte_size(Body) =:= End - Start + 1 ->
                    {ok, {Body, Total, Start, End}};
                {ok, {_ActualStart, _ActualEnd, Total}} when End >= Total ->
                    %% S3 implementations may truncate an overlong explicit
                    %% end offset and return 206 instead of 416. Notify's store
                    %% contract rejects that request consistently across all
                    %% backends.
                    {error, <<"invalid_range">>};
                _ -> {error, <<"invalid_s3_range_response">>}
            end;
        {ok, 404, _, _} -> {error, <<"not_found">>};
        {ok, 416, _, _} -> {error, <<"invalid_range">>};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end;
s3_get(_Config, _Key, {some, {byte_range, _Start, _End}}) ->
    {error, <<"invalid_range">>}.

s3_content_range(Headers) ->
    case s3_response_header("content-range", Headers) of
        {ok, Value} ->
            ValueBinary = unicode:characters_to_binary(Value),
            Pattern = <<"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$">>,
            case re:run(ValueBinary, Pattern, [{capture, [1, 2, 3], binary}]) of
                {match, [Start, End, Total]} ->
                    try {ok, {binary_to_integer(Start), binary_to_integer(End),
                              binary_to_integer(Total)}}
                    catch _:_ -> error end;
                _ -> error
            end;
        error -> error
    end.

s3_delete(Config, Key) ->
    case s3_request(Config, <<"DELETE">>, Key, <<>>, [], <<>>) of
        {ok, Status, _, _} when Status >= 200, Status < 300 -> {ok, nil};
        {ok, 404, _, _} -> {ok, nil};
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_list(Config) ->
    case s3_list_objects(Config) of
        {error, Reason} -> {error, Reason};
        {ok, Objects} -> s3_list_metadata(
            Config,
            [{Key, Size} || {Key, Size} <- Objects, not s3_is_staging(Key)],
            [])
    end.

s3_list_metadata(_Config, [], Acc) -> {ok, lists:reverse(Acc)};
s3_list_metadata(Config, [{Key, _ListedSize} | Rest], Acc) ->
    case s3_head(Config, Key) of
        {ok, {Size, Expires}} ->
            s3_list_metadata(Config, Rest, [{Key, Size, Expires} | Acc]);
        {error, <<"not_found">>} -> s3_list_metadata(Config, Rest, Acc);
        {error, Reason} -> {error, Reason}
    end.

s3_page(Config, After, Limit)
  when is_integer(Limit), Limit > 0, Limit =< 1000 ->
    StartAfter = case After of
        none -> <<"/">>;
        {some, Cursor} -> Cursor
    end,
    Query = <<"list-type=2&max-keys=", (integer_to_binary(Limit))/binary,
              "&start-after=", (s3_query_encode(StartAfter))/binary>>,
    case s3_request(Config, <<"GET">>, <<>>, Query, [], <<>>) of
        {ok, Status, _, Body} when Status >= 200, Status < 300 ->
            Pattern = <<"<Contents>.*?<Key>([^<]+)</Key>.*?<Size>([0-9]+)</Size>.*?</Contents>">>,
            case re:run(
                    Body, Pattern,
                    [global, dotall, {capture, [1, 2], binary}]) of
                nomatch -> {ok, []};
                {match, Captures} -> try
                    Objects = [
                        {s3_xml_unescape(Key), binary_to_integer(Size)}
                        || [Key, Size] <- Captures,
                           not s3_is_staging(s3_xml_unescape(Key))
                    ],
                    s3_page_metadata(Config, Objects, [])
                catch _:_ -> {error, <<"invalid_s3_list_response">>} end;
                {error, _} -> {error, <<"invalid_s3_list_response">>}
            end;
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end;
s3_page(_Config, _After, _Limit) -> {error, <<"invalid_page">>}.

s3_page_metadata(_Config, [], Acc) -> {ok, lists:reverse(Acc)};
s3_page_metadata(Config, [{Key, _ListedSize} | Rest], Acc) ->
    case s3_head(Config, Key) of
        {ok, {Size, Expires}} ->
            s3_page_metadata(Config, Rest, [{Key, Size, Expires} | Acc]);
        {error, <<"not_found">>} -> {error, <<"s3_page_changed">>};
        {error, Reason} -> {error, Reason}
    end.

s3_cleanup(Config, Now) ->
    case s3_cleanup_multipart_uploads(Config, Now) of
        {error, Reason} -> {error, Reason};
        {ok, MultipartCount} ->
            case s3_list_objects(Config) of
                {error, Reason} -> {error, Reason};
                {ok, Objects} ->
                    s3_cleanup_objects(
                        Config, Objects, Now, MultipartCount)
            end
    end.

s3_cleanup_multipart_uploads(Config, Now) ->
    s3_cleanup_multipart_page(Config, Now, none, none, 0, 0).

s3_cleanup_multipart_page(_Config, _Now, _KeyMarker, _UploadMarker,
                          _Count, Page) when Page >= 10000 ->
    {error, <<"s3_multipart_list_page_limit_exceeded">>};
s3_cleanup_multipart_page(Config, Now, KeyMarker, UploadMarker, Count, Page) ->
    Query = s3_multipart_list_query(KeyMarker, UploadMarker),
    case s3_request(Config, <<"GET">>, <<>>, Query, [], <<>>) of
        {ok, Status, _, Body} when Status >= 200, Status < 300 ->
            Pattern = <<"<Upload>.*?<Key>([^<]+)</Key>.*?<UploadId>([^<]+)</UploadId>.*?<Initiated>([^<]+)</Initiated>.*?</Upload>">>,
            case re:run(
                    Body, Pattern,
                    [global, dotall, {capture, [1, 2, 3], binary}]) of
                nomatch ->
                    s3_cleanup_multipart_next(
                        Config, Now, Body, Count, Page);
                {match, Captures} ->
                    case s3_cleanup_multipart_items(
                            Config, Now, Captures, Count) of
                        {error, Reason} -> {error, Reason};
                        {ok, NextCount} ->
                            s3_cleanup_multipart_next(
                                Config, Now, Body, NextCount, Page)
                    end;
                {error, _} -> {error, <<"invalid_s3_multipart_list_response">>}
            end;
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_cleanup_multipart_items(_Config, _Now, [], Count) -> {ok, Count};
s3_cleanup_multipart_items(Config, Now, [[RawKey, RawUploadId, Initiated] | Rest],
                           Count) ->
    Key = s3_xml_unescape(RawKey),
    UploadId = s3_xml_unescape(RawUploadId),
    case {s3_is_staging(Key), s3_rfc3339_seconds(Initiated)} of
        {true, {ok, StartedAt}} when StartedAt =< Now - 3600 ->
            case s3_multipart_abort(Config, Key, UploadId) of
                {ok, nil} ->
                    s3_cleanup_multipart_items(
                        Config, Now, Rest, Count + 1);
                {error, Reason} -> {error, Reason}
            end;
        {_, {ok, _}} ->
            s3_cleanup_multipart_items(Config, Now, Rest, Count);
        {_, error} -> {error, <<"invalid_s3_multipart_initiated_at">>}
    end.

s3_cleanup_multipart_next(Config, Now, Body, Count, Page) ->
    case binary:match(Body, <<"<IsTruncated>true</IsTruncated>">>) of
        nomatch -> {ok, Count};
        _ ->
            case {
                s3_xml_field(Body, <<"NextKeyMarker">>),
                s3_xml_field(Body, <<"NextUploadIdMarker">>)
            } of
                {{ok, NextKey}, {ok, NextUpload}} ->
                    s3_cleanup_multipart_page(
                        Config,
                        Now,
                        {some, NextKey},
                        {some, NextUpload},
                        Count,
                        Page + 1);
                _ -> {error, <<"invalid_s3_multipart_list_response">>}
            end
    end.

s3_multipart_list_query(none, none) -> <<"uploads=">>;
s3_multipart_list_query({some, Key}, {some, UploadId}) ->
    EncodedKey = s3_query_encode(Key),
    EncodedUploadId = s3_query_encode(UploadId),
    <<"key-marker=", EncodedKey/binary,
      "&upload-id-marker=", EncodedUploadId/binary, "&uploads=">>.

s3_xml_field(Body, Name) ->
    Pattern = <<"<", Name/binary, ">([^<]+)</", Name/binary, ">">>,
    case re:run(Body, Pattern, [{capture, [1], binary}]) of
        {match, [Value]} -> {ok, s3_xml_unescape(Value)};
        _ -> error
    end.

s3_rfc3339_seconds(Value) ->
    try
        {ok, calendar:rfc3339_to_system_time(
            binary_to_list(Value), [{unit, second}])}
    catch _:_ -> error end.

s3_cleanup_objects(_Config, [], _Now, Count) -> {ok, Count};
s3_cleanup_objects(Config, [{Key, _Size} | Rest], Now, Count) ->
    case s3_head(Config, Key) of
        {ok, {_ObjectSize, Expires}} when Expires =< Now ->
            case s3_delete(Config, Key) of
                {ok, nil} -> s3_cleanup_objects(Config, Rest, Now, Count + 1);
                {error, Reason} -> {error, Reason}
            end;
        {ok, _} -> s3_cleanup_objects(Config, Rest, Now, Count);
        {error, <<"not_found">>} -> s3_cleanup_objects(Config, Rest, Now, Count);
        {error, Reason} -> {error, Reason}
    end.

s3_health(Config) ->
    case s3_list_objects(Config) of
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

s3_list_objects(Config) ->
    s3_list_objects(Config, none, [], 0).

s3_list_objects(_Config, _Continuation, _Acc, Page) when Page >= 10000 ->
    {error, <<"s3_list_page_limit_exceeded">>};
s3_list_objects(Config, Continuation, Acc, Page) ->
    Query = s3_list_query(Continuation),
    case s3_request(Config, <<"GET">>, <<>>, Query, [], <<>>) of
        {ok, Status, _, Body} when Status >= 200, Status < 300 ->
            Pattern = <<"<Contents>.*?<Key>([^<]+)</Key>.*?<Size>([0-9]+)</Size>.*?</Contents>">>,
            case re:run(Body, Pattern, [global, dotall, {capture, [1, 2], binary}]) of
                nomatch -> s3_list_next(Config, Body, Acc, Page);
                {match, Captures} -> try
                    Objects = [{s3_xml_unescape(Key), binary_to_integer(Size)}
                               || [Key, Size] <- Captures],
                    s3_list_next(Config, Body, lists:reverse(Objects, Acc), Page)
                catch _:_ -> {error, <<"invalid_s3_list_response">>} end;
                {error, _} -> {error, <<"invalid_s3_list_response">>}
            end;
        {ok, Status, _, _} -> s3_status_error(Status);
        {error, Reason} -> {error, Reason}
    end.

s3_list_next(Config, Body, Acc, Page) ->
    case binary:match(Body, <<"<IsTruncated>true</IsTruncated>">>) of
        nomatch -> {ok, lists:reverse(Acc)};
        _ -> case re:run(
            Body,
            <<"<NextContinuationToken>([^<]+)</NextContinuationToken>">>,
            [{capture, [1], binary}]) of
            {match, [Token]} ->
                s3_list_objects(Config, {some, s3_xml_unescape(Token)}, Acc, Page + 1);
            _ -> {error, <<"invalid_s3_list_response">>}
        end
    end.

s3_list_query(none) -> <<"list-type=2">>;
s3_list_query({some, Token}) ->
    Encoded = unicode:characters_to_binary(uri_string:quote(binary_to_list(Token))),
    <<"continuation-token=", Encoded/binary, "&list-type=2">>.

s3_xml_unescape(Value) ->
    lists:foldl(fun({Encoded, Plain}, Current) ->
        binary:replace(Current, Encoded, Plain, [global])
    end, Value, [
        {<<"&amp;">>, <<"&">>},
        {<<"&lt;">>, <<"<">>},
        {<<"&gt;">>, <<">">>},
        {<<"&quot;">>, <<"\"">>},
        {<<"&apos;">>, <<"'">>}
    ]).

s3_xml_escape(Value) ->
    lists:foldl(fun({Plain, Encoded}, Current) ->
        binary:replace(Current, Plain, Encoded, [global])
    end, Value, [
        {<<"&">>, <<"&amp;">>},
        {<<"<">>, <<"&lt;">>},
        {<<">">>, <<"&gt;">>},
        {<<"\"">>, <<"&quot;">>},
        {<<"'">>, <<"&apos;">>}
    ]).

s3_request({config, Endpoint, Bucket, Region, AccessKey, SecretKey, PathStyle},
           Method, Key, Query, ExtraHeaders, Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    try
        {Url, CanonicalUri, HostHeader} =
            s3_target(Endpoint, Bucket, Key, Query, PathStyle),
        {AmzDate, DateStamp} = s3_timestamp(),
        PayloadHash = binary:encode_hex(crypto:hash(sha256, Body), lowercase),
        RequiredHeaders = [
            {<<"host">>, HostHeader},
            {<<"x-amz-content-sha256">>, PayloadHash},
            {<<"x-amz-date">>, AmzDate}
        ],
        CanonicalPairs = lists:keysort(1, RequiredHeaders ++ ExtraHeaders),
        CanonicalHeaders = iolist_to_binary([
            [Name, <<":">>, s3_trim_header(Value), <<"\n">>]
            || {Name, Value} <- CanonicalPairs
        ]),
        SignedHeaders = iolist_to_binary(lists:join(<<";">>, [
            Name || {Name, _} <- CanonicalPairs
        ])),
        CanonicalRequest = iolist_to_binary([
            Method, <<"\n">>, CanonicalUri, <<"\n">>, Query, <<"\n">>,
            CanonicalHeaders, <<"\n">>, SignedHeaders, <<"\n">>, PayloadHash
        ]),
        Scope = iolist_to_binary([
            DateStamp, <<"/">>, Region, <<"/s3/aws4_request">>
        ]),
        StringToSign = iolist_to_binary([
            <<"AWS4-HMAC-SHA256\n">>, AmzDate, <<"\n">>, Scope, <<"\n">>,
            binary:encode_hex(crypto:hash(sha256, CanonicalRequest), lowercase)
        ]),
        SigningKey = s3_signing_key(SecretKey, DateStamp, Region),
        Signature = binary:encode_hex(
            crypto:mac(hmac, sha256, SigningKey, StringToSign), lowercase),
        Authorization = iolist_to_binary([
            <<"AWS4-HMAC-SHA256 Credential=">>, AccessKey, <<"/">>, Scope,
            <<", SignedHeaders=">>, SignedHeaders,
            <<", Signature=">>, Signature
        ]),
        RequestHeaders = CanonicalPairs ++ [{<<"authorization">>, Authorization}],
        s3_http_request(Method, Url, RequestHeaders, Body)
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(
                io_lib:format("s3_request_failed: ~tp:~tp", [Class, Reason]))}
    end.

s3_target(Endpoint, Bucket, Key, Query, PathStyle) ->
    EndpointString = binary_to_list(Endpoint),
    Parsed = uri_string:parse(EndpointString),
    Scheme = unicode:characters_to_binary(maps:get(scheme, Parsed)),
    Host0 = unicode:characters_to_binary(maps:get(host, Parsed)),
    Port = maps:get(port, Parsed, undefined),
    BasePath0 = unicode:characters_to_binary(maps:get(path, Parsed, "")),
    BasePath = s3_trim_slash(BasePath0),
    {Host, ObjectPath} = case PathStyle of
        true -> {Host0, iolist_to_binary([BasePath, <<"/">>, Bucket, <<"/">>, Key])};
        false -> {iolist_to_binary([Bucket, <<".">>, Host0]),
                  iolist_to_binary([BasePath, <<"/">>, Key])}
    end,
    CanonicalUri = case ObjectPath of
        <<"/", _/binary>> -> ObjectPath;
        _ -> <<"/", ObjectPath/binary>>
    end,
    HostHeader = s3_host_header(Host, Scheme, Port),
    QuerySuffix = case Query of <<>> -> <<>>; _ -> <<"?", Query/binary>> end,
    Url = iolist_to_binary([
        Scheme, <<"://">>, HostHeader, CanonicalUri, QuerySuffix
    ]),
    {Url, CanonicalUri, HostHeader}.

s3_trim_slash(<<>>) -> <<>>;
s3_trim_slash(Value) ->
    case binary:last(Value) of
        $/ -> binary:part(Value, 0, byte_size(Value) - 1);
        _ -> Value
    end.

s3_host_header(Host, <<"http">>, undefined) -> Host;
s3_host_header(Host, <<"https">>, undefined) -> Host;
s3_host_header(Host, <<"http">>, 80) -> Host;
s3_host_header(Host, <<"https">>, 443) -> Host;
s3_host_header(Host, _Scheme, Port) ->
    iolist_to_binary([Host, <<":">>, integer_to_binary(Port)]).

s3_timestamp() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    AmzDate = iolist_to_binary(io_lib:format(
        "~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
        [Year, Month, Day, Hour, Minute, Second])),
    DateStamp = iolist_to_binary(io_lib:format(
        "~4..0B~2..0B~2..0B", [Year, Month, Day])),
    {AmzDate, DateStamp}.

s3_signing_key(SecretKey, DateStamp, Region) ->
    DateKey = crypto:mac(hmac, sha256, <<"AWS4", SecretKey/binary>>, DateStamp),
    RegionKey = crypto:mac(hmac, sha256, DateKey, Region),
    ServiceKey = crypto:mac(hmac, sha256, RegionKey, <<"s3">>),
    crypto:mac(hmac, sha256, ServiceKey, <<"aws4_request">>).

s3_trim_header(Value) when is_binary(Value) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Value)));
s3_trim_header(Value) -> unicode:characters_to_binary(string:trim(Value)).

s3_http_request(Method, Url, Headers, Body) ->
    HeaderList = [{binary_to_list(Name), binary_to_list(Value)} ||
        {Name, Value} <- Headers],
    UrlList = binary_to_list(Url),
    Options = [{timeout, 30000}],
    HttpOptions = [{body_format, binary}],
    Result = case Method of
        <<"PUT">> -> httpc:request(put,
            {UrlList, HeaderList, "application/octet-stream", Body},
            Options, HttpOptions);
        <<"GET">> -> httpc:request(get, {UrlList, HeaderList}, Options, HttpOptions);
        <<"HEAD">> -> httpc:request(head, {UrlList, HeaderList}, Options, HttpOptions);
        <<"POST">> -> httpc:request(post,
            {UrlList, HeaderList, "application/xml", Body},
            Options, HttpOptions);
        <<"DELETE">> -> httpc:request(delete, {UrlList, HeaderList}, Options, HttpOptions)
    end,
    case Result of
        {ok, {{_, Status, _}, ResponseHeaders, ResponseBody}} ->
            {ok, Status, ResponseHeaders, ResponseBody};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format(
                "s3_transport_error: ~tp", [Reason]))}
    end.

s3_response_header(Name, Headers) ->
    LowerName = string:lowercase(Name),
    case lists:dropwhile(fun({HeaderName, _}) ->
        string:lowercase(HeaderName) =/= LowerName
    end, Headers) of
        [{_, Value} | _] -> {ok, Value};
        [] -> error
    end.

s3_status_error(Status) ->
    {error, iolist_to_binary([<<"s3_http_">>, integer_to_binary(Status)])}.

atom_to_binary(Reason) ->
    unicode:characters_to_binary(atom_to_list(Reason)).
