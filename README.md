# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="28"/>](https://internetdata.io/) InternetData Erlang Client Library

[![hex.pm](https://img.shields.io/hexpm/v/internetdata.svg)](https://hex.pm/packages/internetdata)
[![license](https://img.shields.io/hexpm/l/internetdata.svg)](LICENSE)

The official Erlang client library for the [InternetData](https://internetdata.io) API.

It tells you what every database InternetData publishes says about an IP address, an AS or a domain, and downloads the databases your organization licenses.

## Getting Started

```erlang
%% rebar.config
{deps, [internetdata]}.
```

Requires Erlang/OTP 27 or newer. There are no runtime dependencies: everything the client needs is in OTP. From Elixir, add `{:internetdata, "~> 1.14"}` to your `mix.exs` deps and call it as `:internetdata`.

## Usage

**No API key needed to start.** Unlimited, the free plan, answers `ip`, `is_bogon`, Tor and relay detection, country-level `location`, `asn`, `is_anycast`, `is_carrier`, `is_satellite`, the five service flags, the reverse-DNS `hostname`, the company's name and domain and the abuse email, with no daily or monthly cap, with a key or without one.

```erlang
Client = internetdata:new(),

{ok, Result} = internetdata:lookup(Client, <<"1.1.1.1">>),
maps:get(is_anycast, Result).                    % true
maps:get(country, maps:get(location, Result)).   % the ISO 3166 country code
maps:get(name, maps:get(company, Result)).       % who the address belongs to
```

Every call answers `{ok, Term}` or `{error, Error}`. A client holds a cache, which is a process, so build one somewhere long lived and call `internetdata:close(Client)` when you are finished with it.

### With an API key

Every paid plan answers every field: `is_vpn`, `is_hosting`, `is_cdn` and the four proxy flags as well, the detail behind each flag, the city-level location, the company's type, the whole abuse contact, the whois records and the hosted domain count. The plans differ only in how many lookups they include, and a free account tries every field, 100 lookups a day. Create a key in the [console](https://app.internetdata.io), then pass it in:

```erlang
Client = internetdata:new(#{api_key => <<"your-api-key">>}),

{ok, Result} = internetdata:lookup(Client, <<"146.70.116.130">>),
maps:get(is_vpn, Result).                        % true, on a paid plan
maps:get(provider, maps:get(vpn, Result)).       % <<"mullvad">>, on a paid plan
maps:get(city, maps:get(location, Result)).      % <<"Vienna">>, on a paid plan
```

A detail map that is present but empty (`#{}`, or `[]` for `web`) means the flag above it is false. A populated one always carries every one of its keys.

### An AS or a domain

```erlang
{ok, As} = internetdata:lookup_asn(Client, 9009),
maps:get(name, As).                              % <<"M247 Europe SRL">>

{ok, Domain} = internetdata:lookup_domain(Client, <<"example.com">>),
maps:get(has_mx, Domain).                        % whether it has an MX record
```

Unlimited answers an AS's registration, and a domain's registration and which record types it has. A paid plan adds the AS's ASN Whois record and the prefixes it announces, and the domain's records, its organization's IP ranges and whether it is disposable. Neither answer is cached, and both calls take the options `lookup/3` does. An AS answer's `whois` is keyed by the registry's own field names, so its keys stay binaries. `lookup` takes addresses alone, and answers anything else `bad_request` without sending it.

### Your own address

```erlang
{ok, Result} = internetdata:my_ip(Client),
maps:get(ip, Result).   % the address we saw this call come from
```

Same answer `lookup` would give for that address, and the same cost against your allowance. It is deliberately not cached: which address you are is the whole question, and a machine that moves between networks would otherwise be told where it used to be.

### Your plan and usage

```erlang
{ok, Entitlement} = internetdata:my_entitlement(Client),
Plan = maps:get(plan, Entitlement),
Usage = maps:get(usage, Entitlement),
maps:get(key, Plan).           % <<"max">>
maps:get(requests, Usage).     % 580
maps:get(window_end, Usage).   % when the allowance resets
```

Usage counts against the anniversary of your subscription on a paid plan, not the calendar month and not the billing period, and against the UTC day on the free plan; it is the same number a lookup is gated on. `hard_limit` is `null` on an uncapped plan, which is not the same as zero. `my_ip/2` and `my_entitlement/2` take a per-call options map.

### Batch lookup

Look up as many addresses as you like at once. Bogons and cached answers are handled locally, and everything else goes to the batch endpoint in chunks of up to 1000 addresses, in parallel. The batch endpoint needs a paid plan:

```erlang
Results = internetdata:lookup_batch(Client, [<<"146.70.116.130">>, <<"8.8.8.8">>, <<"1.1.1.1">>]),

maps:foreach(fun
    (Ip, {ok, Result}) -> io:format("~s: ~p~n", [Ip, maps:get(is_vpn, Result)]);
    (Ip, {error, Error}) -> io:format("~s: ~s~n", [Ip, maps:get(message, Error)])
end, Results).
```

Results are keyed by address, so duplicates in your list collapse into a single entry and one address failing never loses the rest: it carries its error as its value, with the status the API would have given that address on its own. Erlang maps carry no order, so iterate your own list when order matters.

How many chunks are in flight at once, how many times a failed chunk is retried, and how long each chunk's request may take are configurable per call:

```erlang
Results = internetdata:lookup_batch(Client, ManyIps, #{concurrency => 4, retries => 4, timeout_ms => 5000}).
```

### Caching

Answers are cached by default, so repeat lookups of the same address are free:

```erlang
Client = internetdata:new(),

{ok, Result} = internetdata:lookup(Client, <<"1.1.1.1">>),
maps:get(is_anycast, Result).    % true, API request

{ok, Result2} = internetdata:lookup(Client, <<"1.1.1.1">>),
maps:get(is_anycast, Result2).   % true, no API request, result was cached
```

You can change the default cache variables (max size, TTL, etc) on initialization, or even disable it:

```erlang
Client = internetdata:new(#{cache => #{max => 50000, ttl_ms => 6 * 60 * 60 * 1000}}),
ClientNoCache = internetdata:new(#{cache => false}).
```

The cache belongs to one client and is never shared, because two clients holding different keys are on different plans and so entitled to different fields. It is owned by a process linked to whoever called `new/1`, so a client built inside a short-lived process loses its cache when that process ends. `internetdata:close(Client)` releases it; a client built with `cache => false` starts no process at all and needs no closing.

### Private and reserved addresses

Private, loopback, link-local, documentation and multicast addresses (and their IPv6 equivalents, including the 6to4 and Teredo ranges) are not routable on the public internet. The library answers them locally, so they cost no request and no quota:

```erlang
{ok, Result} = internetdata:lookup(Client, <<"192.168.1.1">>),
maps:get(is_bogon, Result).   % true, answered without a request
maps:get(is_vpn, Result).     % false
```

A locally computed answer is deliberately the widest shape the API serves, so every flag is present and false and every detail map is present and empty. Do not read your plan's features off one.

The check is available on the client, which is handy when your inputs are addresses anyway:

```erlang
internetdata:is_bogon(Client, <<"10.0.0.1">>).   % true
internetdata:is_bogon(Client, <<"8.8.8.8">>).    % false
```

It is also callable on its own, if you want it without a client:

```erlang
internetdata:is_bogon(<<"10.0.0.1">>).   % true
```

### Errors

A failure answers `{error, Error}`, where `Error` is a map carrying a `kind` and a `retryable` flag:

```erlang
case internetdata:lookup(Client, <<"1.1.1.1">>) of
    {ok, Result} ->
        maps:get(is_anycast, Result);
    {error, #{kind := unauthorized}} ->
        check_your_api_key();
    {error, Error} ->
        io:format("~p: ~s~n", [maps:get(kind, Error), maps:get(message, Error)])
end.
```

`kind` is one of `bad_request`, `unauthorized`, `forbidden`, `rate_limited`, `quota_exceeded`, `server_error`, `network` or `io`. `status` carries the HTTP status where there was one, and `message` is the API's own: a lookup's refusal says what went wrong, and a database call's names its result code, so `NOT_LICENSED`, `LICENSE_EXPIRED` and `IP_NOT_ALLOWED` (a call from an address the key or its organization does not allow) tell you which 403 you got without having to ask us.

Note that `rate_limited` and `quota_exceeded` both arrive as HTTP 429 and are not the same thing. A rate limit carries `Retry-After`, and retrying later works; a spent allowance, such as an overage cap you set in Billing, needs the cap raised or the window to roll over. The library retries rate limits for you, but never a spent allowance.

### Timeouts and retries

```erlang
Client = internetdata:new(#{api_key => <<"your-api-key">>, retries => 4, timeout_ms => 30000}),

{ok, Result} = internetdata:lookup(Client, <<"146.70.116.130">>, #{retries => 0, timeout_ms => 2000}).
```

`timeout_ms` bounds each attempt, body included, so a call that is retried can take longer in total. The client's values are defaults: `lookup/3`, `lookup_batch/3`, `lookup_asn/3`, `lookup_domain/3`, `my_ip/2` and `my_entitlement/2` each take `retries` and `timeout_ms` for that call alone, and `database_downloads/2`, `database_download_url/4` and every `oauth_*` function take `timeout_ms`. During a download it bounds the wait between chunks instead: a deadline that suits a listing is the wrong one for a gigabyte, while a transfer that has stopped making progress is stalled at any size.

`timeout_ms` is milliseconds from 1 to 4294967295 (about 49.7 days), or `infinity` for no bound. Anything else is refused where it is set: `new/1` raises `badarg`, and a call answers `bad_request` before sending anything.

### Databases

The database endpoints need an API key with the `db.download` scope. Keys are default-deny, so an existing key does not gain database access until that scope is added to it in the [console](https://app.internetdata.io).

```erlang
Client = internetdata:new(#{api_key => <<"your-api-key">>}),

{ok, Databases} = internetdata:database_list(Client),
[maps:get(base, D) || D <- Databases].   % [<<"bogon_ip">>, <<"vpn_ip">>, ...]
```

### The catalog

`database_list/1` returns every dataset FAMILY your organization may see, with your license beside each one:

```erlang
{ok, Databases} = internetdata:database_list(Client),

[begin
     io:format("~s (~s): ~s~n", [maps:get(base, D), maps:get(standing, D), maps:get(name, D)]),
     [io:format("  ~s ~p~n", [maps:get(id, V), maps:get(formats, V)])
      || V <- maps:get(versions, D)]
 end || D <- Databases].
```

`standing` is `<<"licensed">>` for a live grant, `<<"expired">>` for one whose term has ended, and `<<"unlicensed">>` for a database published but never bought. `license_type` says what your license permits you to do with the data, and is `null` when there is no license. `internetdata:standings()` and `internetdata:license_types()` list the values each can take, and `internetdata:database_formats()` the formats a download takes, for checking one that came from a flag or a config file.

A license covers a family (`bogon_ip`), while a download names one of its versions (`bogon_ip_v1`), so the IDs the other calls take come from a family's `versions` rather than from the family itself. Old versions are frozen rather than migrated, so both stay downloadable.

### What is in a database

`database_metadata/2` describes one version without downloading any of it, so it is cheap to poll and it is what to check a transfer against before starting one:

```erlang
{ok, Metadata} = internetdata:database_metadata(Client, <<"bogon_ip_v1">>),

maps:get(updated, Metadata).                        % <<"2026-09-04">>, the day this build was made
maps:get(entries, Metadata).                        % row count
maps:get(<<"csvgz">>, maps:get(size, Metadata)).    % bytes
```

`schema`, `sample` and `size` are keyed by format, and a sample row is keyed by the dataset's own column names. Those keys stay binaries, because they are the server's to choose; the fields the API documents are atoms. Same rule everywhere in this library.

### Downloading

`database_download/4` streams a database straight to a file. Nothing beyond a single chunk is ever held in memory, so the size of the dataset does not matter:

```erlang
{ok, Written} = internetdata:database_download(Client, <<"bogon_ip_v1">>, csvgz, "bogon_ip.csv.gz").
```

The bytes go to a neighboring `.part` file that is renamed only once the whole body has arrived, so a transfer that dies halfway leaves neither a truncated file that reads as a complete database nor a `.part` for the next attempt to append to.

For a small database you can take the bytes directly. This holds the whole file in memory, and the published catalog runs from a few hundred bytes to several gigabytes, so check `size` first for anything you have not measured:

```erlang
{ok, Bytes} = internetdata:database_download_bytes(Client, <<"bogon_ip_v1">>, csvgz).
```

`database_download_url/3` hands back the link instead of the bytes, so you can transfer it however you like. The API answers a redirect straight to object storage and the returned URL carries **no credential of yours**, so it is safe to pass to another process, another machine, or `curl`:

```erlang
{ok, Url} = internetdata:database_download_url(Client, <<"bogon_ip_v1">>, mmdb).
```

It authorizes the START of a transfer, so one already running is not interrupted when the link lapses.

Each of the three downloads the build that is live unless you name one, through the arity that takes options. A `database.updated` webhook names the build it announces and carries its `sha256`, so a receiver that downloads after the next publish asks for that build to get the file the hash is of:

```erlang
{ok, Written} = internetdata:database_download(Client, <<"vpn_ip_v1">>, mmdb, "vpn_ip_v1.mmdb",
                                               #{build => Build}).
```

A build is kept 7 days. Past that the call answers `bad_request` with the message `<<"BUILD_GONE">>`, and downloading without `build` fetches the live one. `database_download_url/4` takes `timeout_ms` beside it; a transfer refuses one as `bad_request`.

### Verifying a download

```erlang
{ok, Checksums} = internetdata:database_checksums(Client, <<"bogon_ip_v1">>, csvgz),
maps:get(sha256, Checksums).
```

Read the checksums after the transfer rather than before it: a build published in between then shows up as a mismatch instead of passing against the digest of a file you no longer have.

### Download history

`database_downloads/2` lists your organization's recent download attempts, newest first, refusals included. A denial is what answers "it stopped working", and its absence answers nothing. `limit` defaults to 50 and the API clamps it to 200:

```erlang
{ok, Attempts} = internetdata:database_downloads(Client, #{limit => 20}),

[io:format("~s ~s ~s~n", [maps:get(created, A), maps:get(dataset_id, A), maps:get(outcome, A)])
 || A <- Attempts].
```

### Sign in with OAuth (device flow)

A program running on a person's own machine can let them sign in with their browser and pick one of their API keys, instead of asking them to paste one.

```erlang
Client = internetdata:new(),
ClientId = <<"your-client-id">>,
{ok, Device} = internetdata:oauth_device_authorization(Client, ClientId,
    #{scope => <<"account.read apikeys.read apikeys.reveal">>}),
io:format("Open ~s and enter ~s~n", [maps:get(verification_uri, Device), maps:get(user_code, Device)]),
{ok, Token} = internetdata:oauth_poll_device_token(Client, ClientId, Device),
Keyed = case Token of
    #{apikey := Key} -> internetdata:new(#{api_key => Key});
    #{} -> error(no_api_key_picked)
end.
```

A refusal answers `{error, #{error_code := <<"access_denied">>}}` and a code that expired first `{error, #{error_code := <<"expired_token">>}}`. Client IDs are issued on request from support@internetdata.io, and `internetdata:oauth_revoke(Client, ClientId, maps:get(refresh_token, Token))` signs the machine out.

### Sign in with OAuth (authorization code)

An app that can take a browser redirect signs the person in there instead, with a PKCE pair made for that one sign-in.

```erlang
Client = internetdata:new(),
ClientId = <<"your-client-id">>,
RedirectUri = <<"http://127.0.0.1:8765/callback">>,
#{verifier := Verifier, challenge := Challenge} = internetdata:oauth_create_pkce(),
{ok, Url} = internetdata:oauth_authorization_url(Client, ClientId, RedirectUri, Challenge,
    #{scope => <<"apikeys.use">>, state => <<"your-state">>}),
%% Open Url in the browser. Its redirect to RedirectUri carries code and state.
{ok, Token} = internetdata:oauth_exchange_authorization_code(Client, ClientId, Code, Verifier,
    RedirectUri).
```

Check that `state` came back as you sent it before you exchange `code`, which works once. The client ID can also be the https URL of a client metadata document your app serves, and such an app is never handed a key, so `Token` carries no `apikey`.

### Register a client

An app with no client ID, and no client metadata document to use as one, registers itself, then signs in with the `client_id` it gets back as the client ID for `oauth_authorization_url` and `oauth_exchange_authorization_code`:

```erlang
Client = internetdata:new(),
{ok, Registration} = internetdata:oauth_register(Client, [<<"http://127.0.0.1:8765/callback">>],
                                                 #{client_name => <<"Your App">>}),
```

Each redirect URI must be https on a public host name, or http on a loopback address, which then matches any port. Nothing is kept until a person approves the client, so an app with no client ID saved can simply register again.

### Absent is not false

Unlimited leaves out `is_vpn`, `is_hosting`, `is_cdn` and the proxy flags with the detail behind them, and inside `location`, `asn`, `company` and `abuse` the members only a paid plan answers, such as `city`, `rpki_status`, `type` and `phone`; a free-plan key's answer carries `trial_expired`, true once its daily trial is spent. Fields your plan does not include are simply not in the result map. Absent means "not in your plan"; a present `false` means "we checked, and no".

```erlang
maps:get(is_vpn, Result, false).          % when you only want the flag
maps:is_key(is_vpn, Result).              % false on Unlimited: not in your plan
maps:get(trial_expired, Result, false).   % true: a free-plan key's daily trial is spent
```

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, and Ruby. See our GitHub at https://github.com/internetdata for more.

## About InternetData

Geolocation, anonymity, ownership and network data for IP addresses, AS numbers and domains, as an API and as databases you download and query yourself.

[<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="64"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
