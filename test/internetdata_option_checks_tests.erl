%% Options no call could use are refused where they are given: a client's in
%% new/1, a call's as a bad_request before any request, and a middleware's when
%% it is built.
-module(internetdata_option_checks_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IP, <<"66.249.66.1">>).

%%% ------------------------------------------------------------------ the cache

a_cache_option_no_lookup_could_use_is_refused_when_the_client_is_built_test_() ->
    Bad = [{ttl_ms, infinity}, {ttl_ms, "x"}, {ttl_ms, 0}, {ttl_ms, -1}, {ttl_ms, 1.5},
           {max, -1}, {max, 0}, {max, infinity}, {max, "x"}],
    [{lists:flatten(io_lib:format("~p => ~p", [Name, V])),
      ?_assertError({badarg, {cache, {Name, V}}}, internetdata:new(#{cache => #{Name => V}, http => http()}))}
     || {Name, V} <- Bad]
    ++ [{lists:flatten(io_lib:format("cache => ~p", [V])),
         ?_assertError({badarg, {cache, V}}, internetdata:new(#{cache => V, http => http()}))}
        || V <- [true, undefined, [{max, 5}]]].

a_cache_of_one_entry_and_one_millisecond_builds_and_serves_test() ->
    {Http, Count} = counting(answer()),
    Client = internetdata:new(#{api_key => <<"k">>, cache => #{max => 1, ttl_ms => 1}, http => Http}),
    {ok, _} = internetdata:lookup(Client, ?IP),
    {ok, _} = internetdata:lookup(Client, <<"66.249.66.2">>),
    ?assertEqual(2, counters:get(Count, 1)),
    internetdata:close(Client).

%%% ------------------------------------------------------- database_downloads/2

a_downloads_limit_that_is_no_count_is_a_bad_request_and_sends_nothing_test_() ->
    [{lists:flatten(io_lib:format("limit => ~p", [Limit])), fun() ->
        {Http, Count} = counting(<<"{\"downloads\":[]}">>),
        Client = internetdata:new(#{api_key => <<"k">>, cache => false, http => Http}),
        ?assertMatch({error, #{kind := bad_request, retryable := false}},
                     internetdata:database_downloads(Client, #{limit => Limit})),
        ?assertEqual(0, counters:get(Count, 1))
     end} || Limit <- [1.5, x, -1, 0, "5", <<"5">>]].

%%% ------------------------------------------------------- the middleware core

a_middleware_option_no_request_could_use_is_refused_when_it_is_built_test_() ->
    Bad = [{on_missing_field, throw}, {on_missing_field, bogus}, {fail_closed, yes}, {fail_closed, 1},
           {allow_bots, yes}, {block_condition, [#{is_tor => true}, foo]}, {block_condition, 42},
           {block_condition, true}],
    [{lists:flatten(io_lib:format("~p => ~p", [Name, V])),
      ?_assertMatch({error, {bad_option, Name, V, <<_/binary>>}},
                    internetdata_middleware:new(#{client => client(), Name => V}))}
     || {Name, V} <- Bad].

an_empty_list_of_conditions_is_refused_as_constraining_nothing_test() ->
    ?assertMatch({error, {constrains_nothing, [], <<_/binary>>}},
                 internetdata_middleware:new(#{client => client(), block_condition => []})).

every_documented_middleware_option_value_still_builds_test_() ->
    Good = [{on_missing_field, warn}, {on_missing_field, error}, {on_missing_field, ignore},
            {fail_closed, true}, {fail_closed, false}, {allow_bots, true}, {allow_bots, false},
            {block_condition, #{is_tor => true}}, {block_condition, [#{is_tor => true}, #{is_relay => true}]}],
    [{lists:flatten(io_lib:format("~p => ~p", [Name, V])),
      ?_assertMatch({ok, _}, internetdata_middleware:new(#{client => client(), Name => V}))}
     || {Name, V} <- Good].

%%% ------------------------------------------------- a served user_agent verdict

a_served_user_agent_that_is_no_verdict_is_a_retried_server_error_test_() ->
    Bad = [<<"5">>, <<"\"verified\"">>, <<"[]">>, <<"{\"agent\":\"Googlebot\",\"kind\":\"bot\"}">>,
           <<"{\"agent\":1,\"kind\":\"bot\",\"verdict\":\"verified\"}">>,
           <<"{\"agent\":\"Googlebot\",\"kind\":\"bot\",\"verdict\":true}">>],
    [{"a well-formed verdict is read", fun() ->
        {Http, _} = counting(answer(<<"{\"agent\":\"Googlebot\",\"kind\":\"bot\",\"verdict\":\"verified\"}">>)),
        Client = internetdata:new(#{api_key => <<"k">>, cache => false, http => Http}),
        ?assertMatch({ok, #{user_agent := #{agent := <<"Googlebot">>, verdict := <<"verified">>}}},
                     internetdata:lookup(Client, ?IP, #{user_agent => <<"Googlebot">>}))
     end}
     | [{binary_to_list(Verdict), fun() ->
            {Http, Count} = counting(answer(Verdict)),
            Client = internetdata:new(#{api_key => <<"k">>, retries => 1, cache => false, http => Http}),
            ?assertMatch({error, #{kind := server_error, status := 200, retryable := true}},
                         internetdata:lookup(Client, ?IP, #{user_agent => <<"Googlebot">>})),
            ?assertEqual(2, counters:get(Count, 1))
        end} || Verdict <- Bad]].

%%% ------------------------------------------------------------------- helpers

answer() ->
    iolist_to_binary(json:encode(internetdata_stub:answer(?IP))).

answer(Verdict) ->
    iolist_to_binary(json:encode((internetdata_stub:answer(?IP))#{<<"user_agent">> => json:decode(Verdict)})).

counting(Body) ->
    Count = counters:new(1, []),
    {fun(_) -> counters:add(Count, 1, 1), {ok, #{status => 200, headers => [], body => Body}} end, Count}.

http() ->
    fun(_) -> {ok, #{status => 200, headers => [], body => answer()}} end.

client() ->
    internetdata:new(#{api_key => <<"k">>, cache => false, http => http()}).
