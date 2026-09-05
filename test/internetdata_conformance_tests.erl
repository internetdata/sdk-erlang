%% Asserts the shared conformance corpus that every InternetData SDK asserts.
%%
%% The corpus is generated into testdata/ and is identical across languages, so a
%% behavior that drifts here fails here rather than surfacing as two client
%% libraries quietly disagreeing about the same refusal.
-module(internetdata_conformance_tests).

-include_lib("eunit/include/eunit.hrl").

-define(METADATA_PATH, <<"/api/v2/database/metadata">>).
-define(DOWNLOAD_PATH, <<"/api/v2/database/download">>).
-define(LIST_PATH, <<"/api/v2/database/list">>).

%% The JSON endpoints and the redirect endpoint classify a refusal through two
%% different handlers, and only one of them was ever going to be exercised by
%% accident. A 404 that reads as a retryable server_error is the specific drift
%% this corpus exists to catch: three of the four VPNDetection SDKs shipped it.
errors_are_classified_by_range_and_by_retry_after_test_() ->
    [{binary_to_list(<<Name/binary, " via ", Path/binary>>),
      fun() -> assert_error(Path, Call, Case) end}
     || #{<<"name">> := Name} = Case <- corpus(<<"errors">>),
        {Path, Call} <- [{?METADATA_PATH, fun metadata/1}, {?DOWNLOAD_PATH, fun download_url/1}]].

