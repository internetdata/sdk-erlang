%% Where the integration suite points and what it needs to get there.
-module(staging).

-export([base_url/0, key/0, skip_reason/0, client/0, notice/1, staged/1]).

-define(SECRET, "INTERNETDATA_STAGING_KEY").
-define(DEFAULT_URL, "https://staging.internetdata.io").

%% @doc The API to run against. Overridable so the same suite can be pointed at
%% another environment without a code change.
-spec base_url() -> binary().
base_url() ->
    case string:trim(os:getenv("INTERNETDATA_STAGING_URL", "")) of
        "" -> list_to_binary(?DEFAULT_URL);
        Url -> list_to_binary(Url)
    end.

%% @doc The key, or `undefined' when there is none to present.
%%
%% Actions interpolates a secret that does not exist to an EMPTY STRING rather
%% than leaving the variable unset, and an empty key would be sent as a bearer
%% token of nothing, so every call would 401 and read like a revoked credential.
-spec key() -> binary() | undefined.
key() ->
    case string:trim(os:getenv(?SECRET, "")) of
        "" -> undefined;
        Key -> list_to_binary(Key)
    end.

%% @doc A reason to skip, or `undefined' when the suite can run.
-spec skip_reason() -> string() | undefined.
skip_reason() ->
    case key() of
        undefined -> ?SECRET " is not set, so nothing can be exercised against staging";
        _ -> undefined
    end.

%% @doc A client for staging, and the recorder watching what it sends.
%%
%% The base URL is set through the client's own option, which is what makes that
%% option worth testing at all.
-spec client() -> {internetdata:client(), pid()}.
client() ->
    Key = key(),
    Recorder = staging_recorder:start(Key),
    Client = internetdata:new(#{api_key => Key, base_url => base_url(),
                                http => staging_recorder:http(Recorder)}),
    {Client, Recorder}.

%% @doc Wrap a test body so an absent key skips it with a reason rather than
%% failing it, reported once per test rather than once per run.
-spec staged(fun(() -> any())) -> {timeout, pos_integer(), fun()}.
staged(Body) ->
    {timeout, 300, fun() ->
        case skip_reason() of
            undefined -> Body();
            Reason -> notice("SKIPPED: " ++ Reason)
        end
    end}.

%% @doc Surfaced on the workflow run itself, so a skip is visible without opening
%% the log and reading to the end of it.
-spec notice(string()) -> ok.
notice(Message) ->
    case os:getenv("GITHUB_ACTIONS") of
        "true" -> io:format("::notice title=Integration::~s~n", [Message]);
        _ -> io:format("==> ~s~n", [Message])
    end.
