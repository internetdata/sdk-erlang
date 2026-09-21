%% The published package's `oauth_*' functions against the staging authorization
%% server, on a client built with NO key. Only what is safe to repeat: discovery,
%% a revoke and an exchange of junk, and at most ONE device authorization per run,
%% which nobody approves and which is never polled.
-module(oauth_integration_tests).

-include_lib("eunit/include/eunit.hrl").

%% The one client ID the server holds, already public in the CLI's source.
-define(CLIENT_ID, <<"internetdata-cli">>).
-define(SINCE, [1, 6, 0]).
%% Where staging sends a person to approve a device sign-in.
-define(STAGING_CONSOLE, "https://app-staging.internetdata.io").

metadata_names_the_host_it_was_asked_on_test_() ->
    since(fun(Client) ->
        {ok, Metadata} = internetdata:oauth_metadata(Client),

        ?assertEqual(staging:base_url(), maps:get(issuer, Metadata)),
        ?assert(maps:is_key(device_authorization_endpoint, Metadata)),
        ?assert(lists:member(<<"S256">>, maps:get(code_challenge_methods_supported, Metadata)))
    end).

revoking_junk_succeeds_test_() ->
    since(fun(Client) ->
        ?assertEqual(ok, internetdata:oauth_revoke(Client, ?CLIENT_ID, <<"mo_rt_sdk-ci-not-a-token">>))
    end).

exchanging_an_unknown_device_code_is_an_expired_token_test_() ->
    since(fun(Client) ->
        Junk = <<"mo_dc_sdk-ci-not-a-code">>,
        ?assertMatch({error, #{error_code := <<"expired_token">>, status := 400}},
                     internetdata:oauth_exchange_device_code(Client, ?CLIENT_ID, Junk))
    end).

%% 30 a minute per source address, shared by every SDK's run, so a slow_down is a
%% pass: it is the server answering this request correctly.
one_device_authorization_starts_a_sign_in_test_() ->
    since(fun(Client) ->
        case internetdata:oauth_device_authorization(Client, ?CLIENT_ID, #{scope => <<"account.read">>}) of
            {error, Error} ->
                ?assertMatch(#{error_code := <<"slow_down">>}, Error);
            {ok, Device} ->
                #{device_code := Code, user_code := User, verification_uri := Uri,
                  expires_in := ExpiresIn, interval := Interval} = Device,
                ?assertNotEqual(<<>>, Code),
                ?assertNotEqual(<<>>, User),
                %% The console's, not the apex's: the API is served at the apex here, so
                %% a page taken from the API host would be the landing page's, which a
                %% `/device' suffix alone still passes.
                ?assertEqual(<<?STAGING_CONSOLE "/device">>, Uri),
                ?assert(ExpiresIn > 0),
                ?assert(Interval > 0)
        end
    end).

%% Gated on the INSTALLED version rather than on whether the function exists,
%% which would also skip quietly if one were ever removed.
since(Body) ->
    {timeout, 60, fun() ->
        _ = application:load(internetdata),
        {ok, Vsn} = application:get_key(internetdata, vsn),
        Installed = [list_to_integer(Part) || Part <- string:tokens(Vsn, ".")],
        case Installed >= ?SINCE of
            true ->
                Client = internetdata:new(#{base_url => staging:base_url()}),
                Body(Client);
            false ->
                staging:notice("SKIPPED: the oauth functions arrived in 1.6.0, and " ++ Vsn
                               ++ " is installed")
        end
    end}.
