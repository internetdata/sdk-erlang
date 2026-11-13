%% Runs against the real API, and only when asked, so `rebar3 eunit' stays
%% offline and costs no quota:
%%
%%   INTERNETDATA_LIVE=1 rebar3 eunit --module=internetdata_live_tests
%%
%% It asserts the shape of an answer without a key, including that `is_vpn' and
%% `location.city' are ABSENT, which is the one claim a stub cannot make honestly,
%% and that a batch without a key is refused.
-module(internetdata_live_tests).

-include_lib("eunit/include/eunit.hrl").

live_test_() ->
    case os:getenv("INTERNETDATA_LIVE") of
        "1" -> {timeout, 60, fun unauthenticated_lookups/0};
        _ -> []
    end.

unauthenticated_lookups() ->
    Client = internetdata:new(),

    {ok, Plain} = internetdata:lookup(Client, <<"1.1.1.1">>),
    ?assertEqual(<<"1.1.1.1">>, maps:get(ip, Plain)),
    ?assertEqual(false, maps:get(is_bogon, Plain)),
    ?assertEqual(true, maps:get(is_anycast, Plain)),
    %% Absent, not false: an answer without a key does not include the VPN flag,
    %% so `maps:find/2' answers `error' where a paid key would answer `{ok, _}'.
    ?assertEqual(error, maps:find(is_vpn, Plain)),
    ?assertEqual(false, maps:get(is_vpn, Plain, false)),
    ?assertEqual(error, maps:find(city, maps:get(location, Plain))),

    {ok, V6} = internetdata:lookup(Client, <<"2606:4700:4700::1111">>),
    ?assertEqual(<<"2606:4700:4700::1111">>, maps:get(ip, V6)),

    {ok, As} = internetdata:lookup_asn(Client, 9009),
    ?assertEqual(9009, maps:get(asn, As)),
    ?assertEqual(error, maps:find(prefixes, As)),

    {ok, Domain} = internetdata:lookup_domain(Client, <<"example.com">>),
    ?assertEqual(<<"example.com">>, maps:get(domain, Domain)),
    ?assertEqual(error, maps:find(dns, Domain)),

    %% A client of its own, so no answer comes from the lookups above.
    Fresh = internetdata:new(),
    Batch = internetdata:lookup_batch(Fresh, [<<"1.1.1.1">>, <<"8.8.8.8">>, <<"10.0.0.1">>]),
    internetdata:close(Fresh),
    ?assertEqual(3, map_size(Batch)),
    ?assertMatch({ok, #{is_bogon := true}}, maps:get(<<"10.0.0.1">>, Batch)),
    %% POST /batch of two or more needs a key on a paid plan, so every address sent to it is refused.
    ?assertMatch({error, #{kind := unauthorized, status := 401}}, maps:get(<<"1.1.1.1">>, Batch)),
    ?assertMatch({error, #{kind := unauthorized, status := 401}}, maps:get(<<"8.8.8.8">>, Batch)),

    internetdata:close(Client).
