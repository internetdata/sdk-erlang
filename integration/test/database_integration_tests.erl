%% The suite proper, against a real staging API and a real presigned transfer.
%%
%% Nothing here NAMES a database. The listing supplies both targets - the
%% smallest licensed artifact to transfer, and an unlicensed one to be refused -
%% because a written-in id goes stale the day a license changes, and deriving
%% them exercises `standing' as a side effect.
%%
%% Every transfer is budgeted before it starts. Metadata publishes a size per
%% format, and that size is checked against the ceiling below FIRST, so nothing
%% can quietly pull one of the multi-gigabyte databases through CI.
-module(database_integration_tests).

-include_lib("eunit/include/eunit.hrl").

%% 8 MiB. The smallest published artifacts are a few hundred bytes, so this is
%% four orders of magnitude of headroom: tripping it means the suite is pointed
%% somewhere unintended, which is exactly when a transfer must not go ahead.
-define(CEILING, 8 * 1024 * 1024).

the_catalog_answers_the_family_shape_test_() ->
    staging:staged(fun() ->
        {Client, Recorder} = staging:client(),

        {ok, Families} = internetdata:database_list(Client),

        ?assertNotEqual([], Families),
        %% The key really was presented. Every endpoint here is authenticated, so
        %% a client that never sent it could not have got this far - but the
        %% check costs nothing and names the failure precisely if it ever can.
        ?assert(staging_recorder:carried_key(Recorder), "the key never reached the wire"),
        [assert_family(F) || F <- Families],
        %% Licensed for nothing is a broken credential rather than a license
        %% decision, so it FAILS here rather than skipping everything below.
        Licensed = licensed(Families),
        ?assertNotEqual([], Licensed, "the key is licensed for nothing at all"),
        io:format("~b families, ~b licensed: ~s~n",
                  [length(Families), length(Licensed),
                   lists:join(", ", [binary_to_list(maps:get(base, F)) || F <- Licensed])]),
        done(Client, Recorder)
    end).

assert_family(Family) ->
    Base = maps:get(base, Family, missing),
    ?assert(is_binary(Base) andalso Base =/= <<>>),
    ?assert(is_binary(maps:get(name, Family, missing))),
    ?assert(lists:member(maps:get(standing, Family, missing),
                         [<<"licensed">>, <<"expired">>, <<"unlicensed">>])),
    ?assert(lists:member(maps:get(redistribution, Family, missing),
                         [null, <<"evaluation">>, <<"internal">>, <<"redistribute">>])),
    Versions = maps:get(versions, Family, []),
    ?assertNotEqual({Base, []}, {Base, Versions}),
    [begin
         ?assert(is_binary(maps:get(id, V, missing))),
         ?assert(is_integer(maps:get(version, V, missing))),
         %% The id and the formats live on the VERSION. A family carrying them
         %% itself would leave `database_list/1' unable to tell a caller what to
         %% download at all.
         ?assertNotEqual({Base, []}, {Base, maps:get(formats, V, [])})
     end || V <- Versions].

%% A license refusal names itself in `rc'. Falling back to the status means the
%% client never read the envelope, and the caller cannot tell "never bought this"
%% from "your term lapsed" without asking us.
a_database_the_organization_does_not_license_is_refused_cleanly_test_() ->
    staging:staged(fun() ->
        {Client, Recorder} = staging:client(),
        {ok, Families} = internetdata:database_list(Client),
        case artifacts([F || F <- Families, maps:get(standing, F) =/= <<"licensed">>]) of
            [] ->
                staging:notice("SKIPPED: every listed family is licensed, so there is no "
                               "refusal to observe");
            [{Id, Format} | _] ->
                Before = staging_recorder:requests(Recorder),
                Result = internetdata:database_download_url(Client, Id, Format),

                ?assertMatch({error, #{kind := forbidden, status := 403, retryable := false}},
                             Result),
                {error, #{message := Message}} = Result,
                ?assert(lists:member(Message, [<<"NOT_LICENSED">>, <<"LICENSE_EXPIRED">>]),
                        binary_to_list(<<"the refusal did not carry the API's rc: ",
                                         Message/binary>>)),
                %% A 4xx is a client error. Two requests here would mean the
                %% classifier fell through to the retryable default.
                ?assertEqual(1, staging_recorder:requests(Recorder) - Before)
        end,
        done(Client, Recorder)
    end).

a_database_is_streamed_to_disk_and_matches_its_published_digest_test_() ->
    transferred(fun(#{written := Written, path := Path, checksums := Sums}) ->
        ?assert(Written > 0),
        ?assertEqual({ok, Written}, file_size(Path)),
        %% The working file is gone, so nothing half-written can be mistaken for
        %% a database by whatever reads the directory next.
        ?assertEqual(false, filelib:is_file(<<Path/binary, ".part">>)),
        {ok, Body} = file:read_file(Path),

        %% Unwrapped past the `checksums' envelope. Reading a top-level `sha256'
        %% returns nothing against a perfectly healthy API, which is how another
        %% binding shipped this broken.
        Sha256 = maps:get(sha256, Sums, missing),
        ?assertMatch(<<_:64/binary>>, Sha256),
        ?assertEqual(Sha256, digest(Body))
    end).

