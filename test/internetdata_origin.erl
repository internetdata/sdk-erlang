%% A real HTTP origin on a real socket, for the claims a stubbed transport cannot
%% make honestly: that httpc itself lets the configured number of requests run at
%% once, that a redirect to a huge file is not followed, that a dataset transfer
%% really does move bytes over a socket and stops when they run out, and that a
%% large body is handed over in pieces rather than assembled in memory first.
%%
%% It doubles as the object storage behind a 302, so a download test can check
%% that the second request carried no credential.
-module(internetdata_origin).

-export([start/1, stop/1, base_url/1, peak/1, hits/2, authorized/2, payload/0, large_bytes/0]).

-define(HUGE_BYTES, 5000000000).
-define(PAYLOAD_BYTES, 3000000).
-define(LARGE_BYTES, 67108864).
-define(WRITE_BYTES, 65536).

start(Options) ->
    Parent = self(),
    Pid = spawn_link(fun() -> boot(Parent, Options) end),
    receive
        {?MODULE, Pid, ready} -> Pid
    after 5000 ->
        error(origin_did_not_start)
    end.

stop(Pid) ->
    ask(Pid, stop).

base_url(Pid) ->
    Port = ask(Pid, port),
    iolist_to_binary(io_lib:format("http://127.0.0.1:~b", [Port])).

%% @doc The highest number of requests that were being served at the same moment.
peak(Pid) ->
    ask(Pid, peak).

%% @doc How many times one path was requested.
hits(Pid, Path) ->
    maps:get(Path, ask(Pid, hits), 0).

%% @doc Whether ANY request for one path arrived with an authorization header.
%% `false' for a path nobody asked for, which is why callers check the hit count
%% first: an unasked path trivially carried no credential.
authorized(Pid, Path) ->
    maps:get(Path, ask(Pid, authorized), false).

%% @doc The bytes `/dataset' serves. Deterministic, so a test can hash them.
payload() ->
    Seed = <<"internetdata dataset payload, 64 bytes of it, repeated to size.\n">>,
    Repeats = ?PAYLOAD_BYTES div byte_size(Seed),
    binary:part(binary:copy(Seed, Repeats + 1), 0, ?PAYLOAD_BYTES).

%% @doc How many bytes `/large' serves. Generated a piece at a time on the way
%% out, so the origin does not hold it either and the memory a test observes is
%% the client's.
large_bytes() ->
    ?LARGE_BYTES.

boot(Parent, Options) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {packet, http_bin}, {backlog, 128}]),
    {ok, Port} = inet:port(Listen),
    Self = self(),
    spawn_link(fun() -> accept_loop(Listen, Self, Options#{port => Port}) end),
    Parent ! {?MODULE, self(), ready},
    loop(#{port => Port, in_flight => 0, peak => 0, hits => #{}, authorized => #{}}).

loop(#{in_flight := InFlight, peak := Peak, hits := Hits, authorized := Auth} = State) ->
    receive
        {started, Path, Credentialed} ->
            loop(State#{in_flight := InFlight + 1, peak := max(Peak, InFlight + 1),
                        hits := maps:update_with(Path, fun(N) -> N + 1 end, 1, Hits),
                        authorized := maps:update_with(Path, fun(A) -> A orelse Credentialed end,
                                                       Credentialed, Auth)});
        finished ->
            loop(State#{in_flight := InFlight - 1});
        {Key, From, Ref} when Key =:= port; Key =:= peak; Key =:= hits; Key =:= authorized ->
            From ! {Ref, maps:get(Key, State)},
            loop(State);
        {stop, From, Ref} ->
            From ! {Ref, ok}
    end.

accept_loop(Listen, Counter, Options) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            spawn(fun() -> serve(Socket, Counter, Options) end),
            accept_loop(Listen, Counter, Options);
        {error, closed} ->
            ok
    end.

serve(Socket, Counter, Options) ->
    case read_request(Socket) of
        {ok, Path, Query, Credentialed, Body} ->
            Counter ! {started, Path, Credentialed},
            timer:sleep(maps:get(delay_ms, Options, 0)),
            case {maps:find(body_pace, Options), Path} of
                {{ok, Pace}, _} -> paced(Socket, Pace);
                {error, <<"/flaky">>} -> flaky(Socket, Counter);
                {error, <<"/batch">>} -> respond_batch(Socket, Body);
                {error, _} -> respond(Socket, Path, Query, Options)
            end,
            Counter ! finished,
            gen_tcp:close(Socket);
        error ->
            gen_tcp:close(Socket)
    end.

read_request(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_request, _Method, {abs_path, Target}, _Version}} ->
            [Path | Rest] = binary:split(Target, <<"?">>),
            Seen = headers(Socket, #{credentialed => false, length => 0}),
            #{credentialed := Credentialed, length := Length} = Seen,
            {ok, Path, iolist_to_binary(Rest), Credentialed, body(Socket, Length)};
        {ok, _Other} ->
            read_request(Socket);
        {error, _} ->
            error
    end.

%% Answers whether a credential was presented, which is the whole question at the
%% object storage end of a download, and how long the body is, which a POST
%% carries after the blank line.
headers(Socket, Seen) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Seen;
        {ok, {http_header, _, 'Authorization', _, _}} -> headers(Socket, Seen#{credentialed := true});
        {ok, {http_header, _, 'Content-Length', _, Value}} ->
            headers(Socket, Seen#{length := binary_to_integer(Value)});
        {ok, _} -> headers(Socket, Seen);
        {error, _} -> Seen
    end.

%% httpc sends `Content-Length: 0' on a GET, and a recv of 0 bytes would wait out
%% its whole timeout.
body(_Socket, 0) ->
    <<>>;
