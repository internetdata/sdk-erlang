%% Asserts the shared conformance corpus that every InternetData SDK asserts.
%%
%% The corpus is generated into testdata/ and is identical across languages, so a
%% behavior that drifts here fails here rather than surfacing as two client
%% libraries quietly disagreeing about the same address or refusal.
-module(internetdata_conformance_tests).

-include_lib("eunit/include/eunit.hrl").

-define(METADATA_PATH, <<"/api/v2/database/metadata">>).
-define(DOWNLOAD_PATH, <<"/api/v2/database/download">>).
-define(LIST_PATH, <<"/api/v2/database/list">>).
-define(LOOKUP_PATH, <<"/1.1.1.1">>).

is_bogon_test_() ->
    [{binary_to_list(<<Ip/binary, " (", Why/binary, ")">>),
      ?_assertEqual(Expect, internetdata:is_bogon(Ip))}
     || #{<<"ip">> := Ip, <<"expect">> := Expect, <<"why">> := Why} <- corpus(<<"isBogon">>)].

%% A server listening on :: sees every IPv4 visitor as ::ffff:a.b.c.d. Read
%% whole that is inside ::ffff:0:0/96, so an SDK that did not unmap answered
%% each one locally as a bogon and never asked.
an_ipv4_mapped_address_is_the_ipv4_address_it_carries_test_() ->
    [{binary_to_list(Ip), fun() -> assert_mapped(C) end}
     || #{<<"ip">> := Ip} = C <- corpus(<<"ipv4Mapped">>)].

assert_mapped(#{<<"ip">> := Ip, <<"carries">> := Carries, <<"expect">> := Expect}) ->
    ?assertEqual(Expect, internetdata:is_bogon(Ip)),
    Stub = internetdata_stub:start(#{Carries => #{body => internetdata_stub:answer(Carries)}}),
    Self = self(),
    Http = fun(Request) ->
        Self ! {sent, maps:get(body, Request, <<>>)},
        (internetdata_stub:http(Stub))(Request)
    end,
    Client = internetdata:new(#{http => Http, retries => 0}),
    {ok, Result} = internetdata:lookup(Client, Ip),
    ?assertEqual(Carries, maps:get(ip, Result)),
    case Expect of
        true ->
            ?assertMatch(#{is_bogon := true}, Result),
            ?assertEqual(0, internetdata_stub:calls(Stub));
        false ->
            ?assertEqual(1, internetdata_stub:calls(Stub)),
            {ok, _} = internetdata:lookup(Client, Carries),
            ?assertEqual(1, internetdata_stub:calls(Stub)),
            %% The mapped form alone: asked beside its plain form, a batch that
            %% sent the address as given would still have been answered for it.
            flush_sent(),
            Batch = internetdata:new(#{http => Http, retries => 0}),
            Got = internetdata:lookup_batch(Batch, [Ip]),
            ?assertEqual([Ip], maps:keys(Got)),
            ?assertMatch({ok, #{ip := Carries}}, maps:get(Ip, Got)),
            ?assertEqual([Carries], sent_ips()),
            internetdata:close(Batch)
    end,
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

flush_sent() ->
    receive {sent, _} -> flush_sent() after 0 -> ok end.

%% The addresses every POST /batch since the flush carried; a GET has no body.
sent_ips() ->
    receive
        {sent, Body} ->
            case iolist_to_binary(Body) of
                <<>> -> sent_ips();
                Json -> maps:get(<<"ips">>, json:decode(Json)) ++ sent_ips()
            end
    after 0 ->
        []
    end.

%% The corpus answer with the address filled in, as the wire would carry it, and
%% every member of it under its atom.
bogon_is_answered_locally_in_the_widest_shape_test() ->
    Stub = internetdata_stub:start(#{}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false}),
    {ok, Result} = internetdata:lookup(Client, <<"10.0.0.1">>),

    #{<<"answer">> := Answer, <<"flagsFalse">> := Flags, <<"emptyObjects">> := Objects,
      <<"emptyLists">> := Lists} = Bogon = corpus(<<"bogonResponse">>),
    Wire = Answer#{<<"ip">> => <<"10.0.0.1">>},
    ?assertEqual(Wire, maps:get(raw, Result)),
    ?assertEqual(true, maps:get(is_bogon, Result)),
    ?assertEqual(<<"10.0.0.1">>, maps:get(ip, Result)),
    ?assertEqual(lists:sort([raw | [atom(K) || K <- maps:keys(Wire)]]), lists:sort(maps:keys(Result))),
    [?assertEqual({F, false}, {F, maps:get(atom(F), Result, missing)}) || F <- Flags],
    [?assertEqual({O, #{}}, {O, maps:get(atom(O), Result, missing)}) || O <- Objects],
    [?assertEqual({L, []}, {L, maps:get(atom(L), Result, missing)}) || L <- Lists],
    [?assertEqual({K, atoms(maps:get(K, Bogon))}, {K, maps:get(atom(K), Result, missing)})
     || K <- [<<"location">>, <<"asn">>, <<"company">>, <<"abuse">>, <<"whois">>, <<"rwhois">>]],
    ?assertEqual(maps:get(<<"hostname">>, Bogon), maps:get(hostname, Result)),
    ?assertEqual(atoms(maps:get(<<"hostedDomains">>, Bogon)), maps:get(hosted_domains, Result)),
    ?assertEqual(0, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

%% Absent means "not in your plan", a paid member inside a shared object
%% included, and is a different answer from present-and-false.
lookup_preserves_absent_versus_false_test_() ->
    [{binary_to_list(Name), fun() -> assert_shape(Case) end}
     || #{<<"name">> := Name} = Case <- corpus(<<"lookup">>)].

assert_shape(#{<<"call">> := Call, <<"target">> := Target, <<"status">> := Status, <<"body">> := Body,
               <<"expect">> := Expect}) ->
    {Path, Lookup} = lookup_call(Call, Target),
    Stub = internetdata_stub:start(#{Path => #{status => Status, body => Body}}),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub)}),
    {ok, Result} = Lookup(Client),

    maps:foreach(fun(K, V) ->
        ?assertEqual({K, V}, {K, maps:get(atom(K), Result, missing)})
    end, maps:get(<<"present">>, Expect)),
    Empty = maps:get(<<"empty">>, Expect),
    [begin
         Got = maps:get(atom(K), Result, missing),
         ?assert(is_map(Got) orelse is_list(Got), K),
         case lists:member(K, Empty) of
             true -> ?assertEqual({K, empty}, {K, emptiness(Got)});
             false -> ?assertEqual({K, decoded(Call, K, maps:get(K, Body))}, {K, Got})
         end
     end || K <- maps:get(<<"objects">>, Expect)],
    %% The whole point of the corpus: a plan-gated member the server did not send
    %% must be ABSENT, which is a different answer from present-and-false.
    [?assertEqual({K, error}, {K, maps:find(atom(K), Result)}) || K <- maps:get(<<"absent">>, Expect)],
    maps:foreach(fun(Obj, Keys) ->
        Got = maps:get(atom(Obj), Result),
        [?assertEqual({Obj, K, error}, {Obj, K, maps:find(atom(K), Got)}) || K <- Keys]
    end, maps:get(<<"absentIn">>, Expect, #{})),
    ?assertEqual(1, internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

lookup_call(<<"lookup">>, Ip) ->
    {Ip, fun(Client) -> internetdata:lookup(Client, Ip) end};
lookup_call(<<"lookupAsn">>, Asn) ->
    {<<"asn/", (integer_to_binary(Asn))/binary>>, fun(Client) -> internetdata:lookup_asn(Client, Asn) end};
lookup_call(<<"lookupDomain">>, Domain) ->
    {<<"domain/", Domain/binary>>, fun(Client) -> internetdata:lookup_domain(Client, Domain) end}.

emptiness(Got) when Got =:= #{}; Got =:= [] -> empty;
emptiness(Got) -> {not_empty, Got}.

%% An AS answer's `whois' is keyed by the registry's own field names, so it is
%% handed back as the wire carried it.
decoded(<<"lookupAsn">>, <<"whois">>, Wire) -> Wire;
decoded(_Call, _Member, Wire) -> atoms(Wire).

%% The wire's names as the atoms the result carries, at every depth.
atoms(Wire) when is_map(Wire) ->
    maps:fold(fun(K, V, Acc) -> Acc#{atom(K) => atoms(V)} end, #{}, Wire);
atoms(Wire) when is_list(Wire) ->
    [atoms(V) || V <- Wire];
atoms(Wire) ->
    Wire.

%% The JSON endpoints and the redirect endpoint classify a refusal through two
%% different handlers, and only one of them was ever going to be exercised by
%% accident. A 404 that reads as a retryable server_error is the specific drift
%% this corpus exists to catch: three of the four VPNDetection SDKs shipped it.
%% Every case runs against a lookup and the database calls alike: a lookup
%% refusal's message is its `error', a database refusal's its `rc'.
errors_are_classified_by_range_and_by_retry_after_test_() ->
    [{binary_to_list(<<Name/binary, " via ", Path/binary>>),
      fun() -> assert_error(Path, Call, Case) end}
     || #{<<"name">> := Name} = Case <- corpus(<<"errors">>),
        {Path, Call} <- [{?LOOKUP_PATH, fun lookup/1}, {?METADATA_PATH, fun metadata/1},
                         {?DOWNLOAD_PATH, fun download_url/1}]].

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
    case maps:find(<<"message">>, Expect) of
        {ok, Message} -> ?assertEqual(Message, maps:get(message, Error));
        error -> ok
    end,
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
    [{binary_to_list(<<Name/binary, " via ", Path/binary>>),
      {timeout, 30, fun() -> assert_attempts(Path, Call, Case) end}}
     || #{<<"name">> := Name} = Case <- corpus(<<"errors">>),
        {Path, Call} <- [{?LOOKUP_PATH, fun lookup/1}, {?METADATA_PATH, fun metadata/1}]].

assert_attempts(Path, Call, #{<<"status">> := Status, <<"headers">> := Headers, <<"body">> := Body,
                              <<"expect">> := Expect}) ->
    Stub = internetdata_stub:start(#{Path => #{status => Status, body => Body, headers => Headers}}),
    %% One retry, and a Retry-After of 2 seconds is honoured, so a rate-limited
    %% case really does wait. That is the corpus's own number.
    Client = client(Stub, #{retries => 1}),
    {error, _} = Call(Client),

    Expected = case maps:get(<<"retryable">>, Expect) of
        true -> 2;
        false -> 1
    end,
    ?assertEqual(Expected, internetdata_stub:calls(Stub)),
    internetdata_stub:stop(Stub).

batch_dedupes_short_circuits_bogons_and_keys_by_address_test() ->
    Expect = batch_expect(<<"dedup-bogon-and-order-free-keying">>),
    Stub = internetdata_stub:start(answers([<<"1.1.1.1">>, <<"8.8.8.8">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub)}),
    Got = internetdata:lookup_batch(Client, batch_input(<<"dedup-bogon-and-order-free-keying">>)),

    %% Erlang maps carry no insertion order, so the claim is the KEY SET: the
    %% deduplicated input, whatever order it was supplied in.
    ?assertEqual(lists:sort(maps:get(<<"keys">>, Expect)), lists:sort(maps:keys(Got))),
    ?assertEqual(maps:get(<<"httpRequests">>, Expect), internetdata_stub:calls(Stub)),
    [?assertMatch({ok, #{is_bogon := true}}, maps:get(K, Got))
     || K <- maps:get(<<"bogonKeys">>, Expect)],
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

one_bad_address_does_not_lose_the_rest_of_the_batch_test() ->
    Expect = batch_expect(<<"partial-failure-does-not-fail-the-batch">>),
    Stub = internetdata_stub:start(answers([<<"1.1.1.1">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), retries => 0}),
    Got = internetdata:lookup_batch(Client, batch_input(<<"partial-failure-does-not-fail-the-batch">>)),

    ?assertEqual(lists:sort(maps:get(<<"keys">>, Expect)), lists:sort(maps:keys(Got))),
    Kinds = maps:get(<<"errorKinds">>, Expect),
    [begin
         {error, #{kind := Kind}} = maps:get(K, Got),
         ?assertEqual(binary_to_atom(maps:get(K, Kinds)), Kind)
     end || K <- maps:get(<<"errorKeys">>, Expect)],
    ?assertMatch({ok, #{is_bogon := false}}, maps:get(<<"1.1.1.1">>, Got)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

cache_hit_issues_no_second_request_test() ->
    Case = case_of(<<"batch">>, <<"cache-hit-issues-no-second-request">>),
    Expect = maps:get(<<"expect">>, Case),
    Stub = internetdata_stub:start(answers([<<"1.1.1.1">>])),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub)}),
    Input = maps:get(<<"input">>, Case),
    [internetdata:lookup_batch(Client, Input) || _ <- lists:seq(1, maps:get(<<"repeat">>, Case))],

    ?assertEqual(maps:get(<<"httpRequests">>, Expect), internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

a_large_batch_is_sent_in_chunks_of_a_thousand_test() ->
    assert_chunked(<<"chunks-of-one-thousand">>).

%% No cap on what one call takes: the chunking is the client's job.
an_uncapped_batch_is_chunked_rather_than_refused_test() ->
    assert_chunked(<<"uncapped-input-is-chunked">>).

assert_chunked(Name) ->
    Input = batch_input(Name),
    Expect = batch_expect(Name),
    Stub = internetdata_stub:start(answers(Input)),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), cache => false}),
    Got = internetdata:lookup_batch(Client, Input),

    ?assertEqual(maps:get(<<"keyCount">>, Expect), map_size(Got)),
    ?assertEqual(maps:get(<<"httpRequests">>, Expect), internetdata_stub:calls(Stub)),
    [?assertMatch({ok, #{ip := Ip}}, maps:get(Ip, Got)) || Ip <- Input],
    internetdata_stub:stop(Stub).

%% A per-entry failure carries no headers, so its 429 can only be a spent
%% allowance, and a 500 is the server's; neither is retried per entry, because
%% retries belong to the call and the call succeeded.
an_entry_error_is_classified_by_its_status_test() ->
    Name = <<"an-entry-error-is-classified-by-its-status">>,
    Expect = batch_expect(Name),
    Stub = internetdata_stub:start((answers([<<"1.1.1.1">>]))#{
        <<"8.8.8.8">> => #{status => 429,
                           body => #{<<"error">> => <<"overage cap reached; raise or remove it in Billing">>}},
        <<"9.9.9.9">> => #{status => 500, body => #{<<"error">> => <<"lookup failed">>}}
    }),
    Client = internetdata:new(#{http => internetdata_stub:http(Stub), retries => 3}),
    Got = internetdata:lookup_batch(Client, batch_input(Name)),

    ?assertEqual(lists:sort(maps:get(<<"keys">>, Expect)), lists:sort(maps:keys(Got))),
    [begin
         {error, #{kind := Kind}} = maps:get(K, Got),
         ?assertEqual(binary_to_atom(V), Kind)
     end || K := V <- maps:get(<<"errorKinds">>, Expect)],
    ?assertEqual(maps:get(<<"httpRequests">>, Expect), internetdata_stub:calls(Stub)),
    internetdata:close(Client),
    internetdata_stub:stop(Stub).

answers(Ips) ->
    maps:from_list([{Ip, #{body => internetdata_stub:answer(Ip)}} || Ip <- Ips]).

case_of(Section, Name) ->
    [Case] = [C || #{<<"name">> := N} = C <- corpus(Section), N =:= Name],
    Case.

batch_expect(Name) ->
    maps:get(<<"expect">>, case_of(<<"batch">>, Name)).

batch_input(Name) ->
    maps:get(<<"input">>, case_of(<<"batch">>, Name)).

%% `standing' and `license_type' are documented as open sets. A client that
%% narrowed either into a closed type would drop a value added later, and the
%% dropped one is always the interesting one.
every_standing_and_license_type_survives_the_mapper_test() ->
    Standings = corpus(<<"standings">>),
    %% `null' belongs in the sweep: it is what license_type is when there is no
    %% license at all, which is the commonest value in a real listing.
    LicenseTypes = [null | corpus(<<"license_type">>)],
    Wire = [family(<<Standing/binary, "_", (label(LicenseType))/binary>>,
                   Standing, LicenseType)
            || Standing <- Standings, LicenseType <- LicenseTypes],
    Stub = internetdata_stub:start(#{?LIST_PATH => #{body => #{<<"databases">> => Wire}}}),
    Client = client(Stub, #{}),

    {ok, Databases} = internetdata:database_list(Client),

    ?assertEqual(length(Wire), length(Databases)),
    ?assertEqual(lists:usort(Standings),
                 lists:usort([maps:get(standing, D) || D <- Databases])),
    ?assertEqual(lists:usort(LicenseTypes),
                 lists:usort([maps:get(license_type, D) || D <- Databases])),
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
label(LicenseType) -> LicenseType.

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
            family(<<"a_family_named_only_by_the_server">>, <<"licensed">>, <<"standard">>)],
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
        [family(<<"vpn_ip">>, <<"licensed">>, <<"standard">>)]}}}),
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

family(Base, Standing, LicenseType) ->
    #{
        <<"base">> => Base,
        <<"name">> => Base,
        <<"summary">> => <<"a family">>,
        <<"standing">> => Standing,
        <<"open">> => false,
        <<"license_type">> => LicenseType,
        <<"starts">> => null,
        <<"expires">> => null,
        <<"versions">> => [#{<<"id">> => <<Base/binary, "_v1">>, <<"version">> => 1,
                             <<"summary">> => <<"v1">>, <<"formats">> => [<<"csvgz">>]}]
    }.

lookup(Client) ->
    internetdata:lookup(Client, <<"1.1.1.1">>).

metadata(Client) ->
    internetdata:database_metadata(Client, <<"bogon_ip_v1">>).

download_url(Client) ->
    internetdata:database_download_url(Client, <<"bogon_ip_v1">>, csvgz).

client(Stub, Options) ->
    internetdata:new(Options#{api_key => <<"k">>, http => internetdata_stub:http(Stub), cache => false}).

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
