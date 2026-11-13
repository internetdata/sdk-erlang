%% An HTTP stand-in that answers from a table and counts what it was asked for,
%% so "one request, not three" and "never touched the network" are asserted
%% rather than assumed.
%%
%% Routes are keyed by request PATH, with or without its leading slash, and
%% percent decoded. A path with no route answers 404, which is what the API does
%% for a dataset ID it does not publish.
%%
%% It answers from a process and delays in a child, so several requests really do
%% overlap and the PEAK number in flight is a measurement rather than a guess.
-module(internetdata_stub).

-export([start/1, start/2, stop/1, http/1, calls/1, peak/1, headers_seen/1, request/2, answer/1]).

start(Routes) ->
    start(Routes, 0).

start(Routes, DelayMs) ->
    spawn_link(fun() ->
        loop(#{routes => Routes, delay => DelayMs, calls => 0, headers => [], in_flight => 0, peak => 0})
    end).

stop(Pid) ->
    ask(Pid, stop).

http(Pid) ->
    fun(Request) -> ?MODULE:request(Pid, Request) end.

calls(Pid) ->
    ask(Pid, {stat, calls}).

peak(Pid) ->
    ask(Pid, {stat, peak}).

%% @doc The request headers of every call, newest last. Used to assert the key
%% reached the wire under the scheme the API expects.
headers_seen(Pid) ->
    lists:reverse(ask(Pid, {stat, headers})).

%% @doc An Unlimited answer for an address: the members every plan answers, each
%% empty or false.
answer(Ip) ->
    Location = maps:from_keys([<<"continent">>, <<"continent_name">>, <<"country">>, <<"country_name">>,
                               <<"timezone">>, <<"currency_code">>, <<"currency_name">>,
                               <<"currency_symbol">>, <<"flag_emoji">>, <<"flag_unicode">>], <<>>),
    Flags = maps:from_keys([<<"is_bogon">>, <<"is_tor">>, <<"is_relay">>, <<"is_anycast">>, <<"is_carrier">>,
                            <<"is_satellite">>, <<"is_ssh">>, <<"is_smtp">>, <<"is_web">>,
                            <<"is_dns_resolver">>, <<"is_bittorrent">>], false),
    Flags#{<<"ip">> => Ip, <<"tor">> => #{}, <<"relay">> => #{}, <<"location">> => Location,
           <<"asn">> => #{<<"asn">> => 0, <<"name">> => <<>>, <<"domain">> => <<>>, <<"type">> => <<>>,
                          <<"prefix">> => <<>>},
           <<"company">> => #{<<"name">> => <<>>, <<"domain">> => <<>>},
           <<"hostname">> => <<>>, <<"abuse">> => #{<<"email">> => <<>>}}.

request(Pid, #{url := Url, headers := Headers} = Request) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, Url, Headers, maps:get(body, Request, <<>>)},
    receive
        {Ref, Response} -> Response
    after 15000 ->
        {error, stub_timeout}
    end.

loop(#{calls := Calls, headers := Seen, in_flight := InFlight, peak := Peak} = State) ->
    receive
        {request, From, Ref, Url, Headers, Body} ->
            Self = self(),
            Response = respond(maps:get(routes, State), Url, Body),
            Delay = maps:get(delay, State),
            spawn(fun() ->
                timer:sleep(Delay),
                From ! {Ref, Response},
                Self ! released
            end),
            loop(State#{calls := Calls + 1, headers := [Headers | Seen], in_flight := InFlight + 1,
                        peak := max(Peak, InFlight + 1)});
        released ->
            loop(State#{in_flight := InFlight - 1});
        {{stat, Key}, From, Ref} ->
            From ! {Ref, maps:get(Key, State)},
            loop(State);
        {stop, From, Ref} ->
            From ! {Ref, ok}
    end.

%% A `/batch' route of its own answers every batch as written, for a test of what
%% a batch does with an answer it cannot read.
respond(Routes, Url, Body) ->
    Route = case {path_of(Url), route_for(Routes, <<"/batch">>, undefined)} of
        {<<"/batch">>, undefined} -> batch_route(Routes, Body);
        {Path, _} -> route_for(Routes, Path, #{status => 404, body => #{<<"rc">> => <<"UNKNOWN_DATASET">>}})
    end,
    Headers = maps:get(headers, Route, #{}),
    {ok, #{
        status => maps:get(status, Route, 200),
        %% The real transport lowercases header names, so this one does too; a
        %% stub that handed back `Retry-After' would let a case-sensitive lookup
        %% pass here and fail against the API.
        headers => [{<<"content-type">>, <<"application/json">>}
                    | [{lower(K), V} || {K, V} <- maps:to_list(Headers)]],
        body => body(Route)
    }}.

route_for(Routes, Path, Default) ->
    case {maps:find(Path, Routes), maps:find(strip(Path), Routes)} of
        {{ok, R}, _} -> R;
        {_, {ok, R}} -> R;
        _ -> Default
    end.

%% A POST /batch is answered the way the API answers one: every address the
%% table knows is a result if its route is a 200 and an entry error otherwise,
%% and an unknown address is the 400 the API gives a string it cannot read. One
%% call however many addresses, which is what the request counts measure.
batch_route(Routes, Body) ->
    Ips = try json:decode(Body) of
        #{<<"ips">> := List} when is_list(List) -> List;
        _ -> []
    catch
        _:_ -> []
    end,
    Unknown = #{status => 400, body => #{<<"error">> => <<"not a valid IP address, AS number or domain">>}},
    {Results, Errors} = lists:foldl(fun(Ip, {R, E}) ->
        Route = route_for(Routes, <<"/", Ip/binary>>, Unknown),
        RouteBody = maps:get(body, Route, #{}),
        case maps:get(status, Route, 200) of
            200 -> {R#{Ip => RouteBody}, E};
            Status -> {R, E#{Ip => #{<<"status">> => Status,
                                     <<"error">> => maps:get(<<"error">>, RouteBody, <<>>)}}}
        end
    end, {#{}, #{}}, Ips),
    #{status => 200, body => #{<<"results">> => Results, <<"errors">> => Errors}}.

body(#{raw := Raw}) ->
    Raw;
body(Route) ->
    iolist_to_binary(json:encode(maps:get(body, Route, #{}))).

path_of(Url) ->
    #{path := Path} = uri_string:parse(Url),
    uri_string:percent_decode(Path).

strip(<<"/", Rest/binary>>) -> Rest;
strip(Path) -> Path.

lower(Name) -> list_to_binary(string:lowercase(binary_to_list(Name))).

ask(Pid, Message) ->
    Ref = make_ref(),
    Pid ! {Message, self(), Ref},
    receive
        {Ref, Reply} -> Reply
    after 5000 ->
        error(stub_unresponsive)
    end.