assert_error(Path, Call, #{<<"status">> := Status, <<"headers">> := Headers,
                           <<"body">> := Body, <<"expect">> := Expect}) ->
    Stub = internetdata_stub:start(#{Path => #{status => Status, body => Body,
                                              headers => Headers}}),
    %% No retries, so a retryable failure still surfaces rather than looping.
    Client = client(Stub, #{retries => 0}),
    {error, Error} = Call(Client),

    ?assertEqual(atom(maps:get(<<"kind">>, Expect)), maps:get(kind, Error)),
    ?assertEqual(maps:get(<<"retryable">>, Expect), maps:get(retryable, Error)),
    ?assertEqual(Status, maps:get(status, Error)),
    ?assertEqual(maps:get(<<"message">>, Expect), maps:get(message, Error)),
    case maps:find(<<"retryAfterSeconds">>, Expect) of
        {ok, Seconds} -> ?assertEqual(Seconds, maps:get(retry_after, Error));
        error -> ?assertEqual(error, maps:find(retry_after, Error))
    end,
    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% Only a retryable failure is ever tried again, and it is tried against the same
%% request rather than abandoned. Pinned here because the retry rule and the
%% classification are the same decision read twice.
only_a_retryable_failure_is_attempted_again_test_() ->
    [{binary_to_list(Name), fun() -> assert_attempts(Case) end}
     || #{<<"name">> := Name} = Case <- corpus(<<"errors">>)].

assert_attempts(#{<<"status">> := Status, <<"headers">> := Headers, <<"body">> := Body,
                  <<"expect">> := Expect}) ->
    Stub = internetdata_stub:start(#{?METADATA_PATH => #{status => Status, body => Body,
                                                        headers => Headers}}),
    %% One retry, and a Retry-After of 2 seconds is honoured, so a rate-limited
    %% case really does wait. That is the corpus's own number.
    Client = client(Stub, #{retries => 1}),
    {error, _} = metadata(Client),

    Expected = case maps:get(<<"retryable">>, Expect) of
        true -> 2;
        false -> 1
    end,
    ?assertEqual(Expected, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% `standing' and `redistribution' are documented as open sets. A client that
%% narrowed either into a closed type would drop a value added later, and the
%% dropped one is always the interesting one.
every_standing_and_redistribution_survives_the_mapper_test() ->
    Standings = corpus(<<"standings">>),
    %% `null' belongs in the sweep: it is what redistribution is when there is no
    %% license at all, which is the commonest value in a real listing.
    Redistributions = [null | corpus(<<"redistribution">>)],
    Wire = [family(<<Standing/binary, "_", (label(Redistribution))/binary>>,
                   Standing, Redistribution)
            || Standing <- Standings, Redistribution <- Redistributions],
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => Wire}}}),
    Client = client(Stub, #{}),

    {ok, Databases} = internetdata:database_list(Client),

    ?assertEqual(length(Wire), length(Databases)),
    ?assertEqual(lists:usort(Standings),
                 lists:usort([maps:get(standing, D) || D <- Databases])),
    ?assertEqual(lists:usort(Redistributions),
                 lists:usort([maps:get(redistribution, D) || D <- Databases])),
    internetdata_stub:stop(Stub).

every_format_reaches_the_wire_as_written_test_() ->
    [{binary_to_list(Format), fun() -> assert_format(Format) end}
     || Format <- corpus(<<"formats">>)].

assert_format(Format) ->
    Stub = internetdata_stub:start(#{?DOWNLOAD_PATH => #{status => 302,
                                                        headers => #{<<"Location">> => <<"http://s/f">>}}}),
    Client = client(Stub, #{}),

    ?assertEqual({ok, <<"http://s/f">>},
                 internetdata:database_download_url(Client, <<"bogon_ip_v1">>, format(Format))),
    internetdata_stub:stop(Stub).

%% Written out rather than derived through `binary_to_existing_atom', so a format
%% the corpus gains that this client has no name for fails here loudly instead of
%% resolving to whatever atom some unrelated module happened to define.
format(<<"csvgz">>) -> csvgz;
format(<<"mmdb">>) -> mmdb.

label(null) -> <<"none">>;
label(Redistribution) -> Redistribution.

%% A `private' dataset is ABSENT from a listing for an organization with no grant
%% on it, rather than present with an `unlicensed' standing. The server decides
%% that; the corpus states what the CLIENT must therefore never do, and this is
%% the map from each of those rules to the test that holds it. Comparing the sets
%% means a rule added to the corpus fails here until it is covered, rather than
%% passing unnoticed as prose.
every_visibility_rule_is_covered_test() ->
    #{<<"clientRules">> := Rules} = corpus(<<"visibility">>),
    ?assertEqual(lists:sort(Rules), lists:sort(maps:keys(visibility_rules()))).

visibility_rules() ->
    #{
        <<"listing-is-returned-as-served">> => fun a_listing_is_returned_as_served/0,
        <<"no-catalog-is-compiled-into-the-client">> => fun no_catalog_is_compiled_in/0,
        <<"a-listing-is-never-reused-across-clients">> => fun a_listing_is_not_reused/0
    }.

visibility_test_() ->
    [{binary_to_list(Rule), Body} || Rule := Body <- visibility_rules()].

%% What comes back is the set the server sent: nothing dropped, nothing added, and
%% a base this library has never heard of carried through untouched.
a_listing_is_returned_as_served() ->
    Wire = [family(<<"bogon_ip">>, <<"licensed">>, <<"redistribute">>),
            family(<<"vpn_ip">>, <<"unlicensed">>, null),
            family(<<"a_family_named_only_by_the_server">>, <<"licensed">>, <<"internal">>)],
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => Wire}}}),
    Client = client(Stub, #{}),

    {ok, Databases} = internetdata:database_list(Client),

    ?assertEqual([maps:get(<<"base">>, F) || F <- Wire], [maps:get(base, D) || D <- Databases]),
    internetdata_stub:stop(Stub).

%% An empty catalog is an answer, not a signal to fall back on something built
%% in. A client carrying its own list would have somewhere to fall back TO.
no_catalog_is_compiled_in() ->
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => []}}}),
    Client = client(Stub, #{}),

    ?assertEqual({ok, []}, internetdata:database_list(Client)),
    internetdata_stub:stop(Stub).

%% Two keys are two organizations and therefore two catalogs. Nothing is cached
%% between clients, and nothing is cached within one either: a second call asks
%% again rather than replaying the first answer under a key that may no longer be
%% entitled to it.
a_listing_is_not_reused() ->
    OneStub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> =>
        [family(<<"bogon_ip">>, <<"licensed">>, <<"redistribute">>)]}}}),
    TwoStub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> =>
        [family(<<"vpn_ip">>, <<"licensed">>, <<"internal">>)]}}}),
    One = client(OneStub, #{}),
    Two = client(TwoStub, #{}),

    {ok, [First]} = internetdata:database_list(One),
    {ok, [Second]} = internetdata:database_list(Two),
    {ok, [Again]} = internetdata:database_list(One),

    ?assertEqual(<<"bogon_ip">>, maps:get(base, First)),
    ?assertEqual(<<"vpn_ip">>, maps:get(base, Second)),
    ?assertEqual(<<"bogon_ip">>, maps:get(base, Again)),
    ?assertEqual(2, internetdata_stub:calls(OneStub)),
    ?assertEqual(1, internetdata_stub:calls(TwoStub)),
    internetdata_stub:stop(OneStub),
    internetdata_stub:stop(TwoStub).

family(Base, Standing, Redistribution) ->
    #{
        <<"base">> => Base,
        <<"name">> => Base,
        <<"summary">> => <<"a family">>,
        <<"standing">> => Standing,
        <<"redistribution">> => Redistribution,
        <<"starts">> => null,
        <<"expires">> => null,
        <<"versions">> => [#{<<"id">> => <<Base/binary, "_v1">>, <<"version">> => 1,
                             <<"summary">> => <<"v1">>, <<"formats">> => [<<"csvgz">>]}]
    }.

metadata(Client) ->
    internetdata:database_metadata(Client, <<"bogon_ip_v1">>).

download_url(Client) ->
    internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz).

client(Stub, Options) ->
    internetdata:new(Options#{api_key => <<"k">>, http => internetdata_stub:http(Stub)}).

corpus(Key) ->
    maps:get(Key, testdata()).

testdata() ->
    {ok, Raw} = file:read_file(testdata_path()),
    json:decode(Raw).

%% rebar3 runs from the project root, but a bare eunit run from anywhere else
%% would not, so fall back to walking up from the built application.
testdata_path() ->
    case filelib:is_regular("testdata/testdata.json") of
        true ->
            "testdata/testdata.json";
        false ->
            filename:join([code:lib_dir(internetdata), "..", "..", "..", "..",
                           "testdata", "testdata.json"])
    end.

%% The corpus names things the way the wire does. Turning one into the atom the
%% library uses is an existing-atom lookup on purpose: a corpus name the library
%% never mentions must fail loudly rather than quietly assert nothing. Loading is
%% forced because an atom only exists once the module carrying it as a literal
%% has been loaded.
atom(Name) ->
    _ = code:ensure_loaded(internetdata_result),
    _ = code:ensure_loaded(internetdata_error),
    _ = code:ensure_loaded(internetdata),
    binary_to_existing_atom(Name).
