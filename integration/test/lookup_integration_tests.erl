%% The published package looking addresses, an AS and a domain up, keyless
%% against production and staging, and with the staging key where there is one.
%%
%% Nothing here pins a field COUNT or a value a dataset could change. What a
%% served answer must satisfy on any plan: the members the spec requires, a
%% plan-gated member ABSENT rather than false when the plan leaves it out, and a
%% key's answer carrying at least what a keyless one does.
-module(lookup_integration_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SINCE, [1, 13, 0]).
%% Cloudflare's resolver: stable, and on every plan an anycast address.
-define(PROBE, <<"1.1.1.1">>).
-define(OTHER, <<"8.8.8.8">>).

a_lookup_without_a_key_answers_unlimiteds_shape_test_() ->
    each_env(fun(Env) ->
        {Client, Recorder} = keyless(Env),

        {ok, Result} = internetdata:lookup(Client, ?PROBE),

        ?assertEqual(?PROBE, maps:get(ip, Result)),
        ?assertEqual(false, maps:get(is_bogon, Result)),
        ?assert(is_boolean(maps:get(is_anycast, Result))),
        [?assert(is_map(maps:get(Object, Result))) || Object <- [tor, relay, location, asn, company, abuse]],
        %% Absent, not false: Unlimited leaves the VPN flag and the city out, so
        %% `maps:find/2' answers `error' where a paid key's answer has them.
        ?assertEqual(error, maps:find(is_vpn, Result)),
        ?assertEqual(error, maps:find(city, maps:get(location, Result))),
        ?assertNot(staging_recorder:carried_key(Recorder)),
        ?assertEqual([<<"/", ?PROBE/binary>>], staging_recorder:paths(Recorder)),
        done(Client, Recorder)
    end).

an_as_and_a_domain_are_looked_up_without_a_key_test_() ->
    each_env(fun(Env) ->
        {Client, Recorder} = keyless(Env),

        {ok, As} = internetdata:lookup_asn(Client, 9009),
        {ok, Domain} = internetdata:lookup_domain(Client, <<"example.com">>),

        ?assertEqual(9009, maps:get(asn, As)),
        ?assert(is_binary(maps:get(registry, As))),
        ?assertEqual(error, maps:find(prefixes, As)),
        ?assertEqual(<<"example.com">>, maps:get(domain, Domain)),
        ?assert(is_boolean(maps:get(has_mx, Domain))),
        ?assertEqual(error, maps:find(dns, Domain)),
        ?assertEqual([<<"/asn/9009">>, <<"/domain/example.com">>], staging_recorder:paths(Recorder)),
        done(Client, Recorder)
    end).

my_ip_answers_the_calling_address_test_() ->
    each_env(fun(Env) ->
        {Client, Recorder} = keyless(Env),

        {ok, Result} = internetdata:my_ip(Client),

        ?assert(is_binary(maps:get(ip, Result))),
        ?assertEqual(false, maps:get(is_bogon, Result)),
        done(Client, Recorder)
    end).

a_batch_without_a_key_is_refused_once_and_its_bogon_still_answered_test_() ->
    each_env(fun(Env) ->
        {Client, Recorder} = keyless(Env),

        %% Two addresses on the wire: a keyless batch of one is answered as its lookup.
        Got = internetdata:lookup_batch(Client, [?PROBE, ?OTHER, <<"10.0.0.1">>]),

        ?assertMatch({ok, #{is_bogon := true}}, maps:get(<<"10.0.0.1">>, Got)),
        [?assertMatch({Ip, {error, #{kind := unauthorized, status := 401, retryable := false}}},
                      {Ip, maps:get(Ip, Got)})
         || Ip <- [?PROBE, ?OTHER]],
        %% One request, never retried.
        ?assertEqual(1, staging_recorder:requests(Recorder)),
        ?assertEqual([<<"/batch">>], staging_recorder:paths(Recorder)),
        ?assertEqual(lists:sort([?PROBE, ?OTHER]), staging_recorder:batch_ips(Recorder)),
        done(Client, Recorder)
    end).

a_bogon_is_answered_without_touching_the_network_test_() ->
    since(fun() ->
        Refusing = fun(_Request) -> {error, the_bogon_path_reached_the_network} end,
        Client = internetdata:new(#{base_url => staging:base_url(), http => Refusing}),

        {ok, Result} = internetdata:lookup(Client, <<"10.0.0.1">>),

        ?assertEqual(true, maps:get(is_bogon, Result)),
        ?assertEqual(false, maps:get(is_vpn, Result)),
        ?assertEqual(#{}, maps:get(vpn, Result)),
        ?assert(internetdata:is_bogon(Client, <<"10.0.0.1">>)),
        internetdata:close(Client)
    end).

%% The key is asserted on the wire before anything is compared: an unsent key
%% answers the keyless shape, which contains the keyless shape vacuously.
a_key_reaches_the_wire_and_answers_at_least_the_keyless_shape_test_() ->
    since(fun() ->
        case staging:skip_reason() of
            undefined -> keyed();
            Reason -> staging:notice("SKIPPED: " ++ Reason)
        end
    end).

keyed() ->
    {Client, Recorder} = staging:client(),
    {Keyless, KeylessRecorder} = keyless(staging:base_url()),

    {ok, Answer} = internetdata:lookup(Client, ?PROBE),
    ?assert(staging_recorder:carried_key(Recorder), "the key never reached the wire"),
    {ok, Unlimited} = internetdata:lookup(Keyless, ?PROBE),
    {ok, Entitlement} = internetdata:my_entitlement(Client),

    Keys = wire_keys(Answer),
    [?assert(lists:member(Key, Keys), binary_to_list(<<"the key's answer drops ", Key/binary>>))
     || Key <- wire_keys(Unlimited)],
    ?assertMatch(#{plan := #{key := _, tier := _}, usage := #{requests := _}}, Entitlement),
    done(Client, Recorder),
    done(Keyless, KeylessRecorder).

%% trial_expired marks a free-plan key's answers, and no other: it is not a field
%% a plan serves.
wire_keys(#{raw := Raw}) ->
    lists:sort(maps:keys(Raw)) -- [<<"trial_expired">>].

each_env(Body) ->
    [{binary_to_list(Env), since(fun() -> Body(Env) end)} || Env <- [staging:prod(), staging:base_url()]].

keyless(Env) ->
    Recorder = staging_recorder:start(undefined),
    {internetdata:new(#{base_url => Env, http => staging_recorder:http(Recorder)}), Recorder}.

done(Client, Recorder) ->
    internetdata:close(Client),
    staging_recorder:stop(Recorder).

%% Gated on the INSTALLED version rather than on whether the function exists,
%% which would also skip quietly if one were ever removed.
since(Body) ->
    {timeout, 60, fun() ->
        case staging:installed() >= ?SINCE of
            true -> Body();
            false -> staging:notice("SKIPPED: the lookups arrived in 1.13.0, and an older release is installed")
        end
    end}.
