%% An HTTP stand-in that answers from a table and counts what it was asked for,
%% so "one request, not three" is asserted rather than assumed.
%%
%% Routes are keyed by request PATH, with or without its leading slash. A path
%% with no route answers 404, which is what the API does for a dataset id it does
%% not publish.
-module(internetdata_stub).

-export([start/1, stop/1, http/1, calls/1, headers_seen/1, request/2]).

start(Routes) ->
    spawn_link(fun() -> loop(#{routes => Routes, calls => 0, headers => []}) end).

stop(Pid) ->
    ask(Pid, stop).

http(Pid) ->
    fun(Request) -> ?MODULE:request(Pid, Request) end.

calls(Pid) ->
    ask(Pid, {stat, calls}).

%% @doc The request headers of every call, newest last. Used to assert the key
%% reached the wire under the scheme the API expects.
headers_seen(Pid) ->
    lists:reverse(ask(Pid, {stat, headers})).

request(Pid, #{url := Url, headers := Headers}) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, Url, Headers},
    receive
        {Ref, Response} -> Response
    after 15000 ->
        {error, stub_timeout}
    end.

loop(#{calls := Calls, headers := Seen} = State) ->
    receive
        {request, From, Ref, Url, Headers} ->
            From ! {Ref, respond(maps:get(routes, State), Url)},
            loop(State#{calls := Calls + 1, headers := [Headers | Seen]});
        {{stat, Key}, From, Ref} ->
            From ! {Ref, maps:get(Key, State)},
            loop(State);
        {stop, From, Ref} ->
            From ! {Ref, ok}
    end.

respond(Routes, Url) ->
    Path = path_of(Url),
    Route = case {maps:find(Path, Routes), maps:find(strip(Path), Routes)} of
        {{ok, R}, _} -> R;
        {_, {ok, R}} -> R;
        _ -> #{status => 404, body => #{<<"rc">> => <<"UNKNOWN_DATASET">>}}
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