the_bytes_variant_agrees_with_the_streamed_copy_test_() ->
    transferred(fun(#{written := Written, checksums := Sums, id := Id, format := Format}) ->
        {Client, Recorder} = staging:client(),

        {ok, Bytes} = internetdata:database_download_bytes(Client, Id, Format),

        ?assertEqual(Written, byte_size(Bytes)),
        ?assertEqual(maps:get(sha256, Sums, missing), digest(Bytes)),
        done(Client, Recorder)
    end).

%% The presigned URL authorizes itself, so the request that follows the 302 must
%% carry no credential. The mistake is invisible from the client side: the
%% transfer succeeds either way, and the key is simply gone.
no_credential_is_sent_to_object_storage_test_() ->
    transferred(fun(#{facts := Facts}) ->
        Staging = staging:base_url(),

        Storage = [F || #{origin := Origin} = F <- Facts, Origin =/= Staging],
        ?assertNotEqual([], Storage),
        [?assertEqual({Origin, false}, {Origin, Carried})
         || #{origin := Origin, carried_key := Carried} <- Storage],
        %% And the API half did present it, so the check above is about where the
        %% key went rather than about a client that never had one.
        ?assert(lists:any(fun(#{origin := O, carried_key := C}) -> O =:= Staging andalso C end,
                          Facts))
    end).

%% Every attempt lands in the history, so the transfer this suite just made is
%% there to find. Matched by dataset id rather than by position: another run
%% against the same organization is free to be interleaved with this one.
the_history_records_the_transfer_that_just_happened_test_() ->
    transferred(fun(#{id := Id}) ->
        {Client, Recorder} = staging:client(),

        {ok, Attempts} = internetdata:database_downloads(Client, #{limit => 50}),

        [?assert(lists:member(maps:get(outcome, A),
                              [<<"ok">>, <<"unauthorized">>, <<"denied">>, <<"expired">>,
                               <<"unknown">>, <<"unavailable">>]))
         || A <- Attempts],
        Ours = [A || A <- Attempts, maps:get(dataset_id, A) =:= Id,
                     maps:get(outcome, A) =:= <<"ok">>],
        ?assertNotEqual([], Ours),
        done(Client, Recorder)
    end).

%% Wraps a test in the shared transfer, and turns "nothing licensed is small
%% enough" into a skip: that is a license decision rather than a fault, while a
%% credential licensed for nothing already failed in the catalog test above.
transferred(Body) ->
    staging:staged(fun() ->
        case transfer() of
            {ok, Transferred} -> Body(Transferred);
            {skip, Reason} -> staging:notice("SKIPPED: " ++ Reason)
        end
    end).

%% One transfer for the whole run, in `persistent_term' because each eunit test
%% runs in a process of its own and the file has to outlive whichever one asked
%% for it first.
transfer() ->
    case persistent_term:get({?MODULE, transfer}, undefined) of
        undefined ->
            Transferred = fetch(),
            persistent_term:put({?MODULE, transfer}, Transferred),
            Transferred;
        Transferred ->
            Transferred
    end.

fetch() ->
    {Client, Recorder} = staging:client(),
    {ok, Families} = internetdata:database_list(Client),
    Sized = sized(Client, artifacts(licensed(Families))),
    case [S || {Size, _, _} = S <- Sized, Size > 0, Size =< ?CEILING] of
        [] ->
            done(Client, Recorder),
            {skip, lists:flatten(io_lib:format("nothing licensed is under the ~b byte ceiling",
                                               [?CEILING]))};
        Affordable ->
            {Size, Id, Format} = lists:min(Affordable),
            Path = scratch(Id),
            {ok, Written} = internetdata:database_download(Client, Id, Format, Path),
            %% Read AFTER the transfer, so a rebuild between the two calls shows
            %% up as a digest mismatch rather than passing against a digest of
            %% nothing.
            {ok, Sums} = internetdata:database_checksums(Client, Id, Format),
            io:format("~s.~s: ~b bytes, metadata says ~b~n", [Id, Format, Written, Size]),
            Facts = staging_recorder:facts(Recorder),
            done(Client, Recorder),
            {ok, #{id => Id, format => Format, written => Written, path => Path,
                   checksums => Sums, facts => Facts}}
    end.

%% Metadata carries a size per format, which is what makes budgeting possible at
%% all: the smallest artifact is chosen from what the API publishes rather than
%% from anything written down here.
sized(Client, Artifacts) ->
    [{size_of(Client, Id, Format), Id, Format} || {Id, Format} <- Artifacts].

size_of(Client, Id, Format) ->
    case internetdata:database_metadata(Client, Id) of
        {ok, Metadata} ->
            ?assertEqual(Id, maps:get(id, Metadata, missing)),
            %% Keyed by format, and formats are the server's list, so this key is
            %% a binary rather than an atom - the one place that rule is visible
            %% to a caller.
            maps:get(atom_to_binary(Format), maps:get(size, Metadata, #{}), 0);
        {error, _} ->
            0
    end.

licensed(Families) ->
    [F || F <- Families, maps:get(standing, F) =:= <<"licensed">>].

artifacts(Families) ->
    [{maps:get(id, V), format(Wire)}
     || F <- Families, V <- maps:get(versions, F, []),
        Wire <- maps:get(formats, V, []), format(Wire) =/= undefined].

format(<<"csvgz">>) -> csvgz;
format(<<"mmdb">>) -> mmdb;
%% A format the published spec has gained since this client was built. Skipping
%% it beats crashing a suite whose subject is something else entirely.
format(_Other) -> undefined.

done(_Client, Recorder) ->
    staging_recorder:stop(Recorder).

digest(Body) ->
    Hex = [io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Body)],
    iolist_to_binary(Hex).

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> {ok, element(2, Info)};
        Error -> Error
    end.

scratch(Id) ->
    Dir = list_to_binary(os:getenv("TMPDIR", "/tmp")),
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    <<Dir/binary, "/internetdata-integration-", Unique/binary, "-", Id/binary>>.
