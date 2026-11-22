%% A spent trial's or a reached cap's answer ends with a new UTC month or a raised
%% cap, so it is cached for a minute at most rather than for the client's TTL.
-module(internetdata_cache_life_tests).

-include_lib("eunit/include/eunit.hrl").

flags() ->
    #{<<"45.83.91.1">> => #{},
      <<"45.83.91.2">> => #{<<"trial_expired">> => false, <<"cap_reached">> => false},
      <<"45.83.91.3">> => #{<<"trial_expired">> => true},
      <<"45.83.91.4">> => #{<<"cap_reached">> => true}}.

cases() ->
    [{<<"45.83.91.1">>, 3600, 3600},
     {<<"45.83.91.2">>, 3600, 3600},
     {<<"45.83.91.3">>, 3600, 60},
     {<<"45.83.91.4">>, 3600, 60},
     {<<"45.83.91.3">>, 5, 5},
     {<<"45.83.91.4">>, 5, 5},
     {<<"45.83.91.1">>, 5, 5}].

stub() ->
    Routes = maps:fold(fun(Ip, Flags, Acc) ->
                           Acc#{<<"/", Ip/binary>> => #{body => maps:merge(internetdata_stub:answer(Ip), Flags)}}
                       end, #{}, flags()),
    internetdata_stub:start(Routes).

each_looked_up_answer_is_cached_as_long_as_its_flags_allow_test() ->
    assert_lives(fun(Client, Ip) -> {ok, _} = internetdata:lookup(Client, Ip) end).

each_batch_entry_is_cached_as_long_as_its_flags_allow_test() ->
    assert_lives(fun(Client, Ip) -> #{Ip := {ok, _}} = internetdata:lookup_batch(Client, [Ip, <<"45.83.91.1">>]) end).

a_reduced_answer_is_still_cached_so_a_repeat_sends_nothing_test() ->
    Stub = stub(),
    Client = internetdata:new(#{api_key => <<"k">>, http => internetdata_stub:http(Stub)}),
    {ok, _} = internetdata:lookup(Client, <<"45.83.91.3">>),
    {ok, Again} = internetdata:lookup(Client, <<"45.83.91.3">>),
    ?assertMatch(#{trial_expired := true}, Again),
    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

assert_lives(Call) ->
    Stub = stub(),
    lists:foreach(
        fun({Ip, TtlS, WantS}) ->
            Client = internetdata:new(#{api_key => <<"k">>, http => internetdata_stub:http(Stub),
                                        cache => #{max => 100, ttl_ms => TtlS * 1000}}),
            Before = erlang:monotonic_time(millisecond),
            Call(Client, Ip),
            After = erlang:monotonic_time(millisecond),
            #{cache := #{entries := Entries}} = Client,
            [{Ip, _Result, ExpiresAt, _Seq}] = ets:lookup(Entries, Ip),
            Label = {Ip, TtlS},
            ?assertEqual({Label, true}, {Label, ExpiresAt >= Before + WantS * 1000}),
            ?assertEqual({Label, true}, {Label, ExpiresAt =< After + WantS * 1000}),
            internetdata:close(Client)
        end, cases()),
    internetdata_stub:stop(Stub).