body(Socket, Length) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    case gen_tcp:recv(Socket, Length, 5000) of
        {ok, Body} -> Body;
        {error, _} -> <<>>
    end.

%% A batch is answered from the addresses in its body, each one an Unlimited
%% answer.
respond_batch(Socket, Body) ->
    Ips = try json:decode(Body) of
        #{<<"ips">> := List} when is_list(List) -> List;
        _ -> []
    catch
        _:_ -> []
    end,
    Results = maps:from_list([{Ip, internetdata_stub:answer(Ip)} || Ip <- Ips]),
    Answer = iolist_to_binary(json:encode(#{<<"results">> => Results, <<"errors">> => #{}})),
    send(Socket, 200, [{<<"content-type">>, <<"application/json">>}], Answer).

%% Announces gigabytes and then stalls. A client that followed the redirect would
%% sit here until its own timeout, which is exactly the failure this exists to
%% catch.
respond(Socket, <<"/huge">>, _Query, _Options) ->
    send(Socket, 200, [{<<"content-type">>, <<"application/octet-stream">>},
                       {<<"content-length">>, integer_to_binary(?HUGE_BYTES)}], <<>>),
    timer:sleep(30000);
%% Written out in pieces with a pause between them, so the body cannot arrive in
%% one socket read however generous the receive buffer is. That is what makes
%% "the client saw more than one chunk" a claim about the client rather than
%% about the kernel it happened to run on.
respond(Socket, <<"/dataset">>, _Query, _Options) ->
    Whole = payload(),
    send(Socket, 200, [{<<"content-type">>, <<"application/gzip">>},
                       {<<"content-length">>, integer_to_binary(byte_size(Whole))}], <<>>),
    trickle(Socket, Whole);
%% 64 MiB, generated on the way out rather than held, so what a memory
%% measurement sees during the transfer belongs to the client.
respond(Socket, <<"/large">>, _Query, _Options) ->
    send(Socket, 200, [{<<"content-type">>, <<"application/gzip">>},
                       {<<"content-length">>, integer_to_binary(?LARGE_BYTES)}], <<>>),
    pour(Socket, ?LARGE_BYTES);
%% Declares the whole payload and hands over a tenth of it. A client that reads
%% until the socket closes calls this a complete transfer of a short file.
respond(Socket, <<"/truncated">>, _Query, _Options) ->
    Whole = payload(),
    send(Socket, 200, [{<<"content-type">>, <<"application/gzip">>},
                       {<<"content-length">>, integer_to_binary(byte_size(Whole))}],
         binary:part(Whole, 0, byte_size(Whole) div 10));
%% A 503 naming a `Retry-After', from the API and from object storage alike.
respond(Socket, Path, _Query, #{unavailable := RetryAfter})
  when Path =:= <<"/api/v2/database/list">>; Path =:= <<"/unavailable">> ->
    send(Socket, 503, [{<<"content-type">>, <<"application/json">>}, {<<"retry-after">>, RetryAfter}],
         iolist_to_binary(json:encode(#{<<"rc">> => <<"UNAVAILABLE">>})));
respond(Socket, <<"/expired">>, _Query, _Options) ->
    send(Socket, 403, [{<<"content-type">>, <<"application/xml">>}],
         <<"<Error><Code>AccessDenied</Code></Error>">>);
respond(Socket, <<"/api/v2/database/download">>, Query, Options) ->
    case dataset(Query) of
        <<"unlicensed">> ->
            send(Socket, 403, [{<<"content-type">>, <<"application/json">>}],
                 iolist_to_binary(json:encode(#{<<"rc">> => <<"NOT_LICENSED">>})));
        Id ->
            Location = iolist_to_binary(io_lib:format("http://127.0.0.1:~b/~s",
                                                      [maps:get(port, Options), Id])),
            send(Socket, 302, [{<<"location">>, Location}], <<>>)
    end;
%% The lookups answer from what their path names: an address, the caller's, an
%% AS or a domain, each in the shape every plan answers.
respond(Socket, <<"/myip">>, _Query, _Options) ->
    json(Socket, internetdata_stub:answer(<<"203.0.113.9">>));
respond(Socket, <<"/asn/", Asn/binary>>, _Query, _Options) ->
    json(Socket, #{<<"asn">> => binary_to_integer(Asn), <<"name">> => <<>>, <<"country">> => <<>>,
                   <<"registry">> => <<>>, <<"allocated">> => <<>>, <<"domain">> => <<>>});
respond(Socket, <<"/domain/", Domain/binary>>, _Query, _Options) ->
    Flags = maps:from_keys([<<"is_registered">>, <<"has_a">>, <<"has_aaaa">>, <<"has_mx">>, <<"has_ns">>,
                            <<"has_cname">>], false),
    json(Socket, Flags#{<<"domain">> => Domain});
respond(Socket, <<"/", Target/binary>> = Path, Query, Options) ->
    case inet:parse_strict_address(binary_to_list(Target)) of
        {ok, _} -> json(Socket, internetdata_stub:answer(Target));
        {error, _} -> unknown(Socket, Path, Query, Options)
    end.

unknown(Socket, _Path, _Query, _Options) ->
    send(Socket, 404, [{<<"content-type">>, <<"application/json">>}],
         iolist_to_binary(json:encode(#{<<"rc">> => <<"UNKNOWN_DATASET">>}))).

json(Socket, Wire) ->
    send(Socket, 200, [{<<"content-type">>, <<"application/json">>}], iolist_to_binary(json:encode(Wire))).

%% The head goes out at once and the body does not, so a bound that stops at the
%% headers never sees the stall. `{stall, Ms}' sends half the body and waits;
%% `{trickle, GapMs}' sends a byte per gap, so no single read waits long.
paced(Socket, Pace) ->
    Body = <<"{\"databases\":[]}", (binary:copy(<<" ">>, 400))/binary>>,
    send(Socket, 200, [{<<"content-type">>, <<"application/json">>},
                       {<<"content-length">>, integer_to_binary(byte_size(Body))}], <<>>),
    case Pace of
        {stall, Ms} ->
            Half = byte_size(Body) div 2,
            _ = gen_tcp:send(Socket, binary:part(Body, 0, Half)),
            timer:sleep(Ms),
            gen_tcp:send(Socket, binary:part(Body, Half, byte_size(Body) - Half));
        {trickle, GapMs} ->
            trickle_bytes(Socket, Body, GapMs)
    end.

trickle_bytes(_Socket, <<>>, _GapMs) ->
    ok;
trickle_bytes(Socket, <<Byte, Rest/binary>>, GapMs) ->
    case gen_tcp:send(Socket, <<Byte>>) of
        ok -> timer:sleep(GapMs), trickle_bytes(Socket, Rest, GapMs);
        {error, _} -> ok
    end.

%% Object storage failing before the first byte of its first answer, and serving
%% the dataset to every later one.
flaky(Socket, Counter) ->
    case maps:get(<<"/flaky">>, ask(Counter, hits)) of
        1 -> send(Socket, 503, [{<<"content-type">>, <<"application/xml">>}],
                  <<"<Error><Code>SlowDown</Code></Error>">>);
        _ -> respond(Socket, <<"/dataset">>, <<>>, #{})
    end.

%% The `id' the client asked for doubles as the name of the file the redirect
%% points at, so one origin serves every download case.
dataset(Query) ->
    case [V || {<<"id">>, V} <- uri_string:dissect_query(Query)] of
        [Id | _] -> Id;
        [] -> <<"huge">>
    end.

trickle(_Socket, <<>>) ->
    ok;
trickle(Socket, Body) ->
    Take = min(?WRITE_BYTES, byte_size(Body)),
    <<Piece:Take/binary, Rest/binary>> = Body,
    case gen_tcp:send(Socket, Piece) of
        ok -> timer:sleep(1), trickle(Socket, Rest);
        {error, _} -> ok
    end.

pour(_Socket, 0) ->
    ok;
pour(Socket, Left) ->
    Take = min(?WRITE_BYTES, Left),
    case gen_tcp:send(Socket, binary:copy(<<"i">>, Take)) of
        ok -> pour(Socket, Left - Take);
        {error, _} -> ok
    end.

send(Socket, Status, Headers, Body) ->
    Length = case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Declared} -> Declared;
        false -> integer_to_binary(byte_size(Body))
    end,
    All = lists:keystore(<<"content-length">>, 1, Headers, {<<"content-length">>, Length}),
    Lines = [io_lib:format("~s: ~s\r\n", [K, V]) || {K, V} <- All],
    Head = io_lib:format("HTTP/1.1 ~b ~s\r\nconnection: close\r\n", [Status, phrase(Status)]),
    inet:setopts(Socket, [{packet, raw}]),
    gen_tcp:send(Socket, [Head, Lines, "\r\n", Body]).

phrase(200) -> "OK";
phrase(302) -> "Found";
phrase(403) -> "Forbidden";
phrase(404) -> "Not Found";
phrase(_) -> "Status".

ask(Pid, Message) ->
    Ref = make_ref(),
    Pid ! {Message, self(), Ref},
    receive
        {Ref, Reply} -> Reply
    after 5000 ->
        error(origin_unresponsive)
    end.
